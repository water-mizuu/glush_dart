import 'package:glush/glush.dart';
import 'package:glush/src/sm_parser.dart';

void main() {
  final rule = Rule('M', () => Seq(Seq(Pattern.char('a'), Marker('m')), Pattern.char('b')));

  final grammar = Grammar(() => rule.call());
  final parser = SMParser(grammar, fastMode: true);

  const input = 'ab';
  final outcome = parser.parseWithForest(input);

  if (outcome is ParseForestSuccess) {
    final forest = outcome.forest;
    print('Forest nodes: ${forest.countNodes()}');

    final trees = forest.extract();
    for (final tree in trees) {
      print('Tree:');
      print(tree.toTreeString());

      final derivation = parseTreeToDerivation(tree, input);
      final value = parser.evaluateParseDerivation(derivation, input);
      print('Evaluated Value (including marks): $value');
    }
  } else {
    print('Parse failed');
  }
}
