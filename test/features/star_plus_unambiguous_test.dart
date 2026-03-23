import 'package:glush/glush.dart';
import 'package:test/test.dart';

void main() {
  group('Star/Plus Unambiguous Behavior', () {
    test('word list with whitespace separators has one parse', () {
      final parser =
          r'''
            start = word (ws+ word)*;
            word = [a-z]+;
            ws = [ \t\n\r];
          '''
              .toSMParser();

      final input = 'alpha   beta\tgamma\n\tdelta';

      final ambiguous = parser.parseAmbiguous(input);
      expect(ambiguous, isA<ParseAmbiguousForestSuccess>());
      final paths = (ambiguous as ParseAmbiguousForestSuccess).forest.allPaths();
      expect(paths.length, equals(1));

      final forest = parser.parseWithForest(input);
      expect(forest, isA<ParseForestSuccess>());
      final trees = (forest as ParseForestSuccess).forest.extract().toList();
      expect(trees.length, equals(1));
    });

    test('leading/trailing whitespace with token body has one parse', () {
      final parser =
          r'''
            start = ws* body ws*;
            body = [a-z]+;
            ws = [ \t\n\r];
          '''
              .toSMParser();

      const input = '   hello_world   ';

      // This input should fail because '_' is not in [a-z], proving we are not
      // silently accepting via ambiguous epsilon/repetition behavior.
      expect(parser.parse(input), isA<ParseError>());

      const validInput = '   helloworld   ';
      final ambiguous = parser.parseAmbiguous(validInput);
      expect(ambiguous, isA<ParseAmbiguousForestSuccess>());
      final paths = (ambiguous as ParseAmbiguousForestSuccess).forest.allPaths();
      expect(paths.length, equals(1));

      final forest = parser.parseWithForest(validInput);
      expect(forest, isA<ParseForestSuccess>());
      final trees = (forest as ParseForestSuccess).forest.extract().toList();
      expect(trees.length, equals(1));
    });

    test('star followed by explicit token remains deterministic for whitespace', () {
      final parser = r"start = [ \t]* 'x';".toSMParser();

      final ambiguous = parser.parseAmbiguous('   \t  x');
      expect(ambiguous, isA<ParseAmbiguousForestSuccess>());
      final paths = (ambiguous as ParseAmbiguousForestSuccess).forest.allPaths();
      expect(paths.length, equals(1));

      final forest = parser.parseWithForest('   \t  x');
      expect(forest, isA<ParseForestSuccess>());
      final trees = (forest as ParseForestSuccess).forest.extract().toList();
      expect(trees.length, equals(1));
    });

    test('plus in token runs is deterministic', () {
      final parser = r"start = [a-z]+;".toSMParser();

      final ambiguous = parser.parseAmbiguous('letters');
      expect(ambiguous, isA<ParseAmbiguousForestSuccess>());
      final paths = (ambiguous as ParseAmbiguousForestSuccess).forest.allPaths();
      expect(paths.length, equals(1));

      final forest = parser.parseWithForest('letters');
      expect(forest, isA<ParseForestSuccess>());
      final trees = (forest as ParseForestSuccess).forest.extract().toList();
      expect(trees.length, equals(1));
    });
  });
}
