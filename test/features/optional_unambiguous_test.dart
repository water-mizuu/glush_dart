import 'package:glush/glush.dart';
import 'package:test/test.dart';

void main() {
  group('Optional Unambiguous Behavior', () {
    test('optional whitespace around word has one parse', () {
      final parser =
          r'''
            start = ws? word ws?;
            word = [a-z]*;
            ws = [ \t\n\r]*;
          '''
              .toSMParser();

      const input = 'hello  ';
      final ambiguous = parser.parseAmbiguous(input);
      expect(ambiguous, isA<ParseAmbiguousForestSuccess>());
      final paths = (ambiguous as ParseAmbiguousForestSuccess).forest.allPaths();
      expect(paths.length, equals(1));

      final forest = parser.parseWithForest(input);
      expect(forest, isA<ParseForestSuccess>());
      final trees = (forest as ParseForestSuccess).forest.extract().toList();
      expect(trees.length, equals(1));
    });

    test('optional delimiter before mandatory delimiter is deterministic', () {
      final parser = r"start = ','? ',';".toSMParser();

      final ambiguous = parser.parseAmbiguous(',,');
      expect(ambiguous, isA<ParseAmbiguousForestSuccess>());
      final paths = (ambiguous as ParseAmbiguousForestSuccess).forest.allPaths();
      expect(paths.length, equals(1));
    });

    test('optional branch chooses epsilon only when child does not match', () {
      final parser = r"start = [a-z]? 'x';".toSMParser();

      expect(parser.parse('x'), isA<ParseSuccess>());
      expect(parser.parse('ax'), isA<ParseSuccess>());

      final ambiguous1 = parser.parseAmbiguous('x');
      final ambiguous2 = parser.parseAmbiguous('ax');
      expect((ambiguous1 as ParseAmbiguousForestSuccess).forest.allPaths().length, equals(1));
      expect((ambiguous2 as ParseAmbiguousForestSuccess).forest.allPaths().length, equals(1));
    });
  });
}
