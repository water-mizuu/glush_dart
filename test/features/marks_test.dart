import 'package:glush/glush.dart';
import 'package:test/test.dart';

void main() {
  group('Intuitive Marks (Labels)', () {
    test('Labeled patterns produce LabelMarks', () async {
      final grammar = Grammar(() {
        final ident = Token(const RangeToken(97, 122)).plus();
        final rule = Rule('start', () {
          return Label('name', ident) >>
              Token(const ExactToken(58)) >> // :
              Label('value', ident);
        });
        return rule;
      });

      final parser = SMParser(grammar, captureTokensAsMarks: true);
      final outcome = parser.parse('user:michael');

      expect(outcome, isA<ParseSuccess>());
      final result = (outcome as ParseSuccess).result;

      final marks = result.rawMarks;
      final evaluator = StructuredEvaluator();
      final tree = evaluator.evaluate(marks);

      expect(tree.get('name').first.span, equals('user'));
      expect(tree.get('value').first.span, equals('michael'));
      expect(tree.span, equals('user:michael'));
    });

    test('Grammar string syntax support for labels', () {
      final parser =
          '''
        start = user:ident ":" pass:ident;
        ident = [a-z]+;
      '''
              .toSMParser(captureTokensAsMarks: true);

      final outcome = parser.parse('alice:secret');

      expect(outcome, isA<ParseSuccess>());
      final result = (outcome as ParseSuccess).result;

      final evaluator = StructuredEvaluator();
      final tree = evaluator.evaluate(result.rawMarks);

      expect(tree['user'].first.span, equals('alice'));
      expect(tree['pass'].first.span, equals('secret'));
    });

    test('Nested labels', () {
      final parser =
          '''
        start = person:(first:ident " " last:ident);
        ident = [A-Z][a-z]*;
      '''
              .toSMParser(captureTokensAsMarks: true);

      final outcome = parser.parse('John Doe');

      expect(outcome, isA<ParseSuccess>());
      final result = (outcome as ParseSuccess).result;

      final evaluator = StructuredEvaluator();
      final tree = evaluator.evaluate(result.rawMarks);

      final person = tree['person'].first as ParseResult;
      expect(person['first'].first.span, equals('John'));
      expect(person['last'].first.span, equals('Doe'));
      expect(person.span, equals('John Doe'));
    });

    test('Mismatched label nesting fails fast in strict mode', () {
      final evaluator = StructuredEvaluator();

      expect(
        () => evaluator.evaluateStrict([
          LabelStartMark('outer', 0),
          LabelStartMark('inner', 1),
          LabelEndMark('outer', 0),
          StringMark('x', 3),
        ]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Mismatched label end "outer"'),
          ),
        ),
      );
    });
  });
}
