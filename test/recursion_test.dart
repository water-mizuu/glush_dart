import 'package:glush/glush.dart';
import 'package:test/test.dart';

void main() {
  group('Stack Overflow Prevention Tests', () {
    test('Large Expression Tree Evaluation', () {
      // Create a very deep expression tree (e.g., 1 + 1 + 1 ... + 1)
      const depth = 500;
      final grammar = Grammar(() {
        late final Rule e;
        final digit = Token(RangeToken('0'.codeUnitAt(0), '9'.codeUnitAt(0)));
        final plus = Token.char('+');

        e = Rule('E', () => (digit >> plus >> e.call()) | digit);
        return e.call();
      });

      final input = '1+' * depth + '1';
      final parser = SMParser(grammar);

      // Recognition should be fine (it uses an iterative state machine)
      expect(parser.recognize(input), isTrue);

      // Parsing to forest and evaluating
      final outcome = parser.parseWithForest(input);
      expect(outcome, isA<ParseForestSuccess>());

      final forest = (outcome as ParseForestSuccess).forest;
      final tree = forest.extract().first;

      // Iterative evaluation should not blow the stack
      expect(() => parser.evaluateParseTree(tree, input), returnsNormally);

      final result = parser.evaluateParseTree(tree, input);
      expect(result, isNotNull);
    });

    test('Deeply Nested Sequence Cartesian Product', () {
      // Create a forest that has many combinations (though here we just care about depth)
      // A (B (C (D ...)))
      const depth = 2000;
      final grammar = Grammar(() {
        final rules = <Rule>[];
        for (int i = 0; i <= depth; i++) {
          final level = i;
          rules.add(Rule('R$level', () {
            if (level < depth) {
              return rules[level + 1].call();
            } else {
              return Token.char('a');
            }
          }));
        }
        return rules[0].call();
      });

      final input = 'a';
      final parser = SMParser(grammar);

      final outcome = parser.parseWithForest(input);
      final forest = (outcome as ParseForestSuccess).forest;

      // Counting nodes iteratively
      expect(() => forest.countNodes(), returnsNormally);

      // Extracting tree (uses iterative Cartesian product)
      expect(() => forest.extract().first, returnsNormally);
    });
  });
}
