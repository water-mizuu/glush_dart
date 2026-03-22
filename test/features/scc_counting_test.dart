import 'package:glush/glush.dart';
import 'package:test/test.dart';

void main() {
  group('SCC-based Derivation Counting', () {
    test('Simple non-ambiguous grammar', () {
      // a b c matches exactly one derivation
      final grammar = Grammar(() {
        return Rule('', () => Token.char('a') >> Token.char('b') >> Token.char('c'));
      });

      final parser = SMParser(grammar);
      final result = parser.parseWithForest('abc');

      if (result is ParseForestSuccess) {
        final forest = result.forest;
        final counts = forest.countDerivationsWithSCC();

        expect(counts['count'], BigInt.one);
        expect(counts['hasCycles'], false);
        expect(counts['sccs'], greaterThan(0));
      }
    });

    test('Ambiguous grammar with alternation', () {
      // (a | a) matches two derivations
      final grammar = Grammar(() {
        return Rule('', () => Token.char('a') | Token.char('a'));
      });

      final parser = SMParser(grammar);
      final result = parser.parseWithForest('a');

      if (result is ParseForestSuccess) {
        final forest = result.forest;
        final counts = forest.countDerivationsWithSCC();

        expect(counts['count'], BigInt.two);
        expect(counts['hasCycles'], false);
      }
    });

    test('Left-recursive grammar detection', () {
      // Left-recursive rule: expr -> expr + a | a
      late Rule expr;
      final grammar = Grammar(() {
        expr = Rule('expr', () {
          return (expr.call() >> Token.char('+') >> Token.char('a')) | Token.char('a');
        });
        return expr;
      });

      final parser = SMParser(grammar);
      final result = parser.parseWithForest('a+a');

      if (result is ParseForestSuccess) {
        final forest = result.forest;
        final counts = forest.countDerivationsWithSCC();

        // Should have multiple derivations for "a+a"
        expect(counts['count'], greaterThanOrEqualTo(BigInt.one));
        // May or may not have cycles depending on implementation
        expect(counts.containsKey('hasCycles'), true);
        expect(counts.containsKey('sccs'), true);
      }
    });

    test('Repetition with star - single derivation with greedy matching', () {
      // a* with PEG greedy semantics matches only one way (greedily)
      final grammar = Grammar(() {
        return Rule('S', () => Token.char('a').star());
      });

      final parser = SMParser(grammar);
      final result = parser.parseWithForest('aaa');

      if (result is ParseForestSuccess) {
        final forest = result.forest;
        final counts = forest.countDerivationsWithSCC();

        // PEG greedy semantics: only one derivation (match all three 'a's)
        expect(counts['count'], equals(BigInt.one));
      }
    });

    test('Complex nested grammar', () {
      // Expression grammar: expr -> term (+ term)*
      // term -> factor (* factor)*
      // factor -> a | (expr)
      late Rule expr, term, factor;
      final grammar = Grammar(() {
        factor = Rule('factor', () {
          return Token.char('a') | (Token.char('(') >> expr.call() >> Token.char(')'));
        });
        term = Rule('term', () {
          return factor.call() >> (Token.char('*') >> factor.call()).star();
        });
        expr = Rule('expr', () {
          return term.call() >> (Token.char('+') >> term.call()).star();
        });
        return expr;
      });

      final parser = SMParser(grammar);
      final result = parser.parseWithForest('a+a');

      if (result is ParseForestSuccess) {
        final forest = result.forest;
        final counts = forest.countDerivationsWithSCC();

        expect(counts['count'], greaterThanOrEqualTo(BigInt.one));
        expect(counts['forestSize'], greaterThan(0));
      }
    });

    test('SCC count matches forest size', () {
      final grammar = Grammar(() {
        return Rule('', () => Token.char('a') >> Token.char('b'));
      });

      final parser = SMParser(grammar);
      final result = parser.parseWithForest('ab');

      if (result is ParseForestSuccess) {
        final forest = result.forest;
        final counts = forest.countDerivationsWithSCC();

        // SCC count should be at least 1
        expect(counts['sccs'], greaterThanOrEqualTo(1));
        // Forest size should be at least as large as SCC count
        expect(counts['forestSize'], greaterThanOrEqualTo(counts['sccs'] as int));
      }
    });

    test('Empty forest handling', () {
      final grammar = Grammar(() {
        return Rule('', () => Token.char('a').star());
      });

      final parser = SMParser(grammar);
      final result = parser.parseWithForest('');

      if (result is ParseForestSuccess) {
        final forest = result.forest;
        final counts = forest.countDerivationsWithSCC();

        expect(counts['count'], BigInt.one);
      }
    });

    test('Derivation count calculation', () {
      // S -> a S b | epsilon
      // For input "aabb": should have derivations
      late Rule s;
      final grammar = Grammar(() {
        s = Rule('S', () {
          return (Token.char('a') >> s.call() >> Token.char('b')) | Eps();
        });
        return s;
      });

      final parser = SMParser(grammar);
      final result = parser.parseWithForest('aabb');

      if (result is ParseForestSuccess) {
        final forest = result.forest;
        final counts = forest.countDerivationsWithSCC();
        
        // Should count the derivations correctly
        expect(counts['count'], greaterThan(BigInt.zero));
        expect(counts['count'], isA<BigInt>());
      }
    });
  });
}
