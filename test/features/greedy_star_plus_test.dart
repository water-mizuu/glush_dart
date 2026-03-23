import 'package:glush/glush.dart';
import 'package:test/test.dart';

void main() {
  group('Greedy Star/Plus', () {
    test('star keeps the longest prefix before the following token', () {
      final parser = "S = head:('a'*) tail:('a')".toSMParser(captureTokensAsMarks: true);
      final outcome = parser.parse('aaa');

      expect(outcome, isA<ParseSuccess>());
      final tree = StructuredEvaluator().evaluate((outcome as ParseSuccess).result.rawMarks);
      final head = (tree.get('head').first as ParseResult).span;
      final tail = (tree.get('tail').first as ParseResult).span;

      expect(head, equals('aa'));
      expect(tail, equals('a'));
    });

    test('plus keeps the longest prefix before the following token', () {
      final parser = "S = head:('a'+) tail:('a')".toSMParser(captureTokensAsMarks: true);
      final outcome = parser.parse('aaa');

      expect(outcome, isA<ParseSuccess>());
      final tree = StructuredEvaluator().evaluate((outcome as ParseSuccess).result.rawMarks);
      final head = (tree.get('head').first as ParseResult).span;
      final tail = (tree.get('tail').first as ParseResult).span;

      expect(head, equals('aa'));
      expect(tail, equals('a'));
    });
  });
}
