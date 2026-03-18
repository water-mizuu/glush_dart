import 'package:glush/glush.dart';
import 'package:test/test.dart';

int counter = 0;

void main() {
  group('gamma 3 related bugs', () {
    evaluateGamma3(
      Grammar(() {
        late final Rule s;
        s = Rule('S', () {
          return Token.char('s') | // s
              (s() >> s()) |
              (s() >> s() >> s()) |
              (s() >> s() >> s() >> s());
        });
        return s;
      }),
    );

    evaluateGamma3(
      Grammar(() {
        late final Rule s;
        s = Rule('S', () {
          return Token.char('s') | // s
              (Marker('') >> s() >> s()) |
              (Marker('') >> s() >> s() >> s()) |
              (Marker('') >> s() >> s() >> s() >> s());
        });
        return s;
      }),
    );

    evaluateGamma3(
      Grammar(() {
        late final Rule s;
        s = Rule('S', () {
          return Marker('T') >>
              (Token.char('s') | // s
                  (s() >> s()) |
                  (s() >> s() >> s()) |
                  (s() >> s() >> s() >> s()));
        });
        return s;
      }),
    );
  });
}

void evaluateGamma3(Grammar grammar) {
  const testInput = 'ssss';
  final parser = SMParser(grammar);
  final derivationCount = parser.countAllParses(testInput);
  final derivations = parser.enumerateAllParses(testInput).toList();
  final forestResult = parser.parseWithForest(testInput);
  test('Grammar ${counter++}', () {
    expect(forestResult, isA<ParseForestSuccess>());

    if (forestResult is ParseForestSuccess) {
      Set<String> enumerations = derivations
          .map((s) => s)
          .map((s) => s.toPrecedenceString(testInput))
          .toSet();
      Set<String> forestExtracted = forestResult.forest
          .extract()
          .map((s) => s.toPrecedenceString(testInput))
          .toSet();

      final trees = forestResult.forest.extract().toList();
      expect(enumerations.difference(forestExtracted), equals(<String>{}));
      expect(forestExtracted.difference(enumerations), equals(<String>{}));
      // Both enumeration and forest extraction should find the same number
      expect(derivations.length, equals(trees.length));
      expect(derivations.length, equals(derivationCount));
      // sss has 3 parse trees:
      // 1. SSS -> s+s+s
      // 2. SS -> (s+s)+s
      // 3. SS -> s+(s+s)
      expect(derivations.length, equals(11));
    }
  });
}
