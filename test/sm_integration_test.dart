import 'package:glush/glush.dart';
import 'package:test/test.dart';

void main() {
  group('State Machine Integrated Features', () {
    test('Simple sequence S = a b c', () {
      final parser =
          r"""
        S = 'a' 'b' 'c'
      """
              .toSMParser();

      final result = parser.parseAmbiguous('abc');
      expect(result, isA<ParseAmbiguousForestSuccess>());
      final success = result as ParseAmbiguousForestSuccess;
      expect(success.forest.allPaths().length, equals(1));
    });

    test('Shared Forest prevents exponential explosion', () {
      // Highly ambiguous grammar: S -> S S | 'a'
      final parser =
          r"""
        S = S S | 'a'
      """
              .toSMParser();

      final input = 'a' * 5;
      final result = parser.parseAmbiguous(input, captureTokensAsMarks: true);

      expect(result, isA<ParseAmbiguousForestSuccess>());
      final success = result as ParseAmbiguousForestSuccess;

      // For N=5, the number of derivations is the 4th Catalan number = 14
      final paths = success.forest.allPaths();
      expect(paths.length, equals(14));
    });

    test('Precedence Filtering', () {
      // Classic math grammar with precedence
      final parser =
          r"""
        expr =
            6| $add expr^6 '+' expr^7
            7| $mul expr^7 '*' expr^8
           11| 'n'
      """
              .toSMParser();

      // Input: n + n * n
      // Unambiguous with precedence: (n + (n * n))
      final result = parser.parseAmbiguous('n+n*n', captureTokensAsMarks: true);
      expect(result, isA<ParseAmbiguousForestSuccess>());
      final success = result as ParseAmbiguousForestSuccess;

      final paths = success.forest.allPaths().map((p) => p.toShortMarks()).toList();
      expect(paths.length, equals(1));
      expect(paths[0].join(''), equals('addn+muln*n'));
    });

    test('Predicate Catch-up and Sub-parse', () {
      // Grammar with a predicate rule
      final parser =
          r"""
        S = &Target 'a' 'b' 'c'
        Target = 'a' 'b'
      """
              .toSMParser();

      final result = parser.parseAmbiguous('abc', captureTokensAsMarks: true);
      expect(result, isA<ParseAmbiguousForestSuccess>());
      final success = result as ParseAmbiguousForestSuccess;
      expect(success.forest.allPaths().length, equals(1));
    });

    test('Context Deduplication fixes explosion', () {
      // This grammar is right-recursive and ambiguous (S -> aS | a)
      // Actually it's not ambiguous for 'aaa' unless we have another rule.
      // S -> s S | s s | s
      final parser2 =
          r"""
        S = 's' S | 's' 's' | 's'
      """
              .toSMParser();

      final input = 's' * 20;
      final result = parser2.parseAmbiguous(input, captureTokensAsMarks: true);
      expect(result, isA<ParseAmbiguousForestSuccess>());
    });
  });
}
