import 'package:test/test.dart';
import 'package:glush/glush.dart';

void main() {
  group('Deeply recursive grammars', () {
    test('parses right recursive grammars correctly', () {
      final grammar = Grammar(() {
        late final Rule S;
        S = Rule(
          'S',
          () =>
              Token.char('s') | //
              Token.char('s') >> Token.char("+") >> S.call(),
        );

        return S;
      });

      SMParser parser = SMParser(grammar);
      for (int count = 20; count <= 500; count += 20) {
        final input = "s+" * count + "s";

        expect(parser.parse(input), isNotNull);
        expect(parser.parseWithForest(input), isNotNull);
      }
    });

    test('parses right left grammars correctly', () {
      final grammar = Grammar(() {
        late final Rule S;
        S = Rule(
          'S',
          () =>
              Token.char('s') | //
              S.call() >> Token.char("+") >> Token.char('s'),
        );

        return S;
      });

      final parser = SMParser(grammar);

      for (int count = 20; count <= 500; count += 20) {
        final input = "s+" * count + "s";

        expect(parser.parse(input), isNotNull);
        expect(parser.parseWithForest(input), isNotNull);
      }
    });
  });
}
