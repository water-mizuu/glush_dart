// ignore_for_file: avoid_print
/// Diagnostic test: BSPPF label awareness in data-driven grammars.
///
// ignore: comment_references
/// This test drives the parser manually (via [createParseState]) so we can
/// inspect [ParseState.bsppfRoot] and [ParseState.sppfTable] after a parse.
///
/// For each [SymbolNode] that has a non-empty label map it prints:
///  - the rule name (resolved via stateMachine.allRules)
///  - span (start..end)
///  - families count (derivations)
///  - label index (name → start..end in the source text)
///
/// Run with:   dart test test/diagnostic/bsppf_label_debug_test.dart -v
library bsppf_label_debug;

import "dart:convert" show utf8;

import "package:glush/glush.dart";
import "package:glush/src/core/sppf.dart";
import "package:glush/src/parser/common/parse_state.dart";
import "package:test/test.dart";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Run the full parse and return the final [ParseState] for inspection.
ParseState _driveParser(SMParser parser, String input) {
  var bytes = utf8.encode(input);
  var ps = parser.createParseState(captureTokensAsMarks: true);
  for (var byte in bytes) {
    ps.processToken(byte);
    if (!ps.hasPendingWork) {
      break;
    }
  }
  ps.finish();
  return ps;
}

/// Build a rule-name resolver from the state machine's allRules table.
String Function(PatternSymbol) _nameResolver(StateMachine sm) {
  var byId = <PatternSymbol, String>{};
  sm.allRules.forEach((sym, rule) => byId[sym] = rule.name.toString());
  return (sym) => byId[sym] ?? "?($sym)";
}

/// Dump every [SymbolNode] with a non-empty label map to stdout.
void _printLabelIndex(ParseState ps, String input, StateMachine sm) {
  var bytes = utf8.encode(input);
  var resolve = _nameResolver(sm);

  String spanText(int start, int end) {
    if (start >= end) {
      return "ε";
    }
    var decoded = utf8.decode(bytes.sublist(start, end), allowMalformed: true);
    return '"$decoded" [$start..$end)';
  }

  print("─" * 60);
  print('BSPPF label index  input: "$input"');
  print("─" * 60);

  var printed = 0;
  for (var sym in ps.sppfTable.allSymbolNodes) {
    var map = sym.labelMapForDebug;
    if (map == null || map.isEmpty) {
      continue;
    }
    printed++;
    var ruleName = resolve(sym.ruleSymbol);
    print(
      "  SymbolNode($ruleName, ${sym.start}..${sym.end})"
      "  [${sym.families.length} derivation(s)]",
    );
    for (var entry in map.entries) {
      for (var span in entry.value) {
        print('    label "${entry.key}": ${spanText(span.$1, span.$2)}');
      }
    }
  }
  if (printed == 0) {
    print("  (no label spans recorded in any SymbolNode)");
  }
  print("─" * 60);
}

// ---------------------------------------------------------------------------
// Grammar helpers
// ---------------------------------------------------------------------------

/// Fluent-API grammar:
///   start = wrapper(content: body)
///   wrapper(content) = open: '[' body: content close: ']'
///   body = 'a'+
SMParser _buildLabelledWrapper() {
  late Rule body;
  late Rule wrapper;
  late Rule start;

  body = Rule("body", () => Pattern.char("a") >> Pattern.char("a").star());

  wrapper = Rule(
    "wrapper",
    () =>
        Label("open", Pattern.char("[")) >>
        Label("body", ParameterRefPattern("content")) >>
        Label("close", Pattern.char("]")),
  );

  start = Rule("start", () => wrapper(arguments: {"content": CallArgumentValue.rule(body)}));

  return SMParser(Grammar(() => start));
}

