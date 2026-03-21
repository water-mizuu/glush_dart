import 'package:test/test.dart';
import 'package:glush/glush.dart';

void main() {
  group('SMParser Feature and Edge Case Suite', () {
    test('1. Deep Left & Right Recursion (Context Safety)', () {
      final p1 = r"L = L 'a' | 'a'".toSMParser();
      final p2 = r"R = 'b' R | 'b'".toSMParser();

      // Ensure no stack overflow on deep paths
      expect(p1.parseAmbiguous('a' * 100), isA<ParseAmbiguousForestSuccess>());
      expect(p2.parseAmbiguous('b' * 100), isA<ParseAmbiguousForestSuccess>());
    });

    test('2. Precedence and Associativity (Complex)', () {
      final parser =
          r"""
            E = $ADD E '+' T
              | T
            T = $MUL T '*' F
              | F
            F = $POW P '^' F
              | P
            P = $NUM 'n'
              | '(' E ')'
          """
              .trim()
              .toSMParser();

      final evaluator = Evaluator<String>(
        (consume) => {
          'ADD': () {
            final l = consume<String>();
            consume<String>(); // skip '+'
            final r = consume<String>();
            return "($l + $r)";
          },
          'MUL': () {
            final l = consume<String>();
            consume<String>(); // skip '*'
            final r = consume<String>();
            return "($l * $r)";
          },
          'POW': () {
            final l = consume<String>();
            consume<String>(); // skip '^'
            final r = consume<String>();
            return "($l ^ $r)";
          },
          'NUM': () => consume<String>(),
        },
      );

      // (n + (n * (n ^ n)))
      final result = parser.parseAmbiguous('n+n*n^n', captureTokensAsMarks: true);
      expect(result, isA<ParseAmbiguousForestSuccess>());

      final forest = (result as ParseAmbiguousForestSuccess).forest;
      final val = evaluator.evaluate(forest.allPaths().first.toMarkStrings());
      expect(val, equals('(n + (n * (n ^ n)))'));
    });

    test('3. Regex Operators with Ambiguity', () {
      final parser = r"S = $LIST ('a' | 'a')*".toSMParser();

      final result = parser.parseAmbiguous('aaa', captureTokensAsMarks: true);
      expect(result, isA<ParseAmbiguousForestSuccess>());

      final forest = (result as ParseAmbiguousForestSuccess).forest;
      final paths = forest.allPaths();
      expect(paths.length, equals(1));
    });

    test('4. Named Marks in Repetition', () {
      final parser = r"S = ($A 'a' | $B 'a')+".toSMParser();

      final result = parser.parseAmbiguous('aa', captureTokensAsMarks: true);
      expect(result, isA<ParseAmbiguousForestSuccess>());

      final forest = (result as ParseAmbiguousForestSuccess).forest;
      // Paths: (A, A), (A, B), (B, A), (B, B) = 4 paths
      expect(forest.allPaths().length, equals(4));
    });

    // test('5. Epsilon (Empty Match) in Shared Forest', () {
    //   final parser = r"S = $OPT 'a'? $END 'b'".toSMParser();

    //   final evaluator = Evaluator<String>((consume) => {'OPT': () => "opt", 'END': () => "end"});

    //   expect(
    //     parser.parseAmbiguous('ab', captureTokensAsMarks: true),
    //     isA<ParseAmbiguousForestSuccess>(),
    //   );
    //   final result = parser.parseAmbiguous('b', captureTokensAsMarks: true);
    //   expect(result, isA<ParseAmbiguousForestSuccess>());

    //   final forest = (result as ParseAmbiguousForestSuccess).forest;
    //   final val = evaluator.evaluate(forest.allPaths().first.toMarkStrings());
    //   expect(val, contains('opt'));
    //   expect(val, contains('end'));
    // }, timeout: Timeout(const Duration(seconds: 1)));

    test('6. Cyclic Epsilon Grammar (Protection)', () {
      final parser = r"S = S | 'a'".toSMParser();

      expect(
        parser.parseAmbiguous('a', captureTokensAsMarks: true),
        isA<ParseAmbiguousForestSuccess>(),
      );
    }, timeout: Timeout(const Duration(seconds: 1)));

    // test('7. Mark Collision and Nesting', () {
    //   final parser =
    //       r"""
    // S = $M A $M B
    // A = 'a'
    // B = 'b'
    // """
    //           .trim()
    //           .toSMParser();

    //   print(parser.stateMachine.grammar.rules.map((v) => (v, v.body())).join("\n"));

    //   final result = parser.parseAmbiguous('ab', captureTokensAsMarks: true);
    //   expect(result, isA<ParseAmbiguousForestSuccess>());

    //   final forest = (result as ParseAmbiguousForestSuccess).forest;
    //   final marks = forest.allPaths().first.toMarkStrings();
    //   expect(marks.where((m) => m == 'mark').length, equals(2));
    // });

    test('8. Dangling Else (Precedence)', () {
      final parser =
          r"""
            S = $ELSE "if" _ S _ "else" _ S
              | $IF "if" _ S
              | 'a';

            _ = [ \t\n\r]*;
          """
              .toSMParser();
      final result = parser.parseAmbiguous('if if a else a', captureTokensAsMarks: true);
      expect(result, isA<ParseAmbiguousForestSuccess>());

      final forest = (result as ParseAmbiguousForestSuccess).forest;
      expect(forest.allPaths().length, equals(2));
    }, timeout: Timeout(const Duration(seconds: 1)));

    test('9. Predicate Interactions', () {
      final parser = r"S = &('a' 'b') 'a' 'b'".toSMParser();

      expect(
        parser.parseAmbiguous('ab', captureTokensAsMarks: true),
        isA<ParseAmbiguousForestSuccess>(),
      );
      expect(parser.parseAmbiguous('ac', captureTokensAsMarks: true), isA<ParseError>());
    });
  }, timeout: Timeout(const Duration(seconds: 1)));
}
