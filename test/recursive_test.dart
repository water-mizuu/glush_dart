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
      double previous = 1;
      for (int count = 20; count <= 500; count += 20) {
        Stopwatch watch = Stopwatch()..start();
        final input = "s+" * count + "s";

        expect(parser.parse(input), isNotNull);
        expect(parser.parseWithForest(input), isNotNull);
        watch..stop();
        print(
          "Finished $count in ${watch.elapsedMicroseconds}us "
          "(${watch.elapsedMicroseconds / previous}x)",
        );
        previous = watch.elapsedMicroseconds.toDouble();
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

      double previous = 1;
      for (int count = 20; count <= 500; count += 20) {
        Stopwatch watch = Stopwatch()..start();
        final input = "s+" * count + "s";

        expect(parser.parse(input), isNotNull);
        expect(parser.parseWithForest(input), isNotNull);
        watch..stop();
        print(
          "Finished $count in ${watch.elapsedMicroseconds}us "
          "(${watch.elapsedMicroseconds / previous}x)",
        );
        previous = watch.elapsedMicroseconds.toDouble();
      }
    });
  });
}