/// Grammar-string version:
///   start = invoke(item: atom)
///   invoke(item) = open: '(' body: item close: ')'
///   atom = key: ('a' | 'b' | 'c')
SMParser _buildGrammarFileLabelledParser() {
  const src = r"""
    start = invoke(item: atom)

    invoke(item) =
      open: '('
      body: item
      close: ')'

    atom = key: ('a' | 'b' | 'c')
  """;
  return src.toSMParser();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group("BSPPF label awareness — data-driven grammars", () {
    // ------------------------------------------------------------------
    // Test 1: Fluent API — labelled wrapper invoked with a parameter rule
    // ------------------------------------------------------------------
    test("labels inside a parameter-invoked rule are recorded in SymbolNode", () {
      var parser = _buildLabelledWrapper();
      const input = "[aaa]";
      var ps = _driveParser(parser, input);

      _printLabelIndex(ps, input, parser.stateMachine);

      // The root must be set.
      expect(ps.bsppfRoot, isNotNull, reason: "bsppfRoot must be set after accept");

      // Find the SymbolNode for 'wrapper' covering the whole input.
      var inputLen = utf8.encode(input).length; // 5
      var resolve = _nameResolver(parser.stateMachine);

      var wrapperSym = ps.sppfTable.allSymbolNodes.where((s) {
        return resolve(s.ruleSymbol) == "wrapper" && s.start == 0 && s.end == inputLen;
      }).firstOrNull;

      expect(wrapperSym, isNotNull, reason: "SymbolNode for 'wrapper' must exist");
      print("");
      print('[wrapper] labelFor("open"):  ${wrapperSym!.labelFor("open")}');
      print('[wrapper] labelFor("body"):  ${wrapperSym.labelFor("body")}');
      print('[wrapper] labelFor("close"): ${wrapperSym.labelFor("close")}');

      // '[' → bytes 0..1, 'aaa' → 1..4, ']' → 4..5.
      expect(
        wrapperSym.labelFor("open"),
        equals((0, 1)),
        reason: "'open' label should cover '[' at [0..1)",
      );
      expect(
        wrapperSym.labelFor("body"),
        equals((1, 4)),
        reason: "'body' label should cover 'aaa' at [1..4)",
      );
      expect(
        wrapperSym.labelFor("close"),
        equals((4, 5)),
        reason: "'close' label should cover ']' at [4..5)",
      );
    });

    // ------------------------------------------------------------------
    // Test 2: Grammar-string parser — labels survive the meta-grammar path
    // ------------------------------------------------------------------
    test("grammar-string parser records labels inside data-driven invocation", () {
      var parser = _buildGrammarFileLabelledParser();
      const input = "(b)";
      var ps = _driveParser(parser, input);

      _printLabelIndex(ps, input, parser.stateMachine);

      expect(ps.bsppfRoot, isNotNull);

      var resolve = _nameResolver(parser.stateMachine);
      var inputLen = utf8.encode(input).length; // 3

      var invokeSym = ps.sppfTable.allSymbolNodes.where((s) {
        return resolve(s.ruleSymbol) == "invoke" && s.start == 0 && s.end == inputLen;
      }).firstOrNull;

      expect(invokeSym, isNotNull, reason: "SymbolNode for 'invoke' must exist");
      print("");
      print('[invoke] labelFor("open"):  ${invokeSym!.labelFor("open")}');
      print('[invoke] labelFor("body"):  ${invokeSym.labelFor("body")}');
      print('[invoke] labelFor("close"): ${invokeSym.labelFor("close")}');

      // '(' byte 0, 'b' byte 1, ')' byte 2 — all single bytes.
      expect(invokeSym.labelFor("open"), equals((0, 1)));
      expect(invokeSym.labelFor("body"), equals((1, 2)));
      expect(invokeSym.labelFor("close"), equals((2, 3)));
    });

    // ------------------------------------------------------------------
    // Test 3: Deeply nested parameter chain — labels survive 3 layers
    //
    //   outer(handler, item) = handler(piece: item) item
    //   middle(piece) = inner(value: piece)
    //   inner(value) = open: '[' part1: value part2: value close: ']'
    //   atom = 'a'|'b'|'c'
    //   start = outer(handler: middle, item: atom)
    // ------------------------------------------------------------------
    test("labels inside deeply nested parameter-invoked rules are recorded", () {
      // Fluent API equivalent of:
      //   outer(handler, item) = handler(piece: item) item
      //   middle(piece) = inner(value: piece)
      //   inner(value) = open:'[' part1:value part2:value close:']'
      //   atom = 'a'|'b'|'c'
      //   start = outer(handler: middle, item: atom)
      late Rule atom;
      late Rule inner;
      late Rule middle;
      late Rule outer;
      late Rule start;

      atom = Rule("atom", () => Pattern.char("a") | Pattern.char("b") | Pattern.char("c"));

      inner = Rule(
        "inner",
        () =>
            Label("open", Pattern.char("[")) >>
            Label("part1", ParameterRefPattern("value")) >>
            Label("part2", ParameterRefPattern("value")) >>
            Label("close", Pattern.char("]")),
      );

      middle = Rule(
        "middle",
        () => inner(arguments: {"value": CallArgumentValue.reference("piece")}),
      );

      outer = Rule(
        "outer",
        () =>
            ParameterCallPattern(
              "handler",
              arguments: {"piece": CallArgumentValue.reference("item")},
            ) >>
            ParameterRefPattern("item"),
      );

      start = Rule(
        "start",
        () => outer(
          arguments: {
            "handler": CallArgumentValue.rule(middle),
            "item": CallArgumentValue.rule(atom),
          },
        ),
      );

      var parser = SMParser(Grammar(() => start));
      const input = "[aa]a";
      var ps = _driveParser(parser, input);

      _printLabelIndex(ps, input, parser.stateMachine);

      // Also dump ALL symbol nodes for full diagnostics.
      print("\n--- All SymbolNodes ---");
      var resolve = _nameResolver(parser.stateMachine);
      for (var s in ps.sppfTable.allSymbolNodes) {
        print("  $s  → ${resolve(s.ruleSymbol)}");
      }

      expect(ps.bsppfRoot, isNotNull);

      // Locate 'inner' covering '[aa]' = bytes 0..4.
      var innerSym = ps.sppfTable.allSymbolNodes.where((s) {
        return resolve(s.ruleSymbol) == "inner" && s.start == 0 && s.end == 4;
      }).firstOrNull;

      expect(innerSym, isNotNull, reason: "SymbolNode for 'inner' at 0..4 must exist");
      print('\n[inner] labelFor("open"):  ${innerSym!.labelFor("open")}');
      print('[inner] labelFor("part1"): ${innerSym.labelFor("part1")}');
      print('[inner] labelFor("part2"): ${innerSym.labelFor("part2")}');
      print('[inner] labelFor("close"): ${innerSym.labelFor("close")}');

      expect(innerSym.labelFor("open"), equals((0, 1)));
      expect(innerSym.labelFor("part1"), equals((1, 2)));
      expect(innerSym.labelFor("part2"), equals((2, 3)));
      expect(innerSym.labelFor("close"), equals((3, 4)));
    });
  });
}
