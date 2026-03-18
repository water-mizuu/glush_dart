import 'package:test/test.dart';
import 'package:glush/glush.dart';

void main() {
  group('Grammar DSL', () {
    test('creates basic grammar', () {
      final grammar = Grammar(() {
        final rule = Rule('expr', () => Eps());
        return rule;
      });

      expect(grammar, isNotNull);
      expect(grammar.startCall, isNotNull);
    });

    test('handles token matching', () {
      final grammar = Grammar(() {
        final rule = Rule('expr', () {
          final token = Token(ExactToken(97)); // 'a'
          return token;
        });
        return rule;
      });

      expect(grammar, isNotNull);
    });
  });

  group('Pattern operations', () {
    test('sequence operator works', () {
      final p1 = Token(ExactToken(97));
      final p2 = Token(ExactToken(98));
      final seq = p1 >> p2;

      expect(seq, isA<Seq>());
    });

    test('alternation operator works', () {
      final p1 = Token(ExactToken(97));
      final p2 = Token(ExactToken(98));
      final alt = p1 | p2;

      expect(alt, isA<Alt>());
    });

    test('repetition works', () {
      final token = Token(ExactToken(97));
      expect(token.maybe(), isA<Alt>());
    });
  });

  group('SMParser', () {
    test('recognizes balanced parentheses', () {
      final grammar = Grammar(() {
        late final expr;
        expr = Rule('expr', () {
          return Eps() |
              (Token(ExactToken(40)) >>
                  Call(expr) >>
                  Token(ExactToken(41))); // ( expr )
        });
        return expr;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize(''), isTrue);
      expect(parser.recognize('()'), isTrue);
      expect(parser.recognize('(())'), isTrue);
      expect(parser.recognize('('), isFalse);
      expect(parser.recognize('(()'), isFalse);
    });

    test('recognizes simple patterns', () {
      final grammar = Grammar(() {
        final rule = Rule('expr', () => Token(ExactToken(97))); // 'a'
        return rule;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('a'), isTrue);
      expect(parser.recognize('b'), isFalse);
      expect(parser.recognize(''), isFalse);
    });

    test('recognizes sequences', () {
      final grammar = Grammar(() {
        final rule = Rule(
          'expr',
          () => Token(ExactToken(97)) >> Token(ExactToken(98)),
        ); // ab
        return rule;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('ab'), isTrue);
      expect(parser.recognize('a'), isFalse);
      expect(parser.recognize('ba'), isFalse);
    });

    test('recognizes alternation', () {
      final grammar = Grammar(() {
        final rule = Rule(
          'expr',
          () => Token(ExactToken(97)) | Token(ExactToken(98)),
        ); // a or b
        return rule;
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('a'), isTrue);
      expect(parser.recognize('b'), isTrue);
      expect(parser.recognize('c'), isFalse);
    });

    test('handles marks', () {
      final grammar = Grammar(() {
        final rule = Rule('expr', () {
          return Marker('mark') >> Token(ExactToken(97));
        });
        return rule;
      });

      final parser = SMParser(grammar);
      final result = parser.parse('a');

      expect(result, isA<ParseSuccess>());
      if (result is ParseSuccess) {
        final parserResult = result.result;
        expect(parserResult.marks, isNotEmpty);
        expect(parserResult.marks[0], 'mark');
      }
    });
  });

  group('Error handling', () {
    test('parse error on mismatch', () {
      final grammar = Grammar(() {
        final rule = Rule('expr', () => Token(ExactToken(97)));
        return rule;
      });

      final parser = SMParser(grammar);
      final result = parser.parse('b');

      expect(result, isA<ParseError>());
      if (result is ParseError) {
        expect(result.position, 0);
      }
    });

    test('parse error at correct position', () {
      final grammar = Grammar(() {
        final rule = Rule('expr', () {
          return Token(ExactToken(97)) >>
              Token(ExactToken(98)) >>
              Token(ExactToken(99));
        });
        return rule;
      });

      final parser = SMParser(grammar);
      final result = parser.parse('axx');

      expect(result, isA<ParseError>());
      if (result is ParseError) {
        expect(result.position, 1);
      }
    });
  });

  group('Enumeration vs Forest Extraction', () {
    /// Helper: extract label from ParseDerivation for structure comparison
    String _derivationShape(ParseDerivation d) {
      // Use the symbol ID directly since we don't have grammar context in tests
      final label = d.symbol;
      if (d.children.isEmpty) return label as String;
      return '$label(${d.children.map(_derivationShape).join(',')})';
    }

    /// Helper: extract label from ParseTree for structure comparison
    String _treeShape(ParseTree t) {
      late String label;
      if (t.node is SymbolicNode) {
        label = (t.node as SymbolicNode).symbol as String;
      } else if (t.node is TerminalNode) {
        final token = (t.node as TerminalNode).token;
        label = String.fromCharCode(token);
      } else if (t.node is EpsilonNode) {
        label = 'ε';
      } else if (t.node is IntermediateNode) {
        label = (t.node as IntermediateNode).description as String;
      } else {
        label = t.node.toString();
      }

      if (t.children.isEmpty) return label;
      return '$label(${t.children.map(_treeShape).join(',')})';
    }

    test('counts match for simple unambiguous grammar', () {
      final grammar = Grammar(() {
        final rule = Rule('expr', () => Token(ExactToken(97))); // 'a'
        return rule;
      });

      final parser = SMParser(grammar);
      final derivations = parser.enumerateAllParses('a').toList();

      final forestResult = parser.parseWithForest('a');
      expect(forestResult, isA<ParseForestSuccess>());

      if (forestResult is ParseForestSuccess) {
        final trees = forestResult.forest.extract().toList();
        expect(derivations.length, equals(trees.length));
        expect(derivations.length, equals(1));
      }
    });

    test('counts match for simple ambiguous grammar S->SS|ε', () {
      final grammar = Grammar(() {
        late final s;
        s = Rule('S', () => Eps() | (Call(s) >> Call(s)));
        return s;
      });

      final parser = SMParser(grammar);
      const testInput = '';
      final derivations = parser.enumerateAllParses(testInput).toList();

      final forestResult = parser.parseWithForest(testInput);
      expect(forestResult, isA<ParseForestSuccess>());

      if (forestResult is ParseForestSuccess) {
        final trees = forestResult.forest.extract().toList();
        expect(derivations.length, equals(trees.length));
        expect(derivations.length, equals(1)); // ε produces exactly one parse
      }
    });

    test('counts match for ambiguous grammar with input', () {
      final grammar = Grammar(() {
        late final s;
        s = Rule(
          'S',
          () => Eps() | (Token(ExactToken(97)) >> Call(s) >> Call(s)),
        );
        return s;
      });

      final parser = SMParser(grammar);
      const testInput = 'a';
      final derivations = parser.enumerateAllParses(testInput).toList();

      final forestResult = parser.parseWithForest(testInput);
      expect(forestResult, isA<ParseForestSuccess>());

      if (forestResult is ParseForestSuccess) {
        final trees = forestResult.forest.extract().toList();
        expect(derivations.length, equals(trees.length));
      }
    });

    test('tree structures match for S->SS|s grammar', () {
      final grammar = Grammar(() {
        late final s;
        s = Rule('S', () {
          return Token(ExactToken(115)) | (Call(s) >> Call(s)); // s | SS
        });
        return s;
      });

      final parser = SMParser(grammar);
      const testInput = 'ss';
      final derivations = parser.enumerateAllParses(testInput).toList();

      final forestResult = parser.parseWithForest(testInput);
      expect(forestResult, isA<ParseForestSuccess>());

      if (forestResult is ParseForestSuccess) {
        final trees = forestResult.forest.extract().toList();

        // Both should find the same number of parses
        expect(derivations.length, equals(trees.length));

        // Get tree shapes from both approaches
        final derivShapes = derivations.map(_derivationShape).toSet();
        final treeShapes = trees.map(_treeShape).toSet();

        // Both should have the same structural representations
        expect(derivShapes.length, equals(treeShapes.length));
      }
    });

    test('counts match for left-recursive grammar', () {
      final grammar = Grammar(() {
        late final expr;
        expr = Rule('expr', () {
          return Token(ExactToken(97)) // a
              |
              (Call(expr) >> Token(ExactToken(43)) >> Call(expr)); // expr+expr
        });
        return expr;
      });

      final parser = SMParser(grammar);
      const testInput = 'a+a';
      final derivations = parser.enumerateAllParses(testInput).toList();

      final forestResult = parser.parseWithForest(testInput);
      expect(forestResult, isA<ParseForestSuccess>());

      if (forestResult is ParseForestSuccess) {
        final trees = forestResult.forest.extract().toList();
        expect(derivations.length, equals(trees.length));
      }
    });

    test('counts match for nested alternation', () {
      final grammar = Grammar(() {
        late final a;
        late final b;
        a = Rule('A', () {
          return (Token(ExactToken(97)) >> Call(b)) | Eps();
        });
        b = Rule('B', () {
          return (Token(ExactToken(98)) >> Call(a)) | Eps();
        });
        return a;
      });

      final parser = SMParser(grammar);
      const testInput = 'ab';
      final derivations = parser.enumerateAllParses(testInput).toList();

      final forestResult = parser.parseWithForest(testInput);
      expect(forestResult, isA<ParseForestSuccess>());

      if (forestResult is ParseForestSuccess) {
        final trees = forestResult.forest.extract().toList();
        expect(derivations.length, equals(trees.length));
      }
    });

    test('empty parse produces same count for both', () {
      final grammar = Grammar(() {
        final rule = Rule('expr', () => Eps());
        return rule;
      });

      final parser = SMParser(grammar);
      final derivations = parser.enumerateAllParses('').toList();

      final forestResult = parser.parseWithForest('');
      expect(forestResult, isA<ParseForestSuccess>());

      if (forestResult is ParseForestSuccess) {
        final trees = forestResult.forest.extract().toList();
        expect(derivations.length, equals(trees.length));
        expect(derivations.length, equals(1));
      }
    });

    test('both fail gracefully on non-matching input', () {
      final grammar = Grammar(() {
        final rule = Rule('expr', () => Token(ExactToken(97))); // 'a'
        return rule;
      });

      final parser = SMParser(grammar);
      final derivations = parser.enumerateAllParses('b').toList();

      final forestResult = parser.parseWithForest('b');
      expect(forestResult, isA<ParseError>());

      // Both should have no parses for invalid input
      expect(derivations.length, equals(0));
    });

    test('counts match for more complex ambiguity S->SSS|SS|s', () {
      final grammar = Grammar(() {
        late final Rule s;
        s = Rule('S', () {
          return Token.char('s') | // s
              (Marker('') >> s() >> s()).withAction((_, c) => [...c]) | // SS
              (Marker('') >> s() >> s() >> s()).withAction((_, c) => [...c]) |
              (Marker('') >> s() >> s() >> s() >> s()).withAction(
                (_, c) => [...c],
              ); // SSS
        });
        return s;
      });

      final parser = SMParser(grammar);
      const testInput = 'sssss';
      final derivationCount = parser.countAllParses(testInput);
      final derivations = parser.enumerateAllParses(testInput).toList();
      final forestResult = parser.parseWithForest(testInput);
      expect(forestResult, isA<ParseForestSuccess>());

      if (forestResult is ParseForestSuccess) {
        Set<String> enumerations =
            derivations //
                .map((s) => s.toPrecedenceString(testInput))
                .toSet();
        Set<String> forestExtracted = forestResult.forest
            .extract()
            .map((s) => s.toPrecedenceString(testInput))
            .toSet();

        final trees = forestResult.forest.extract().toList();
        expect(enumerations, equals(forestExtracted));
        expect(forestExtracted, equals(enumerations));
        expect(enumerations.difference(forestExtracted), equals(<String>{}));
        expect(forestExtracted.difference(enumerations), equals(<String>{}));
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
  });
}
