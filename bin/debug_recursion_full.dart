import 'package:glush/glush.dart';
import 'package:glush/src/sm_parser.dart';

void main() {
  const depth = 5; // Moderate depth
  final grammar = Grammar(() {
    late final Rule e;
    final digit = Token.char('1');
    final plus = Token.char('+');

    e = Rule('E', () => (digit >> plus >> e.call()) | digit);
    return e.call();
  });

  final input = '1+' * depth + '1';
  final parser = SMParser(grammar);

  print('Testing Input: $input');
  
  final res = parser.recognize(input);
  print('Recognize: $res');

  if (res) {
    final outcome = parser.parseWithForest(input);
    if (outcome is ParseForestSuccess) {
      print('Forest Success!');
      final tree = outcome.forest.extract().first;
      final node = tree.node;
      if (node is SymbolicNode) {
        print('Tree Extracted: ${node.symbol}');
      } else {
        print('Tree Extracted: $node');
      }
      
      final eval = parser.evaluateParseTree(tree, input);
      print('Eval Result: $eval');
    } else {
      print('Forest Failure: $outcome');
    }
  }
}
