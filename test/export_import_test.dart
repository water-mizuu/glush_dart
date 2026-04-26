import "dart:io";

import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("StateMachine Export/Import", () {
    test("Round-trip preserves character ranges and complex structures", () {
      const grammarDef = r"""
        Result = Expr
        Expr = Term (('+' | '-') Term)*
        Term = Factor (('*' | '/') Factor)*
        Factor = Number | '(' Expr ')'
        Number = [0-9]+
      """;

      var grammar = grammarDef.toGrammar();
      var originalParser = SMParser(grammar);

      var exportedJson = originalParser.stateMachine.exportToJson();
      var importedParser = SMParser.fromImported(exportedJson);

      const testInputs = ["1+2*3", "(1+2)*3", "10+20-5", "100/10+5"];

      for (var input in testInputs) {
        var state1 = originalParser.createParseState();
        for (var code in input.codeUnits) {
          state1.processToken(code);
        }
        state1.finish();

        var state2 = importedParser.createParseState();
        for (var code in input.codeUnits) {
          state2.processToken(code);
        }
        state2.finish();

        expect(state2.accept, equals(state1.accept), reason: 'Input "$input" failure');
      }
    });

    test("Preserves anchors and predicates", () {
      const grammarDef = r"""
        S = ^ 'a' $ | & 'b' 'b'
      """;

      var grammar = grammarDef.toGrammar();
      var originalParser = SMParser(grammar);

      var exportedJson = originalParser.stateMachine.exportToJson();
      var importedParser = SMParser.fromImported(exportedJson);

      var inputs = {
        "a": true,
        "b": true, // & 'b' is lookahead, then 'b' matches
        "bb": false, // 'b' matches the first char, then EOF expected but found 'b'
        "aa": false,
      };

      for (var entry in inputs.entries) {
        var input = entry.key;
        var expected = entry.value;

        var state = importedParser.createParseState();
        for (var code in input.codeUnits) {
          state.processToken(code);
        }
        state.finish();

        expect(
          state.accept,
          equals(expected),
          reason: 'Input "$input" failure (Expected $expected, got ${state.accept})',
        );
      }
    });

    test("Preserves rule calls with precedence", () {
      const grammarDef = r"""
        E = 11| [0-9]
             7| E '*' E
             6| E '+' E
      """;

      var grammar = grammarDef.toGrammar();
      var originalParser = SMParser(grammar);

      var exportedJson = originalParser.stateMachine.exportToJson();
      var importedParser = SMParser.fromImported(exportedJson);

      const input = "1+2*3";

      var state1 = originalParser.createParseState();
      for (var code in input.codeUnits) {
        state1.processToken(code);
      }
      state1.finish();

      var state2 = importedParser.createParseState();
      for (var code in input.codeUnits) {
        state2.processToken(code);
      }
      state2.finish();

      expect(state2.accept, isTrue);
    });

    test("Preserves data-driven parsers, guards, and complex features grammar-lessly", () {
      const grammarText = r"""
        start = strict | lenient

        strict = invoke(payload: wrapper, policy: "strict")
        lenient = invoke(payload: wrapper, policy: "lenient")

        invoke(payload, policy) =
              if (policy == "strict") payload(piece: atom) atom
            | if (policy == "lenient") payload(piece: atom)

        wrapper = '[' pair(piece: atom) ']'
        pair(piece) = piece piece
        atom = 'a' | 'b' | 'c'
      """;

      var originalParser = grammarText.toSMParser();
      var exportedJson = originalParser.stateMachine.exportToJson();
      File("exported.json")
        ..createSync(recursive: true)
        ..writeAsStringSync(exportedJson);

      // Import WITHOUT passing the grammar!
      var importedParser = SMParser.fromImported(exportedJson);

      var inputs = [
        ("[aa]a", true),
        ("[aa]", true),
        ("[bb]b", true),
        ("[aa]d", false),
        ("[ad]a", false),
      ];

      for (var (input, expected) in inputs) {
        var state = importedParser.createParseState();
        for (var code in input.codeUnits) {
          state.processToken(code);
        }
        state.finish();

        expect(
          state.accept,
          equals(expected),
          reason: 'Input "$input" failure (Expected $expected, got ${state.accept})',
        );
      }
    });

    test("Preserves mathematical parameter calls and indentation grammar-lessly", () {
      late Rule indent;
      late Rule indentStep;
      late Rule indentBase;
      late Rule program;
      late Rule block;
      late Rule stmt;
      late Rule nested;
      var space = Token.char(" ");
      var colon = Token.char(":");
      var newline = Token.char("\n");
      var code = Token.charRange("a", "z").plus();

      indent = Rule("indent", () {
        var target = CallArgumentValue.reference("target");
        return indentStep.call(arguments: {"target": target}) |
            indentBase.call(arguments: {"target": target});
      });

      indentStep = Rule("indent_step", () {
        return indent.call(
              arguments: {
                "target": CallArgumentValue.binary(
                  CallArgumentValue.reference("target"),
                  ExpressionBinaryOperator.subtract,
                  CallArgumentValue.literal(1),
                ),
              },
            ) >>
            space;
      }).guardedBy(GuardValue.argument("target").gt(0));

      indentBase = Rule("indent_base", () => Eps()).guardedBy(GuardValue.argument("target").eq(0));

      block = Rule("block", () {
        var lvl = CallArgumentValue.reference("lvl");
        return (stmt.call(arguments: {"lvl": lvl}) | nested.call(arguments: {"lvl": lvl})).plus();
      });

      stmt = Rule("stmt", () {
        var lvl = CallArgumentValue.reference("lvl");
        return indent.call(arguments: {"target": lvl}) >> code >> newline;
      });

      nested = Rule("nested", () {
        var lvl = CallArgumentValue.reference("lvl");
        return indent.call(arguments: {"target": lvl}) >>
            colon >>
            newline >>
            block.call(
              arguments: {
                "lvl": CallArgumentValue.binary(
                  lvl,
                  ExpressionBinaryOperator.add,
                  CallArgumentValue.literal(4),
                ),
              },
            );
      });

      program = Rule("program", () => block.call(arguments: {"lvl": CallArgumentValue.literal(0)}));
      var originalParser = SMParser(Grammar(() => program));
      var exportedJson = originalParser.stateMachine.exportToJson();
      var importedParser = SMParser.fromImported(exportedJson);

      expect(importedParser.recognize("aaa\nbbb\n"), isTrue);
      expect(importedParser.recognize(":\n    aaa\n"), isTrue);
      expect(
        importedParser.recognize("aaa\n:\n    bbb\n    :\n        ccc\n    ddd\neee\n"),
        isTrue,
      );
      expect(importedParser.recognize(":\n  aaa\n"), isFalse);
    });

    test("Preserves advanced data-driven parsing (XML matching) grammar-lessly", () {
      const grammarText = r"""
        start = element

        element =
              openTag body closeTag(tag)

        openTag =
              '<' tag:name '>'

        closeTag(tag) =
              '</' close:name '>' verify(tag, close)

        verify(open, close) = if (open == close) ''

        body =
              text

        text =
              [A-Za-z ]+

        name = [A-Za-z_] [A-Za-z0-9_]*
      """;

      var originalParser = grammarText.toSMParser();
      var exportedJson = originalParser.stateMachine.exportToJson();
      var importedParser = SMParser.fromImported(exportedJson);

      expect(importedParser.recognize("<book>Hello</book>"), isTrue);
      expect(importedParser.recognize("<book>Hello</author>"), isFalse);
    });
  });
}
