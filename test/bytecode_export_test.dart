import "dart:convert";

import "package:glush/glush.dart";
import "package:glush/src/parser/bytecode/bytecode_parser.dart";
import "package:test/test.dart";

void main() {
  group("BCParser Export/Import", () {
    test("Simple grammar round-trip", () {
      var grammar = Grammar(() {
        return Rule("main", () => Token.char("a") | Token.char("b"));
      });

      var originalParser = BCParser(grammar);
      var exported = originalParser.export();
      var jsonStr = jsonEncode(exported);

      var importedData = jsonDecode(jsonStr) as Map<String, Object?>;
      var importedParser = BCParser.import(importedData);

      expect(importedParser.recognize("a"), isTrue);
      expect(importedParser.recognize("b"), isTrue);
      expect(importedParser.recognize("c"), isFalse);
    });

    test("Recursive grammar round-trip", () {
      var grammar = Grammar(() {
        late Rule expr;
        expr = Rule("expr", () {
          return Token.char("a") | (Token.char("(") >> expr() >> Token.char(")"));
        });
        return expr;
      });

      var originalParser = BCParser(grammar);
      var exported = originalParser.export();
      var jsonStr = jsonEncode(exported);

      var importedData = jsonDecode(jsonStr) as Map<String, Object?>;
      var importedParser = BCParser.import(importedData);

      expect(importedParser.recognize("a"), isTrue);
      expect(importedParser.recognize("(a)"), isTrue);
      expect(importedParser.recognize("((a))"), isTrue);
      expect(importedParser.recognize("(a"), isFalse);
      expect(importedParser.recognize("((a)"), isFalse);
    });

    test("Grammar with labels and constants round-trip", () {
      var grammar = Grammar(() {
        return Rule("main", () => Label("X", Token.char("x")) >> Label("Y", Token.char("y")));
      });

      var originalParser = BCParser(grammar);
      var exported = originalParser.export();
      var jsonStr = jsonEncode(exported);

      var importedData = jsonDecode(jsonStr) as Map<String, Object?>;
      var importedParser = BCParser.import(importedData);

      expect(importedParser.recognize("xy"), isTrue);
      expect(importedParser.recognize("x"), isFalse);

      // Verify constants were preserved
      expect(importedParser.machine.constants.strings, contains("X"));
      expect(importedParser.machine.constants.strings, contains("Y"));
    });

    test("Grammar with precedence round-trip", () {
      var grammar = Grammar(() {
        late Rule E;
        E = Rule("E", () {
          return Token(const RangeToken(48, 57)).atLevel(11) |
              (E() >> Token.char("*") >> E()).atLevel(7) |
              (E() >> Token.char("+") >> E()).atLevel(6);
        });
        return E;
      });

      var originalParser = BCParser(grammar);
      var exported = originalParser.export();

      var importedParser = BCParser.import(exported);

      expect(importedParser.recognize("1+2*3"), isTrue);
      expect(importedParser.recognize("1*2+3"), isTrue);
    });

    test("Grammar with predicates and admissibility round-trip", () {
      var grammar = Grammar(() {
        // S = & 'a' 'a' | ! 'a' 'b'
        return Rule(
          "S",
          () =>
              (And(Token.char("a")) >> Token.char("a")) | (Not(Token.char("a")) >> Token.char("b")),
        );
      });

      var originalParser = BCParser(grammar);
      var exported = originalParser.export();

      var importedParser = BCParser.import(exported);

      expect(importedParser.recognize("a"), isTrue);
      expect(importedParser.recognize("b"), isTrue);
      expect(importedParser.recognize("c"), isFalse);
      expect(importedParser.recognize("aa"), isFalse);
    });

    test("Full expression grammar complexity", () {
      const grammarDef = r"""
        Result = Expr
        Expr = Term (('+' | '-') Term)*
        Term = Factor (('*' | '/') Factor)*
        Factor = Number | '(' Expr ')'
        Number = [0-9]+
      """;

      var grammar = grammarDef.toGrammar();
      var originalParser = BCParser(grammar);
      var exported = originalParser.export();

      var importedParser = BCParser.import(
        jsonDecode(jsonEncode(exported)) as Map<String, Object?>,
      );

      const testInputs = {
        "1+2*3": true,
        "(1+2)*3": true,
        "10+20-5": true,
        "100/10+5": true,
        "1+": false,
        "(1+2": false,
        "a+b": false,
      };

      for (var entry in testInputs.entries) {
        expect(
          importedParser.recognize(entry.key),
          equals(entry.value),
          reason: "Failed for input: ${entry.key}",
        );
      }
    });

    test("Left recursion round-trip", () {
      var grammar = Grammar(() {
        late Rule A;
        A = Rule("A", () {
          return (A() >> Token.char("b")) | Token.char("a");
        });
        return A;
      });

      var importedParser = BCParser.import(BCParser(grammar).export());

      expect(importedParser.recognize("a"), isTrue);
      expect(importedParser.recognize("ab"), isTrue);
      expect(importedParser.recognize("abb"), isTrue);
      expect(importedParser.recognize("b"), isFalse);
    });

    test("Right recursion round-trip", () {
      var grammar = Grammar(() {
        late Rule A;
        A = Rule("A", () {
          return (Token.char("a") >> A()) | Token.char("a");
        });
        return A;
      });

      var importedParser = BCParser.import(BCParser(grammar).export());

      expect(importedParser.recognize("a"), isTrue);
      expect(importedParser.recognize("aa"), isTrue);
      expect(importedParser.recognize("aaa"), isTrue);
      expect(importedParser.recognize("b"), isFalse);
    });

    test("Indirect recursion round-trip", () {
      var grammar = Grammar(() {
        late Rule A, B;
        A = Rule("A", () => Token.char("a") >> B());
        B = Rule("B", () => A() | Token.char("b"));
        return A;
      });

      var importedParser = BCParser.import(BCParser(grammar).export());

      expect(importedParser.recognize("ab"), isTrue);
      expect(importedParser.recognize("aab"), isTrue);
      expect(importedParser.recognize("aaab"), isTrue);
      expect(importedParser.recognize("a"), isFalse);
      expect(importedParser.recognize("b"), isFalse);
    });

    test("Ambiguous grammar round-trip", () {
      var grammar = Grammar(() {
        late Rule S;
        S = Rule("S", () => (Token.char("a") >> S()) | (S() >> Token.char("a")) | Token.char("a"));
        return S;
      });

      var originalParser = BCParser(grammar);
      var exported = originalParser.export();
      var importedParser = BCParser.import(exported);

      for (var input in ["a", "aa", "aaa"]) {
        var originalOutcome = originalParser.parseAmbiguous(input);
        var importedOutcome = importedParser.parseAmbiguous(input);

        var originalSuccess = originalOutcome.ambiguousSuccess();
        var importedSuccess = importedOutcome.ambiguousSuccess();

        expect(importedSuccess, isNotNull);
        expect(importedSuccess!.forest.derivationCount, equals(originalSuccess!.forest.derivationCount));
        
        // Compare the sets of result paths (using short marks for comparison)
        var originalPaths = originalSuccess.forest.allMarkPaths().map((p) => p.toShortMarks()).toSet();
        var importedPaths = importedSuccess.forest.allMarkPaths().map((p) => p.toShortMarks()).toSet();
        
        expect(importedPaths, equals(originalPaths));
      }
    });

    test("Epsilon (empty) matching round-trip", () {
      var grammar = Grammar(() {
        return Rule("S", () => Token.char("a").opt());
      });

      var importedParser = BCParser.import(BCParser(grammar).export());

      expect(importedParser.parse("a").success(), isNotNull);
      expect(importedParser.parse("").success(), isNotNull);
      expect(importedParser.parse("b").error(), isNotNull);
    });

    test("Nested labels round-trip", () {
      var grammar = Grammar(() {
        return Rule(
          "main",
          () => Label("Outer", Token.char("a") >> Label("Inner", Token.char("b"))),
        );
      });

      var importedParser = BCParser.import(BCParser(grammar).export());

      var outcome = importedParser.parse("ab");
      var success = outcome.success();
      expect(success, isNotNull);
      expect(success!.marks, equals(["Outer", "Inner"]));
      
      expect(importedParser.machine.constants.strings, contains("Outer"));
      expect(importedParser.machine.constants.strings, contains("Inner"));
    });

    test("Explicit epsilon rule round-trip", () {
      var grammar = Grammar(() {
        late Rule S, E;
        E = Rule("E", () => Eps());
        S = Rule("S", () => Token.char("a") >> E() >> Token.char("b"));
        return S;
      });

      var importedParser = BCParser.import(BCParser(grammar).export());

      expect(importedParser.parse("ab").success(), isNotNull);
      expect(importedParser.parse("a").error(), isNotNull);
    });
  });
}
