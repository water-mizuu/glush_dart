/// Deduplication table for BSPPF nodes.
///
/// All node creation goes through this table to ensure that nodes are shared
/// whenever two derivation paths produce the same (type, start, end) triple.
library glush.sppf_table;

import "package:glush/src/core/patterns.dart";
import "package:glush/src/core/sppf.dart";
import "package:meta/meta.dart";

/// A deduplication table and factory for Binarized Shared Packed Parse Forest (BSPPF) nodes.
///
/// The [SppfTable] is the central repository for all nodes created during a
/// single parse session. It ensures that the forest is "packed" by memoizing
/// nodes based on their unique identities. Two derivation paths that cover the
/// same input span with the same grammar symbol or state-machine slot will
/// share the exact same [SppfNode] instance.
///
/// This sharing is critical for maintaining polynomial (or better) space
/// complexity in the face of exponential numbers of possible derivations in
/// ambiguous grammars.
class SppfTable {
  // -------------------------------------------------------------------------
  // Internal maps
  // -------------------------------------------------------------------------

  final Map<int, TerminalNode> _terminals = {};
  final Map<int, EpsilonNode> _epsilons = {};

  // Packed as a single int key where possible for speed.
  // Complex key: (slotId, start, end) - use Object.hash
  final Map<int, IntermediateNode> _intermediateSimple = {};
  final Map<Object, IntermediateNode> _intermediateComplex = {};

  final Map<int, SymbolNode> _symbolSimple = {};
  final Map<Object, SymbolNode> _symbolComplex = {};

  // -------------------------------------------------------------------------
  // Public accessors
  // -------------------------------------------------------------------------

  /// Returns a shared [TerminalNode] representing the token at [position].
  ///
  /// If a node already exists for this position, the existing instance is
  /// returned.
  TerminalNode terminal(int position) => _terminals[position] ??= TerminalNode(position);

  /// Returns a shared [EpsilonNode] representing an empty match at [position].
  EpsilonNode epsilon(int position) => _epsilons[position] ??= EpsilonNode(position);

  /// Returns a shared [IntermediateNode] for the given [slotId] and input span.
  ///
  /// Intermediate nodes represent partially completed rules or state-machine
  /// configurations. They are keyed by the state ID and the input range they
  /// cover.
  IntermediateNode intermediate(int slotId, int start, int end) {
    // Optimization: Pack the triple into a single 64-bit integer if possible.
    if (slotId < 0xFFFF && start < 0xFFFF && end < 0xFFFF) {
      var key = (slotId << 32) | (start << 16) | end;
      return _intermediateSimple[key] ??= IntermediateNode(slotId, start, end);
    }
    var key = Object.hash(slotId, start, end);
    return _intermediateComplex[key] ??= IntermediateNode(slotId, start, end);
  }

  /// Returns a shared [SymbolNode] for the given [ruleSymbol] and input span.
  ///
  /// Symbol nodes represent fully completed grammar rules. They are keyed by the
  /// rule's unique symbol ID and the range of input tokens they consumed.
  SymbolNode symbol(PatternSymbol ruleSymbol, int start, int end) {
    if (ruleSymbol >= 0 && ruleSymbol < 0xFFFF && start < 0xFFFF && end < 0xFFFF) {
      var key = (ruleSymbol << 32) | (start << 16) | end;
      return _symbolSimple[key] ??= SymbolNode(ruleSymbol, start, end);
    }
    var key = Object.hash(ruleSymbol, start, end);
    return _symbolComplex[key] ??= SymbolNode(ruleSymbol, start, end);
  }

  // -------------------------------------------------------------------------
  // Core construction helpers
  // -------------------------------------------------------------------------

