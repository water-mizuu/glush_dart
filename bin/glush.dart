import 'package:glush/glush.dart';

import 'helper.dart';

void main() async {
  const grammarText = r'''
    expr = $add expr _ '+' _ term | $sub expr _ '-' _ term | term;
    term = $mul term _ '*' _ factor | $div term _ '/' _ factor | factor;
    factor = $group '(' _ expr _ ')'
           | $number [0-9]+;
    _ = [ \t\n\r]*;
  ''';

  // Test the spawnProcessParser function
  final processParser = await spawnProcessParser(grammarText);
  print('Parser spawned successfully!');

  final result = await processParser.parse('1+2*(3+4)');
  print('Parse result: $result');

  final markEvaluator = Evaluator<num>((consume) {
    return {
      "add": () => consume<num>() + consume<num>(),
      "sub": () => consume<num>() - consume<num>(),
      "mul": () => consume<num>() * consume<num>(),
      "div": () => consume<num>() / consume<num>(),
      "group": () => consume<num>(),
      "number": () => num.parse(consume<String>()),
    };
  });

  if (result case ["ok", List<String> marks]) {
    print(markEvaluator.evaluate(marks));
  }

  await processParser.dispose();
  print('Parser disposed.');
}
