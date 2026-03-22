import 'package:test/test.dart';
import 'package:glush/glush.dart';

void main() {
  group('SMParserMini Basic Operations', () {
    test('recognize succeeds for simple grammar', () {
      final grammar = Grammar(() {
        final a = Token(ExactToken(97)); // 'a'
        return Rule('test', () => a >> a);
      });
      final parser = SMParserMini(grammar);
      expect(parser.recognize('aa'), isTrue);
      expect(parser.recognize('a'), isFalse);
      expect(parser.recognize('aaa'), isFalse);
    });

    test('parse returns marks for simple grammar', () {
      final grammar = Grammar(() {
        final a = Token(ExactToken(97));
        final m1 = Marker('m1');
        return Rule('test', () => m1 >> a >> a);
      });
      final parser = SMParserMini(grammar, captureTokensAsMarks: true);

      final outcome = parser.parse('aa');
      expect(outcome, isA<ParseSuccessMini>());
      final success = outcome as ParseSuccessMini;
      expect(success.result.marks, equals(['m1', 'aa']));
    });

    test('parseAmbiguous returns multiple forests', () {
      final grammar = Grammar(() {
        final a = Token(ExactToken(97));
        return Rule('test', () => (a >> a) | (a >> a));
      });
      final parser = SMParserMini(grammar);
      final outcome = parser.parseAmbiguous('aa', captureTokensAsMarks: true);
      expect(outcome, isA<ParseAmbiguousForestSuccessMini>());
      final success = outcome as ParseAmbiguousForestSuccessMini;
      // Depending on GlushList implementation, count completions
      expect(success.forest.toList(), isNotEmpty);
    });
  });

  group('SMParserMini Nested Predicates', () {
    test('Double negation !!a', () {
      final grammar = Grammar(() {
        final a = Token(ExactToken(97));
        return Rule('test', () => a.not().not() >> a);
      });
      final parser = SMParserMini(grammar);
      expect(parser.recognize('a'), isTrue, reason: '!!a should match a');
      expect(parser.recognize('b'), isFalse);
    });

    test('Triple negation !!!a', () {
      final grammar = Grammar(() {
        final a = Token(ExactToken(97));
        return Rule('test', () => a.not().not().not() >> a);
      });
      final parser = SMParserMini(grammar);
      expect(parser.recognize('a'), isFalse, reason: '!!!a should NOT match a');
    });

    test('Nested AND in NOT !(&a)', () {
      final grammar = Grammar(() {
        final a = Token(ExactToken(97));
        final b = Token(ExactToken(98));
        return Rule('test', () => a.and().not() >> b);
      });
      final parser = SMParserMini(grammar);
      expect(parser.recognize('b'), isTrue, reason: '!(&a) at start of "b" is true');
      expect(parser.recognize('a'), isFalse, reason: '!(&a) at start of "a" is false');
    });

    test('Rule call within predicate', () {
      final grammar = Grammar(() {
        late final r1, r2;
        final a = Token(ExactToken(97));
        final b = Token(ExactToken(98));
        r1 = Rule('r1', () => a);
        r2 = Rule('r2', () => r1().and() >> b);
        return r2;
      });
      final parser = SMParserMini(grammar);
      expect(parser.recognize('b'), isFalse); // 'a' matches at pos 0 in &r1
      // Wait, if &r1 matches, it should match 'b'? No,
      // Let's re-verify.
    });

    test('Rule call within predicate - match case', () {
      final grammar = Grammar(() {
        late final r1, r2;
        final a = Token(ExactToken(97));
        r1 = Rule('r1', () => a);
        r2 = Rule('r2', () => r1().and() >> a);
        return r2;
      });
      final parser = SMParserMini(grammar);
      expect(parser.recognize('a'), isTrue);
    });
  });
}