  /// Constructs or updates a binarized forest node during a parse transition.
  ///
  /// This is the primary entry point for forest construction during state
  /// transitions. It manages the creation of [IntermediateNode]s that represent
  /// the concatenation of an existing prefix ([left]) and a newly completed
  /// child ([right]).
  ///
  /// By creating a chain of binary nodes, we ensure that the forest remains
  /// binarized, which is essential for efficient sharing and ambiguity
  /// representation.
  IntermediateNode getNodeP(
    int slotId,
    int callStart,
    int position,
    SppfNode? left,
    SppfNode right,
  ) {
    var node = intermediate(slotId, callStart, position);
    node.addFamily(left, right);
    return node;
  }

  // -------------------------------------------------------------------------
  // Diagnostics
  // -------------------------------------------------------------------------

  int get terminalCount => _terminals.length;
  int get intermediateCount => _intermediateSimple.length + _intermediateComplex.length;
  int get symbolCount => _symbolSimple.length + _symbolComplex.length;

  /// All [SymbolNode]s created during this parse session.
  ///
  /// Exposed for diagnostic tests that want to walk the BSPPF after parsing.
  Iterable<SymbolNode> get allSymbolNodes => _symbolSimple.values.followedBy(_symbolComplex.values);

  @override
  String toString() => "SppfTable(T=$terminalCount, I=$intermediateCount, S=$symbolCount)";

