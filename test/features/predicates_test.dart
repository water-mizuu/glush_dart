import 'package:test/test.dart';
import 'package:glush/glush.dart';

void main() {
  group('AND Predicates (&)', () {
    test('AND succeeds when pattern matches', () {
      final grammar = Grammar(() {
        final r = Rule('test', () {
          final a = Token(ExactToken(97));
          return a.and() >> a;
        });
        return r;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('a'), isTrue);
      expect(parser.recognize('b'), isFalse);
    });

    test('AND prevents matching when pattern doesnt match', () {
      final grammar = Grammar(() {
        final r = Rule('test', () {
          final a = Token(ExactToken(97));
          final b = Token(ExactToken(98));
          return b.and() >> a;
        });
        return r;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('a'), isFalse);
      expect(parser.recognize('b'), isFalse);
    });

    test('AND doesnt consume input', () {
      final grammar = Grammar(() {
        final r = Rule('test', () {
          final b = Token(ExactToken(98));
          return b.and() >> b;
        });
        return r;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('b'), isTrue);
      expect(parser.recognize('a'), isFalse);
    });

    test('AND with rule calls', () {
      final grammar = Grammar(() {
        late final expr;
        final a = Token(ExactToken(97));
        final b = Token(ExactToken(98));

        expr = Rule('expr', () => a | (b.and() >> a));
        return expr;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('a'), isTrue);
      expect(parser.recognize('b'), isFalse);
    });
  });

  group('NOT Predicates (!)', () {
    test('NOT succeeds when pattern fails', () {
      final grammar = Grammar(() {
        final r = Rule('test', () {
          final a = Token(ExactToken(97));
          final b = Token(ExactToken(98));
          return b.not() >> a;
        });
        return r;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('a'), isTrue);
      expect(parser.recognize('b'), isFalse);
    });

    test('NOT prevents matching when pattern matches', () {
      final grammar = Grammar(() {
        final r = Rule('test', () {
          final a = Token(ExactToken(97));
          return a.not() >> a;
        });
        return r;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('a'), isFalse);
      expect(parser.recognize('b'), isFalse);
    });

    test('NOT doesnt consume input', () {
      final grammar = Grammar(() {
        final r = Rule('test', () {
          final a = Token(ExactToken(97));
          final b = Token(ExactToken(98));
          return a.not() >> b;
        });
        return r;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('b'), isTrue);
      expect(parser.recognize('a'), isFalse);
    });

    test('NOT with alternation', () {
      final grammar = Grammar(() {
        final r = Rule('test', () {
          final a = Token(ExactToken(97));
          final b = Token(ExactToken(98));
          final c = Token(ExactToken(99));
          return (b | c).not() >> a;
        });
        return r;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('a'), isTrue);
      expect(parser.recognize('b'), isFalse);
      expect(parser.recognize('c'), isFalse);
    });

    test('Double negation', () {
      final grammar = Grammar(() {
        final r = Rule('test', () {
          final a = Token(ExactToken(97));
          final b = Token(ExactToken(98));
          return b.not().not() >> a;
        });
        return r;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('a'), isFalse);
      expect(parser.recognize('b'), isFalse);
    });

    test('NOT in rule calls', () {
      final grammar = Grammar(() {
        late final expr;
        final a = Token(ExactToken(97));
        final b = Token(ExactToken(98));

        expr = Rule('expr', () => a | (b.not() >> a));
        return expr;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('a'), isTrue);
    });

    test('NOT at end of input', () {
      final grammar = Grammar(() {
        final r = Rule('test', () {
          final a = Token(ExactToken(97));
          final b = Token(ExactToken(98));
          return a >> b.not();
        });
        return r;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('a'), isTrue);
      expect(parser.recognize('ab'), isFalse);
    });
  });

  group('Combined AND/NOT patterns', () {
    test('AND with sequence lookahead', () {
      final grammar = Grammar(() {
        final r = Rule('test', () {
          final a = Token(ExactToken(97));
          final b = Token(ExactToken(98));
          final c = Token(ExactToken(99));
          return (b >> c).and() >> a;
        });
        return r;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('a'), isFalse);
    });

    test('NOT with sequence lookahead', () {
      final grammar = Grammar(() {
        final r = Rule('test', () {
          final a = Token(ExactToken(97));
          final b = Token(ExactToken(98));
          final c = Token(ExactToken(99));
          return (b >> c).not() >> a;
        });
        return r;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('a'), isTrue);
      expect(parser.recognize('b'), isFalse);
      expect(parser.recognize('abc'), isFalse);
    });

    test('Multiple predicates in sequence', () {
      final grammar = Grammar(() {
        final r = Rule('test', () {
          final a = Token(ExactToken(97));
          final b = Token(ExactToken(98));
          final c = Token(ExactToken(99));
          return a >> b.and() >> c.not() >> b;
        });
        return r;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('ab'), isTrue);
      expect(parser.recognize('abc'), isFalse);
    });

    test('Predicate in alternation', () {
      final grammar = Grammar(() {
        final r = Rule('test', () {
          final a = Token(ExactToken(97));
          final b = Token(ExactToken(98));
          final c = Token(ExactToken(99));
          return (a >> b.and()) | c;
        });
        return r;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('c'), isTrue);
      expect(parser.recognize('a'), isFalse);
    });

    test('Lookahead in left-recursive rule', () {
      final grammar = Grammar(() {
        late final expr;
        final a = Token(ExactToken(97));
        final b = Token(ExactToken(98));

        expr = Rule('expr', () => b.not() >> a | expr() >> a);
        return expr;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('a'), isTrue);
      expect(parser.recognize('aa'), isTrue);
      expect(parser.recognize('aaa'), isTrue);
      expect(parser.recognize('b'), isFalse);
    });
  });

  group('Predicate edge cases', () {
    test('Predicate with epsilon', () {
      final grammar = Grammar(() {
        final r = Rule('test', () {
          final a = Token(ExactToken(97));
          return Eps().and() >> a;
        });
        return r;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('a'), isTrue);
      expect(parser.recognize('b'), isFalse);
    });

    test('Negation of epsilon', () {
      final grammar = Grammar(() {
        final r = Rule('test', () {
          final a = Token(ExactToken(97));
          return Eps().not() >> a;
        });
        return r;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('a'), isFalse);
    });

    test('Complex alternation in lookahead', () {
      final grammar = Grammar(() {
        final r = Rule('test', () {
          final a = Token(ExactToken(97));
          final b = Token(ExactToken(98));
          final c = Token(ExactToken(99));
          final d = Token(ExactToken(100));
          return (b | c | d).and() >> a;
        });
        return r;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('a'), isFalse);
    });
  });

  group('Predicate with semantic actions', () {
    test('Predicate followed by semantic action', () {
      final grammar = Grammar(() {
        final r = Rule('test', () {
          final a = Token(ExactToken(97));
          final b = Token(ExactToken(98));
          return (b.not() >> a).withAction((span, _) => 'matched_$span');
        });
        return r;
      });

      final parser = SMParser(grammar);
      final result = parser.parse('a');
      expect(result, isA<ParseSuccess>());
    });
  });

  group('Predicate performance - no backtracking', () {
    test('Lookahead doesnt consume on failure', () {
      final grammar = Grammar(() {
        final r = Rule('test', () {
          final a = Token(ExactToken(97));
          final b = Token(ExactToken(98));
          final c = Token(ExactToken(99));
          return (b.and() >> a) | c;
        });
        return r;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('a'), isFalse);
      expect(parser.recognize('c'), isTrue);
    });
  });

  group('Integration with forest and enumeration', () {
    test('Predicate with forest parsing', () {
      final grammar = Grammar(() {
        final r = Rule('test', () {
          final a = Token(ExactToken(97));
          final b = Token(ExactToken(98));
          return b.not() >> a;
        });
        return r;
      });

      final parser = SMParser(grammar);
      final result = parser.parseWithForest('a');
      expect(result, isA<ParseForestSuccess>());
    });

    test('Predicate with enumeration', () {
      final grammar = Grammar(() {
        final r = Rule('test', () {
          final a = Token(ExactToken(97));
          final b = Token(ExactToken(98));
          return b.not() >> a;
        });
        return r;
      });

      final parser = SMParser(grammar);
      final derivations = parser.enumerateAllParses('a').toList();
      expect(derivations, isNotEmpty);
    });
  });

  group('Advanced predicate scenarios', () {
    test('Keyword recognition with negative lookahead', () {
      final grammar = Grammar(() {
        final r = Rule('keyword', () {
          final w = Token(ExactToken(119));
          final h = Token(ExactToken(104));
          final i = Token(ExactToken(105));
          final l = Token(ExactToken(108));
          final e = Token(ExactToken(101));
          final letter = Token(RangeToken(97, 122));

          return (w >> h >> i >> l >> e) >> letter.not();
        });
        return r;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('while'), isTrue);
    });

    test('Multiple predicates chained', () {
      final grammar = Grammar(() {
        final a = Token(ExactToken(97));
        final b = Token(ExactToken(98));
        return Rule('test', () => a.and() >> b.not() >> a);
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('a'), isTrue);
      expect(parser.recognize('ba'), isFalse);
      expect(parser.recognize('abc'), isFalse);
    });

    test('Predicate in deeply nested rules', () {
      final grammar = Grammar(() {
        late final e1, e2, e3;
        final a = Token(ExactToken(97));
        final b = Token(ExactToken(98));

        e1 = Rule('e1', () => a | e2());
        e2 = Rule('e2', () => b.not() >> e3());
        e3 = Rule('e3', () => a);

        return e1;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('a'), isTrue);
    });
  });
}
