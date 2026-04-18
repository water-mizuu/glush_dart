/// Deduplication table for BSPPF nodes.
///
/// All node creation goes through this table to ensure that nodes are shared
/// whenever two derivation paths produce the same (type, start, end) triple.
library glush.sppf_table;

import "package:glush/src/core/patterns.dart";
import "package:glush/src/core/sppf.dart";
import "package:meta/meta.dart";

/// Shared table of BSPPF nodes for a single parse session.
///
/// Keys:
/// - [TerminalNode]   → `position`
/// - [EpsilonNode]    → `position`
/// - [IntermediateNode] → `(slotId, start, end)`
/// - [SymbolNode]     → `(ruleSymbol, start, end)`
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

  /// Get or create a [TerminalNode] for [position].
  TerminalNode terminal(int position) => _terminals[position] ??= TerminalNode(position);

  /// Get or create an [EpsilonNode] at [position].
  EpsilonNode epsilon(int position) => _epsilons[position] ??= EpsilonNode(position);

  /// Get or create an [IntermediateNode] for ([slotId], [start], [end]).
  IntermediateNode intermediate(int slotId, int start, int end) {
    // Fast path: pack into one int if all values fit.
    if (slotId < 0xFFFF && start < 0xFFFF && end < 0xFFFF) {
      var key = (slotId << 32) | (start << 16) | end;
      return _intermediateSimple[key] ??= IntermediateNode(slotId, start, end);
    }
    var key = Object.hash(slotId, start, end);
    return _intermediateComplex[key] ??= IntermediateNode(slotId, start, end);
  }

  /// Get or create a [SymbolNode] for ([ruleSymbol], [start], [end]).
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

  /// Build or update an [IntermediateNode] for a step transition.
  ///
  /// Called after each child completion (terminal or sub-rule):
  /// - [slotId]: the state ID of the state we are transitioning INTO
  /// - [callStart]: the start position of the enclosing rule call
  /// - [position]: the new input position (right boundary after the child)
  /// - [left]: the accumulated prefix so far (null = ε, first child only)
  /// - [right]: the child just completed
  ///
  /// Returns the shared [IntermediateNode] keyed by (slotId, callStart, position).
  /// Multiple derivation paths add distinct [SppfFamily] entries.
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

  /// Render the BSPPF as a Graphviz DOT graph.
  ///
  /// [nameOf] maps a [PatternSymbol] to a human-readable rule name.
  /// Typical usage:
  /// ```dart
  /// final dot = parseState.sppfTable.toDot(
  ///   nameOf: (sym) => parser.stateMachine.allRules[sym]?.name.toString() ?? '?($sym)',
  ///   input: utf8.encode(inputString),
  /// );
  /// ```
  ///
  /// Node shapes and colors:
  /// - **SymbolNode** (rule completions) — rounded rectangle, steel-blue fill
  /// - **IntermediateNode** (in-progress slots) — rectangle, light-grey fill
  /// - **TerminalNode** (single consumed byte) — oval, pale-green fill
  /// - **EpsilonNode** (zero-width match) — oval, pale-yellow fill
  ///
  /// Edges represent the binarized derivation structure:
  /// - `SymbolNode → body` (one edge per derivation alternative)
  /// - `IntermediateNode → left + right` (packed node split)
  ///
  /// Ambiguous nodes (multiple families) are highlighted with a red border.
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
