import 'package:glush/glush.dart';

void main() {
  final grammar = Grammar(() {
    late final Rule s;
    s = Rule('S', () {
      return Marker('') >>
          (Token.char('s') | // s
              (s() >> s()) |
              (s() >> s() >> s()) |
              (s() >> s() >> s() >> s()));
    });
    return s;
  });

  const testInput = 'ssss';
  final parser = SMParser(grammar);
  
  print('Enumerations:');
  for (final d in parser.enumerateAllParses(testInput)) {
    print('  ${d.toTreeString(testInput)}');
  }

  print('\nForest extracted:');
  final forestResult = parser.parseWithForest(testInput);
  if (forestResult is ParseForestSuccess) {
    for (final tree in forestResult.forest.extract()) {
      print('  ${tree.toPrecedenceString(testInput)}');
    }
  }
}
