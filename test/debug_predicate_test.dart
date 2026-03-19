import 'package:test/test.dart';
import 'package:glush/glush.dart';

void main() {
  // Simple test to debug predicates
  test('Simple AND predicate test', () {
    // Grammar: &'a' >> 'a'
    // This should match 'a' and only 'a'
    final grammar = Grammar(() {
      final a = Token(ExactToken(97)); // 'a'
      return Rule('test', () => a.and() >> a);
    });

    final parser = SMParser(grammar);

    expect(parser.recognize('a'), isTrue, reason: 'Should recognize "a"');
    expect(parser.recognize('b'), isFalse, reason: 'Should not recognize "b"');
  });
}
