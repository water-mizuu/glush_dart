import "dart:convert";

import "package:glush/glush.dart";
import "package:test/test.dart";

typedef _MarksCase = ({
  String name,
  String grammar,
  String input,
  String? startRuleName,
  int? expectedPaths,
});

Object _encodeNode(ParseNode node) {
  return switch (node) {
    TokenResult() => {"type": "token", "span": node.span},
    ParseResult() => {
      "type": "result",
      "span": node.span,
      "children": [
        for (final child in node.children) {"label": child.$1, "node": _encodeNode(child.$2)},
      ],
    },
  };
}

String _canonicalNode(ParseNode node) => jsonEncode(_encodeNode(node));

Set<String> _marksTrees(SMParser parser, String input) {
  var result = parser.parseAmbiguous(input, captureTokensAsMarks: true);
  expect(result, isA<ParseAmbiguousSuccess>());
  var forest = (result as ParseAmbiguousSuccess).forest;
  return {
    for (final path in forest.allMarkPaths())
      _canonicalNode(const StructuredEvaluator().evaluate(path, input: input)),
  };
}

void main() {
  group("Marks System Regression", () {
    var compareCases = <_MarksCase>[
      (
        name: "simple labels",
        grammar: '''
          start = user:ident ":" pass:ident;
          ident = [a-z]+;
        ''',
        input: "alice:secret",
        startRuleName: null,
        expectedPaths: 1,
      ),
      (
        name: "dollar mark wraps labeled sequence",
        grammar: r'''
          start = $pair left:ident ":" right:ident;
          ident = [a-z]+;
        ''',
        input: "alice:bob",
        startRuleName: null,
        expectedPaths: 1,
      ),
      (
        name: "ambiguous overlapping labels",
        grammar: r'''
          S = a:("a" "b") | "a" b:("b");
        ''',
        input: "ab",
        startRuleName: null,
        expectedPaths: 2,
      ),
      (
        name: "ambiguous repetition labels",
        grammar: r"""
          S = (a:([a-z]) | b:([a-z]))+;
        """,
        input: "aa",
        startRuleName: null,
        expectedPaths: 4,
      ),
      (
        name: "negative predicate keyword guard",
        grammar: r"""
          keyword = $kw chars:('w' 'h' 'i' 'l' 'e') ![a-z];
        """,
        input: "while",
        startRuleName: "keyword",
        expectedPaths: 1,
      ),
      (
        name: "precedence marks and labels",
        grammar: r'''
          expr =
              6| $add left:expr^6 "+" right:expr^7
              7| $mul left:expr^7 "*" right:expr^8
             11| value:[0-9]+;
        ''',
        input: "2+3*4",
        startRuleName: "expr",
        expectedPaths: 1,
      ),
      (
        name: "left recursion with dollar marks",
        grammar: r"""
          S = $join left:S tail:'a' | $base value:'a';
        """,
        input: "aaa",
        startRuleName: null,
        expectedPaths: 1,
      ),
      (
        name: "optional labels",
        grammar: r"""
          S = prefix:([a-z])? tail:'x';
        """,
        input: "ax",
        startRuleName: null,
        expectedPaths: 1,
      ),
    ];

    for (var testCase in compareCases) {
      test("marks match forest for ${testCase.name}", () {
        var parser = testCase.grammar.toSMParser(startRuleName: testCase.startRuleName);

        var marksTrees = _marksTrees(parser, testCase.input);

        if (testCase.expectedPaths case var expected?) {
          expect(marksTrees.length, equals(expected));
        }
      });
    }

    test("nested labels inside dollar mark preserve the full wrapped tree", () {
      var parser =
          r'''
            start = item:($pair left:ident ":" right:(first:ident "-" last:ident));
            ident = [a-z]+;
          '''
              .toSMParser();

      var result = parser.parseAmbiguous("alpha:beta-gamma", captureTokensAsMarks: true);
      expect(result, isA<ParseAmbiguousSuccess>());

      var tree = const StructuredEvaluator().evaluate(
        (result as ParseAmbiguousSuccess).forest.allMarkPaths().single,
        input: "alpha:beta-gamma",
      );

      var item = tree["item"].single as ParseResult;
      var pair = item["start.pair"].single as ParseResult;
      expect(pair["left"].single.span, equals("alpha"));

      var right = pair["right"].single as ParseResult;
      expect(right["first"].single.span, equals("beta"));
      expect(right["last"].single.span, equals("gamma"));
      expect(pair.span, equals("alpha:beta-gamma"));
    });

    test("dangling else keeps both marked interpretations", () {
      var parser =
          r'''
            S = $ifStmt "if" _ thenStmt:S (_ "else" _ elseStmt:S)? | a:"a";
            _ = [ \t\n\r]*;
          '''
              .toSMParser();

      var result = parser.parseAmbiguous("if if a else a", captureTokensAsMarks: true);
      expect(result, isA<ParseAmbiguousSuccess>());

      var trees = (result as ParseAmbiguousSuccess).forest.allMarkPaths().map(
        (path) => const StructuredEvaluator().evaluate(path, input: "if if a else a"),
      );
      var canonicalTrees = {for (final tree in trees) _canonicalNode(tree)};

      expect(canonicalTrees.length, equals(2));
    });

    test("predicate labels do not consume input but keep downstream structure", () {
      var parser =
          r"""
            S = look:(&Target) value:Target;
            Target = $pair first:'a' second:'b';
          """
              .toSMParser();

      var result = parser.parseAmbiguous("ab", captureTokensAsMarks: true);
      expect(result, isA<ParseAmbiguousSuccess>());

      var tree = const StructuredEvaluator().evaluate(
        (result as ParseAmbiguousSuccess).forest.allMarkPaths().single,
        input: "ab",
      );

      expect(tree["look"], isEmpty);

      var value = tree["value"].single as ParseResult;
      var pair = value["Target.pair"].single as ParseResult;
      expect(pair["first"].single.span, equals("a"));
      expect(pair["second"].single.span, equals("b"));
    });

    test("meta-style continuation grammar yields many stable mark paths", () {
      var parser =
          r'''
            full = full:(_ file:file _);
            file = rules:(left:file _ right:rule) | first:(rule:rule);
            rule = rule:(name:ident _ '=' _ body:choice ( _ ';' )?);
            choice = choice:(left:choice _ '|' _ right:seq) | seq;
            seq = seq:(left:seq _ (&isContinuation) right:prefix) | prefix;
            prefix = and:('&' atom:rep) | not:('!' atom:rep) | rep;
            rep = rep:(atom:primary kind:repKind) | primary;
            repKind = star:'*' | plus:'+' | question:'?';
            primary = group:('(' _ inner:choice _ ')')
                    | label:(name:ident ':' atom:primary)
                    | mark:('$' name:ident)
                    | ref:ident
                    | lit:literal
                    | range:charRange
                    | any:'.';
            isContinuation = &(ident !(_ [=]))
                          | &literal
                          | &charRange
                          | &'['
                          | &'('
                          | &'.'
                          | &'$'
                          | &'!'
                          | &'&';
            ident = [A-Za-z$_] [A-Za-z$_0-9]*;
            literal = ['] (!['] .)* ['] | ["] (!["] .)* ["];
            charRange = '[' (!']' .)* ']';
            _ = (plain_ws | comment | newline)*;
            comment = '#' (!newline .)*;
            plain_ws = [ \t]+;
            newline = [\n\r]+;
          '''
              .toSMParser(startRuleName: "full");

      const input = "abc = c | &d !e*\nxyz = 'foo' [a-z] \$mark";
      var result = parser.parseAmbiguous(input, captureTokensAsMarks: true);
      expect(result, isA<ParseAmbiguousSuccess>());

      var forest = (result as ParseAmbiguousSuccess).forest;
      var paths = forest.allMarkPaths().toList();

      var trees = paths
          .map((path) => const StructuredEvaluator().evaluate(path, input: input))
          .toList();
      expect(trees, isNotEmpty);
      expect(trees.any((tree) => tree["full"].isNotEmpty), isTrue);
      expect(trees.any((tree) => tree.span == input), isTrue);
    });

    test(r"$mark wraps the whole sequence node with its children intact", () {
      var parser =
          r'''
            start = $pair left:ident ":" right:ident;
            ident = [a-z]+;
          '''
              .toSMParser();

      var result = parser.parseAmbiguous("alice:bob", captureTokensAsMarks: true);
      expect(result, isA<ParseAmbiguousSuccess>());

      var tree = const StructuredEvaluator().evaluate(
        (result as ParseAmbiguousSuccess).forest.allMarkPaths().single,
        input: "alice:bob",
      );

      var pair = tree["start.pair"].single as ParseResult;
      expect(pair["left"].single.span, equals("alice"));
      expect(pair["right"].single.span, equals("bob"));
      expect(pair.span, equals("alice:bob"));
    });

    test("nested label marks stay balanced and ordered", () {
      var parser =
          r'''
            start = outer:(left:('a'+) ":" right:(inner:('b'+)));
          '''
              .toSMParser();

      var outcome = parser.parse("aaa:bbb", captureTokensAsMarks: true);
      expect(outcome, isA<ParseSuccess>());

      var marks = (outcome as ParseSuccess).rawMarks;
      var starts = [
        for (final mark in marks)
          if (mark case LabelStartMark(:var name)) name,
      ];
      var ends = [
        for (final mark in marks)
          if (mark case LabelEndMark(:var name)) name,
      ];

      expect(starts, equals(["outer", "left", "right", "inner"]));
      expect(ends, equals(["left", "inner", "right", "outer"]));
    });

    test("named marks remain stable when token capture is enabled", () {
      var parser =
          r"""
            start = $outer first:'a' middle:'b' last:'c';
          """
              .toSMParser();

      var outcome = parser.parse("abc", captureTokensAsMarks: true);
      expect(outcome, isA<ParseSuccess>());

      var result = outcome as ParseSuccess;
      expect(result.marks, equals(["start.outer", "first", "a", "middle", "b", "last", "c"]));

      var tree = const StructuredEvaluator().evaluate(result.rawMarks, input: "abc");
      var outer = tree["start.outer"].single as ParseResult;
      expect(outer.span, equals("abc"));
      expect(outer.children.map((e) => e.$1), equals(["first", "middle", "last"]));
    });
  });
}