  /// Renders the entire parse forest as a Graphviz DOT visualization.
  ///
  /// This is a powerful diagnostic tool for inspecting the structure of a
  /// parse, especially when debugging ambiguous grammars or complex state
  /// transitions.
  ///
  /// The resulting graph uses distinct shapes and colors for different node
  /// types:
  /// - **Blue Boxes**: [SymbolNode]s (rule completions).
  /// - **Grey Boxes**: [IntermediateNode]s (partially completed paths).
  /// - **Green Ovals**: [TerminalNode]s (input tokens).
  /// - **Yellow Ovals**: [EpsilonNode]s (empty matches).
  ///
  /// Nodes with red borders indicate ambiguity (multiple derivation paths).
  String toDot({
    required String Function(PatternSymbol) nameOf,
    String Function(int slotId)? slotOf,
    List<int>? input,
    String rankdir = "TB",
  }) {
    var buf = StringBuffer();
    buf.writeln("digraph BSPPF {");
    buf.writeln("  rankdir=$rankdir;");
    buf.writeln('  node [fontname="Helvetica", fontsize=11];');
    buf.writeln("  edge [fontsize=9];");
    buf.writeln();

    // ── Assign stable node IDs ──────────────────────────────────────────────
    var nodeId = <Object, String>{};
    var counter = 0;

    String idOf(Object node) => nodeId.putIfAbsent(node, () => "n${counter++}");

    // Collect all reachable nodes via BFS from all SymbolNodes.
    var visited = <Object>{};
    var queue = <Object>[..._symbolSimple.values, ..._symbolComplex.values];

    // ── Helper: byte span text ───────────────────────────────────────────────
    String spanText(int start, int end) {
      if (input == null || start >= end) {
        return "[$start..$end)";
      }
      try {
        // Decode the relevant slice; replace malformed bytes with '?'.
        var slice = input.sublist(start.clamp(0, input.length), end.clamp(0, input.length));
        // Represent bytes as ASCII printable chars or '·'.
        var chars = slice.map((b) {
          if (b >= 32 && b < 127) {
            return String.fromCharCode(b);
          }
          return "·";
        }).join();
        return "'$chars' [$start..$end)";
      } on Exception catch (_) {
        return "[$start..$end)";
      }
    }

    // ── BFS to emit all nodes ────────────────────────────────────────────────
    while (queue.isNotEmpty) {
      var node = queue.removeLast();
      if (!visited.add(node)) {
        continue;
      }
      var id = idOf(node);

      switch (node) {
        case SymbolNode sym:
          var ruleName = nameOf(sym.ruleSymbol);
          var span = spanText(sym.start, sym.end);
          var labelLines =
              sym.labelMapForDebug?.entries
                  .map((e) => '${e.key}: ${e.value.map((s) => '[${s.$1}..${s.$2})').join(', ')}')
                  .join(r"\n") ??
              "";
          var labelAnnotation = labelLines.isNotEmpty ? "\\n{$labelLines}" : "";
          var isAmbiguous = sym.families.length > 1;
          var border = isAmbiguous ? "color=crimson, penwidth=2," : "";

          buf.writeln(
            '  $id [label="${_esc(ruleName)}\\n$span${_esc(labelAnnotation)}", '
            'shape=box, style="rounded,filled", fillcolor="#5B9BD5", '
            "fontcolor=white, $border];",
          );

          for (var (i, body) in sym.families.indexed) {
            // Packed Node for this derivation
            var packedId = "${id}_p$i";
            buf.writeln('  $packedId [label="", shape=circle, width=0.1, height=0.1];');
            buf.writeln('  $id -> $packedId [label="alt${i + 1}", arrowhead=none];');

            if (body == null) {
              var eid = idOf(_EpsilonSentinel(sym.start));
              buf.writeln("  $packedId -> $eid [style=dashed];");
              if (visited.add(_EpsilonSentinel(sym.start))) {
                buf.writeln(
                  '  $eid [label="ε", shape=oval, '
                  'style=filled, fillcolor="#FFFACD"];',
                );
              }
            } else {
              buf.writeln("  $packedId -> ${idOf(body)};");
              queue.add(body);
            }
          }

        case IntermediateNode im:
          var slotName = slotOf?.call(im.slotId) ?? "slot ${im.slotId}";
          var span = spanText(im.start, im.end);
          var isAmbiguous = im.families.length > 1;
          var border = isAmbiguous ? "color=crimson, penwidth=2," : "";

          buf.writeln(
            '  $id [label="${_esc(slotName)}\\n$span", shape=box, '
            'style=filled, fillcolor="#D9D9D9", $border];',
          );

          for (var (i, fam) in im.families.indexed) {
            // Packed Node for this derivation
            var packedId = "${id}_p$i";
            buf.writeln('  $packedId [label="", shape=circle, width=0.1, height=0.1];');
            buf.writeln('  $id -> $packedId [label="alt${i + 1}", arrowhead=none];');

            if (fam.left != null) {
              buf.writeln("  $packedId -> ${idOf(fam.left!)} [style=dashed];");
              queue.add(fam.left!);
            }
            if (fam.right != null) {
              buf.writeln("  $packedId -> ${idOf(fam.right!)};");
              queue.add(fam.right!);
            } else {
              var eid = idOf(_EpsilonSentinel(im.end));
              buf.writeln("  $packedId -> $eid [style=dashed];");
              if (visited.add(_EpsilonSentinel(im.end))) {
                buf.writeln(
                  '  $eid [label="ε", shape=oval, '
                  'style=filled, fillcolor="#FFFACD"];',
                );
              }
            }
          }

        case TerminalNode term:
          var text = input != null && term.position < input.length
              ? _esc(
                  String.fromCharCode(
                    input[term.position] >= 32 && input[term.position] < 127
                        ? input[term.position]
                        : 0xB7 /* · */,
                  ),
                )
              : "?";
          buf.writeln(
            '  $id [label="\'$text\'\\n[${term.position}..${term.end})", '
            'shape=oval, style=filled, fillcolor="#C8E6C9"];',
          );

        case EpsilonNode eps:
          buf.writeln(
            '  $id [label="ε\\n[${eps.position}]", shape=oval, '
            'style=filled, fillcolor="#FFFACD"];',
          );
      }
    }

    buf.writeln("}");
    return buf.toString();
  }

  static String _esc(String s) =>
      s.replaceAll(r"\", r"\\").replaceAll('"', r'\"').replaceAll("\n", r"\n");
}

/// Sentinel used to render an epsilon body edge for a SymbolNode.
@immutable
class _EpsilonSentinel {
  const _EpsilonSentinel(this.position);
  final int position;

  @override
  bool operator ==(Object other) => other is _EpsilonSentinel && other.position == position;

  @override
  int get hashCode => position ^ 0xE70;
}
