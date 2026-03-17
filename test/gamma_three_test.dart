import 'package:glush/glush.dart';
import 'package:test/test.dart';

void main() {
  test('counts match for more complex ambiguity S->SSS|SS|s', () {
    final grammar = Grammar(() {
      late final Rule s;
      s = Rule('S', () {
        return Eps() |
            Token.char('s') | // s
            (s() >> s()) |
            (s() >> s() >> s());
      });
      return s;
    });

    final parser = SMParser(grammar);
    const testInput = 'ssss';
    final derivationCount = parser.countAllParses(testInput);
    final derivations = parser.enumerateAllParses(testInput).toList();
    final forestResult = parser.parseWithForest(testInput);
    expect(forestResult, isA<ParseForestSuccess>());
    if (forestResult is ParseForestSuccess) {
      final trees = forestResult.forest.extract().toList();
      for (final derivation in derivations) {
        print(derivation.toTreeString(testInput));
      }
      // Both enumeration and forest extraction should find the same number
      expect(derivations.length, equals(trees.length));
      expect(derivations.length, equals(derivationCount));
      // sss has 3 parse trees:
      // 1. SSS -> s+s+s
      // 2. SS -> (s+s)+s
      // 3. SS -> s+(s+s)
      expect(derivations.length, equals(44));
    }
  });
}
