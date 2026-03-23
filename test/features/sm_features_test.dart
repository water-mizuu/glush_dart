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

      final evaluator = Evaluator<String>({
        'ADD': (ctx) => "(${ctx.next()} + ${ctx.next()})",
        'MUL': (ctx) => "(${ctx.next()} * ${ctx.next()})",
        'POW': (ctx) => "(${ctx.next()} ^ ${ctx.next()})",
        'NUM': (ctx) => ctx.span,
      });

      // (n + (n * (n ^ n)))
      final result = parser.parseAmbiguous('n+n*n^n', captureTokensAsMarks: true);
      expect(result, isA<ParseAmbiguousForestSuccess>());

      final forest = (result as ParseAmbiguousForestSuccess).forest;
      final val = evaluator.evaluate(StructuredEvaluator().evaluate(forest.allPaths().first));
      expect(val, equals('(n + (n * (n ^ n)))'));
    });

    test('3. Regex Operators with Ambiguity', () {
      final parser = r"S = $LIST ('a' | 'a')*".toSMParser();

      final result = parser.parseAmbiguous('aaa');
      expect(result, isA<ParseAmbiguousForestSuccess>());

      final forest = (result as ParseAmbiguousForestSuccess).forest;
      final paths = forest.allPaths();
      expect(paths.length, equals(1));
    });

    test('4. Named Marks in Repetition', () {
      final parser = r"S = ($A 'a' | $B 'a')+".toSMParser();

      final result = parser.parseAmbiguous('aa', captureTokensAsMarks: true);
      expect(result, isA<ParseAmbiguousForestSuccess>());
      if (result case ParseAmbiguousForestSuccess(:var forest)) {
        // Paths: (A, A), (A, B), (B, A), (B, B) = 4 paths
        expect(forest.allPaths().length, equals(4));
      }
    });

    test('5. Epsilon (Empty Match) in Shared Forest', () {
      final parser = r"S = $OPT 'a'? $END 'b'".toSMParser();
      expect(
        parser.parseAmbiguous('ab', captureTokensAsMarks: true),
        isA<ParseAmbiguousForestSuccess>(),
      );
      final result = parser.parseAmbiguous('b', captureTokensAsMarks: true);
      expect(result, isA<ParseAmbiguousForestSuccess>());

      final forest = (result as ParseAmbiguousForestSuccess).forest;
      final marksConcat = forest.allPaths().single.toStringList().join(" ");
      expect(marksConcat, contains('OPT'));
      expect(marksConcat, contains('END'));
    });

    test('6. Cyclic Epsilon Grammar (Protection)', () {
      final parser = r"S = S | 'a'".toSMParser();

      expect(
        parser.parseAmbiguous('a', captureTokensAsMarks: true),
        isA<ParseAmbiguousForestSuccess>(),
      );
    });

    test('7. Mark Collision and Nesting', () {
      final parser =
          r"""
    S = $M A $M B
    A = 'a'
    B = 'b'
    """
              .trim()
              .toSMParser();

      final result = parser.parseAmbiguous('ab', captureTokensAsMarks: true);
      expect(result, isA<ParseAmbiguousForestSuccess>());

      final forest = (result as ParseAmbiguousForestSuccess).forest;
      final marks = forest.allPaths().first.toMarkStrings();
      expect(marks.where((m) => m == 'M').length, equals(2));
    });

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
    });

    test('9. Predicate Interactions', () {
      final parser = r"S = &('a' 'b') 'a' 'b'".toSMParser();

      expect(
        parser.parseAmbiguous('ab', captureTokensAsMarks: true),
        isA<ParseAmbiguousForestSuccess>(),
      );
      expect(parser.parseAmbiguous('ac', captureTokensAsMarks: true), isA<ParseError>());
    });
  });
}
