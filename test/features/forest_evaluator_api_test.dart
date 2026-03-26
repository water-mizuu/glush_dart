import 'package:glush/glush.dart';
import 'package:test/test.dart';

void main() {
  group('Forest Evaluator API', () {
    test('evaluateParseTreeWith supports mark handlers and labels', () {
      final parser =
          r'''
            start = $full file:rule;
            rule = $rule name:name _ ":" _ body:name;
            name = [a-z]+;
            _ = $ws [ \t]*;
          '''
              .toSMParser();

      final forestOutcome = parser.parseWithForest('alpha:beta');
      expect(forestOutcome, isA<ParseForestSuccess>());
      final tree = (forestOutcome as ParseForestSuccess).forest.extract().first;

      final evaluator = Evaluator<Object?>({
        'full': (ctx) => ctx<Object?>('file'),
        'rule': (ctx) => (ctx<String>('name'), ctx<Object?>('body')),
        'name': (ctx) => ctx.span,
        'ws': (ctx) => ctx.span,
      });

      final value = parser.evaluateParseTreeWith(tree, 'alpha:beta', evaluator);
      expect(value, equals(('alpha', 'beta')));
    });

    test('extractParseTreeRawMarks includes label and named marks', () {
      final parser =
          r'''
            start = $full file:item;
            item = $item left:name;
            name = [a-z]+;
          '''
              .toSMParser();

      final forestOutcome = parser.parseWithForest('abc');
      expect(forestOutcome, isA<ParseForestSuccess>());
      final tree = (forestOutcome as ParseForestSuccess).forest.extract().first;

      final marks = parser.extractParseTreeRawMarks(tree, 'abc');
      expect(marks.any((m) => m is LabelStartMark && m.name == 'full'), isTrue);
      expect(marks.any((m) => m is LabelEndMark && m.name == 'full'), isTrue);
      expect(marks.any((m) => m is LabelStartMark && m.name == 'item'), isTrue);
      expect(marks.any((m) => m is LabelEndMark && m.name == 'item'), isTrue);
      expect(marks.any((m) => m is LabelStartMark && m.name == 'file'), isTrue);
      expect(marks.any((m) => m is LabelEndMark && m.name == 'file'), isTrue);
      expect(marks.any((m) => m is LabelStartMark && m.name == 'left'), isTrue);
      expect(marks.any((m) => m is LabelEndMark && m.name == 'left'), isTrue);

      final fileEnd = marks.whereType<LabelEndMark>().firstWhere((m) => m.name == 'file');
      final itemEnd = marks.whereType<LabelEndMark>().firstWhere((m) => m.name == 'item');
      final leftEnd = marks.whereType<LabelEndMark>().firstWhere((m) => m.name == 'left');

      expect(fileEnd.position, equals(0));
      expect(itemEnd.position, equals(0));
      expect(leftEnd.position, equals(0));
    });

    test('evaluateChildren skips unhandled siblings until it finds a handler', () {
      final tree = ParseResult([
        ('ws', ParseResult([], ' ')),
        ('value', ParseResult([], 'beta')),
      ], ' beta');

      final evaluator = Evaluator<String>({'value': (ctx) => ctx.span});

      expect(evaluator.evaluate(tree), equals('beta'));
    });
  });
}
