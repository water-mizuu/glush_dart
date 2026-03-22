import 'package:test/test.dart';
import 'package:glush/glush.dart';

void main() {
  /// Runs a test for both SMParser and SMParserMini
  void testBoth(
    String name, //
    Grammar grammar,
    void Function(RecognizerAndMarksParser parser) body,
  ) {
    test('$name (Mini)', () => body(SMParserMini(grammar)));
    test('$name (Full)', () => body(SMParser(grammar)));
  }

  /// Extracts marks from either ParseSuccess or ParseSuccess
  List<String> getMarks(Object outcome) {
    if (outcome is ParseSuccess) return outcome.result.marks;
    if (outcome is ParseSuccess) return outcome.result.marks;
    return [];
  }

  group('Edge Case Tests - Minimal Grammars', () {
    testBoth(
      'Empty grammar (Start rule points to Eps)',
      Grammar(() {
        return Rule('start', () => Eps());
      }),
      (parser) {
        expect(parser.recognize(''), isTrue);
        expect(parser.recognize('a'), isFalse);
      },
    );

    testBoth(
      'Single token grammar',
      Grammar(() {
        return Rule('start', () => Token.char('a'));
      }),
      (parser) {
        expect(parser.recognize('a'), isTrue);
        expect(parser.recognize(''), isFalse);
        expect(parser.recognize('ab'), isFalse);
      },
    );

    testBoth(
      'Purely marker grammar',
      Grammar(() {
        return Rule('start', () => Marker('m'));
      }),
      (parser) {
        expect(parser.recognize(''), isTrue);
        final outcome = parser.parse('');
        expect(getMarks(outcome), contains('m'));
      },
    );
  });

  group('Edge Case Tests - Tokens', () {
    testBoth(
      'AnyToken (wildcard)',
      Grammar(() {
        return Rule('start', () => Token(const AnyToken()));
      }),
      (parser) {
        expect(parser.recognize('a'), isTrue);
        expect(parser.recognize(' '), isTrue);
        expect(parser.recognize('\n'), isTrue);
        expect(parser.recognize(''), isFalse);
      },
    );

    testBoth(
      'Token range boundaries',
      Grammar(() {
        return Rule('start', () => Token(const RangeToken(0, 255)));
      }),
      (parser) {
        expect(parser.recognize(String.fromCharCode(0)), isTrue);
        expect(parser.recognize(String.fromCharCode(255)), isTrue);
        expect(parser.recognize(String.fromCharCode(256)), isFalse);
      },
    );
  });

  group('Edge Case Tests - Predicates (AND/NOT)', () {
    testBoth(
      'Nested NOT predicates',
      Grammar(() {
        final a = Token.char('a');
        return Rule('start', () => Not(Not(a)) >> a);
      }),
      (parser) {
        expect(parser.recognize('a'), isTrue);
        expect(parser.recognize('b'), isFalse);
      },
    );

    testBoth(
      'Predicate at end of input',
      Grammar(() {
        final a = Token.char('a');
        final b = Token.char('b');
        return Rule('start', () => a >> And(b));
      }),
      (parser) {
        expect(parser.recognize('a'), isFalse);
        expect(parser.recognize('ab'), isFalse); // Matches 'a' but doesn't consume 'b'
      },
    );

    testBoth(
      'Predicate at end of input that consumes',
      Grammar(() {
        final a = Token.char('a');
        final b = Token.char('b');
        return Rule('start', () => (a >> And(b)) >> b);
      }),
      (parser) {
        expect(parser.recognize('ab'), isTrue);
      },
    );

    testBoth(
      'Predicate matching epsilon',
      Grammar(() {
        return Rule('start', () => And(Eps()) >> Token.char('a'));
      }),
      (parser) {
        expect(parser.recognize('a'), isTrue);
      },
    );
  });

  group('Edge Case Tests - Recursion and Cycles', () {
    testBoth(
      'Purely epsilon cycle S -> S | ε',
      Grammar(() {
        late final Rule s;
        s = Rule('S', () => s() | Eps());
        return s;
      }),
      (parser) {
        expect(parser.recognize(''), isTrue);
        expect(parser.recognize('a'), isFalse);
      },
    );

    testBoth(
      'Mutual epsilon cycle A -> B, B -> A | ε',
      Grammar(() {
        late final Rule a, b;
        a = Rule('A', () => b());
        b = Rule('B', () => a() | Eps());
        return a;
      }),
      (parser) {
        expect(parser.recognize(''), isTrue);
      },
    );
  });

  group('Edge Case Tests - Repetitions', () {
    testBoth(
      'Star on epsilon (handled by parser to avoid infinite loop)',
      Grammar(() {
        return Rule('start', () => Eps().star() >> Token.char('a'));
      }),
      (parser) {
        expect(parser.recognize('a'), isTrue);
      },
    );

    testBoth(
      'Nested stars',
      Grammar(() {
        return Rule('start', () => (Token.char('a').star()).star());
      }),
      (parser) {
        expect(parser.recognize(''), isTrue);
        expect(parser.recognize('a'), isTrue);
        expect(parser.recognize('aaaa'), isTrue);
      },
    );
  });

  group('Edge Case Tests - Ordered Choice Simulation', () {
    testBoth(
      'P / Q simulation where P partially matches',
      Grammar(() {
        final a = Token.char('a');
        final b = Token.char('b');
        final c = Token.char('c');
        final p = a >> b;
        final q = a >> c;
        return Rule('start', () => Alt(p, Not(p) >> q) >> c);
      }),
      (parser) {
        expect(parser.recognize('acc'), isTrue);
        expect(parser.recognize('abc'), isTrue);
      },
    );
  });

  group('Edge Case Tests - Markers and Ambiguity', () {
    testBoth(
      'Markers in cyclic epsilon rule',
      Grammar(() {
        late final Rule s;
        s = Rule('S', () => (Marker('loop') >> s()) | Eps());
        return s;
      }),
      (parser) {
        if (parser is SMParser) {
          final result = parser.parseWithForest('');
          expect(result, isA<ParseForestSuccess>());
          if (result is ParseForestSuccess) {
            final counts = result.forest.countDerivationsWithSCC();
            expect(counts['hasCycles'], isTrue);
          }
        } else {
          expect(parser.recognize(''), isTrue);
        }
      },
    );

    testBoth(
      'Overlapping patterns in Alt with markers',
      Grammar(() {
        final a = Token.char('a');
        return Rule('start', () => (Marker('M1') >> a) | (Marker('M2') >> a >> a));
      }),
      (parser) {
        expect(parser.recognize('a'), isTrue);
        expect(parser.recognize('aa'), isTrue);
      },
    );

    testBoth(
      'Deeply nested predicates',
      Grammar(() {
        final a = Token.char('a');
        // !(!(!(!a))) >> a  => equivalent to &a >> a which matches a
        return Rule('start', () => Not(Not(Not(Not(a)))) >> a);
      }),
      (parser) {
        expect(parser.recognize('a'), isTrue);
      },
    );

    testBoth(
      'Deeply nested AND predicates',
      Grammar(() {
        final a = Token.char('a');
        return Rule('start', () => And(And(And(a))) >> a);
      }),
      (parser) {
        expect(parser.recognize('a'), isTrue);
      },
    );
  });

  group('Edge Case Tests - Heavyweight Ambiguity & Recursion', () {
    testBoth(
      'Left recursion with markers in all positions',
      Grammar(() {
        late final Rule e;
        e = Rule(
          'E',
          () =>
              (Marker('left') >>
                  e() >>
                  Marker('mid') >>
                  Token.char('+') >>
                  Marker('right') >>
                  Token.char('a')) |
              Token.char('a'),
        );
        return e;
      }),
      (parser) {
        if (parser is SMParserMini) {
          final result = parser.parseAmbiguous('a+a+a');
          expect(result, isA<ParseAmbiguousForestSuccess>());
          if (result is ParseAmbiguousForestSuccess) {
            expect(result.forest.allPaths().length, equals(1));
            final marks = result.forest.allPaths().first.toStringList();
            expect(marks.where((m) => m == 'left').length, equals(2));
            expect(marks.where((m) => m == 'mid').length, equals(2));
            expect(marks.where((m) => m == 'right').length, equals(2));
          }
        } else if (parser is SMParser) {
          expect(parser.recognize('a+a+a'), isTrue);
          // Full SMParser parseAmbiguous returns merged marks, not paths
          final result = parser.parseAmbiguous('a+a+a');
          expect(result, isA<ParseAmbiguousForestSuccess>());
          if (result is ParseAmbiguousForestSuccess) {
            final marks = result.forest.toList().map((m) => (m as NamedMark).name).toList();
            expect(marks.where((m) => m == 'left').length, equals(2));
            expect(marks.where((m) => m == 'mid').length, equals(2));
            expect(marks.where((m) => m == 'right').length, equals(2));
          }
        }
      },
    );

    testBoth(
      'Highly ambiguous grammar (Catalan S -> SS | a)',
      Grammar(() {
        late final Rule s;
        s = Rule('S', () => (s() >> s()) | Token.char('a'));
        return s;
      }),
      (parser) {
        if (parser is SMParser) {
          const n = 5;
          final input = 'a' * n;
          expect(parser.countAllParses(input), equals(14));
        } else {
          expect(parser.recognize('aaaaa'), isTrue);
        }
      },
    );

    testBoth(
      'Robustness - Action throws exception',
      Grammar(() {
        return Rule(
          'start',
          () => Token.char('a').withAction((_, __) => throw Exception('Action failed')),
        );
      }),
      (parser) {
        if (parser is SMParser) {
          final result = parser.parseWithForest('a');
          expect(result, isA<ParseForestSuccess>());
          if (result is ParseForestSuccess) {
            final tree = result.forest.extract().first;
            expect(() => parser.evaluateParseTree(tree, 'a'), throwsA(isA<Exception>()));
          }
        } else {
          expect(parser.recognize('a'), isTrue);
        }
      },
    );

    testBoth(
      'Long input performance/robustness (1k chars)',
      Grammar(() {
        return Rule('start', () => Token.char('a').plus());
      }),
      (parser) {
        final input = 'a' * 1000;
        expect(parser.recognize(input), isTrue);
      },
    );

    testBoth(
      'Noisy input (random chars) resilience',
      Grammar(() {
        return Rule('start', () => Token.char('a').star());
      }),
      (parser) {
        final input = r'abc def!@#$%^&*()_+';
        expect(parser.recognize(input), isFalse);
      },
    );
  });

  group('Edge Cases - Right Recursion', () {
    testBoth(
      'Simple right recursion R -> a R | a',
      Grammar(() {
        late final Rule r;
        r = Rule('R', () => (Token.char('a') >> r()) | Token.char('a'));
        return r;
      }),
      (parser) {
        expect(parser.recognize('a'), isTrue);
        expect(parser.recognize('aaa'), isTrue);
        expect(parser.recognize(''), isFalse);
      },
    );

    testBoth(
      'Right recursion with markers',
      Grammar(() {
        late final Rule r;
        r = Rule(
          'R',
          () => (Marker('head') >> Token.char('a') >> r()) | (Marker('last') >> Token.char('a')),
        );
        return r;
      }),
      (parser) {
        final outcome = parser.parse('aaa');
        final marks = getMarks(outcome);
        expect(marks.where((m) => m == 'head').length, equals(2));
        expect(marks.where((m) => m == 'last').length, equals(1));
      },
    );
  });

  group('Edge Cases - Mutual Recursion', () {
    testBoth(
      'Mutually recursive A -> aB, B -> bA | b',
      Grammar(() {
        late final Rule a, b;
        a = Rule('A', () => Token.char('a') >> b());
        b = Rule('B', () => (Token.char('b') >> a()) | Token.char('b'));
        return a;
      }),
      (parser) {
        expect(parser.recognize('ab'), isTrue);
        expect(parser.recognize('abab'), isTrue);
        expect(parser.recognize('ababab'), isTrue);
        expect(parser.recognize('a'), isFalse);
        expect(parser.recognize('b'), isFalse);
      },
    );

    testBoth(
      'Three-way mutual recursion',
      Grammar(() {
        late final Rule a, b, c;
        a = Rule('A', () => Token.char('a') >> b());
        b = Rule('B', () => Token.char('b') >> c());
        c = Rule('C', () => Token.char('c') | (Token.char('c') >> a()));
        return a;
      }),
      (parser) {
        expect(parser.recognize('abc'), isTrue);
        expect(parser.recognize('abcabc'), isTrue);
        expect(parser.recognize('ab'), isFalse);
      },
    );
  });

  group('Edge Cases - Epsilon in Sequences', () {
    testBoth(
      'Eps at start of sequence',
      Grammar(() {
        return Rule('start', () => Eps() >> Token.char('a'));
      }),
      (parser) {
        expect(parser.recognize('a'), isTrue);
        expect(parser.recognize(''), isFalse);
      },
    );

    testBoth(
      'Eps at end of sequence',
      Grammar(() {
        return Rule('start', () => Token.char('a') >> Eps());
      }),
      (parser) {
        expect(parser.recognize('a'), isTrue);
        expect(parser.recognize(''), isFalse);
      },
    );

    testBoth(
      'Multiple Eps in sequence',
      Grammar(() {
        return Rule('start', () => Eps() >> Eps() >> Token.char('a') >> Eps());
      }),
      (parser) {
        expect(parser.recognize('a'), isTrue);
        expect(parser.recognize('aa'), isFalse);
      },
    );

    testBoth(
      'Alt where one branch is Eps',
      Grammar(() {
        return Rule('start', () => (Token.char('a') | Eps()) >> Token.char('b'));
      }),
      (parser) {
        expect(parser.recognize('ab'), isTrue);
        expect(parser.recognize('b'), isTrue);
        expect(parser.recognize('a'), isFalse);
      },
    );
  });

  group('Edge Cases - Adjacent Markers', () {
    testBoth(
      'Multiple consecutive markers',
      Grammar(() {
        return Rule('start', () => Marker('a') >> Marker('b') >> Marker('c') >> Token.char('x'));
      }),
      (parser) {
        final outcome = parser.parse('x');
        final marks = getMarks(outcome);
        expect(marks, equals(['a', 'b', 'c']));
      },
    );

    testBoth(
      'Markers surrounding token',
      Grammar(() {
        return Rule('start', () => Marker('before') >> Token.char('a') >> Marker('after'));
      }),
      (parser) {
        final outcome = parser.parse('a');
        final marks = getMarks(outcome);
        expect(marks.indexOf('before'), lessThan(marks.indexOf('after')));
      },
    );

    testBoth(
      'Marker in star body',
      Grammar(() {
        return Rule('start', () => (Marker('item') >> Token.char('a')).star());
      }),
      (parser) {
        final outcome = parser.parse('aaa');
        final marks = getMarks(outcome);
        expect(marks.where((m) => m == 'item').length, equals(3));
      },
    );

    testBoth(
      'Marker in plus body',
      Grammar(() {
        return Rule('start', () => (Marker('item') >> Token.char('a')).plus());
      }),
      (parser) {
        final outcome = parser.parse('aa');
        final marks = getMarks(outcome);
        expect(marks.where((m) => m == 'item').length, equals(2));
      },
    );
  });

  group('Edge Cases - Predicate Interactions', () {
    testBoth(
      'NOT predicate on recursive rule',
      Grammar(() {
        late final Rule digits;
        digits = Rule(
          'digits',
          () => Token(const RangeToken(48, 57)) >> digits() | Token(const RangeToken(48, 57)),
        );
        final notDigit = Not(digits());
        return Rule('start', () => notDigit >> Token.char('a'));
      }),
      (parser) {
        expect(parser.recognize('a'), isTrue);
        expect(parser.recognize('1'), isFalse);
      },
    );

    testBoth(
      'AND predicate followed by star',
      Grammar(() {
        final a = Token.char('a');
        return Rule('start', () => And(a) >> a.star());
      }),
      (parser) {
        expect(parser.recognize('a'), isTrue);
        expect(parser.recognize('aaa'), isTrue);
        expect(parser.recognize(''), isFalse);
      },
    );

    testBoth(
      'Predicate inside star',
      Grammar(() {
        final a = Token.char('a');
        final b = Token.char('b');
        return Rule('start', () => (Not(b) >> a).star() >> b);
      }),
      (parser) {
        expect(parser.recognize('b'), isTrue);
        expect(parser.recognize('aaab'), isTrue);
        expect(parser.recognize('aaaa'), isFalse);
      },
    );

    testBoth(
      'Two predicates in sequence',
      Grammar(() {
        final a = Token.char('a');
        final b = Token.char('b');
        return Rule('start', () => And(a) >> Not(b) >> a);
      }),
      (parser) {
        expect(parser.recognize('a'), isTrue);
        expect(parser.recognize('b'), isFalse);
      },
    );

    testBoth(
      'Predicate on empty input',
      Grammar(() {
        return Rule('start', () => Not(Token.char('a')));
      }),
      (parser) {
        expect(parser.recognize(''), isTrue);
        expect(parser.recognize('a'), isFalse);
      },
    );
  });

  group('Edge Cases - Rule Called From Multiple Sites', () {
    testBoth(
      'Same rule called twice in sequence',
      Grammar(() {
        final digit = Rule('digit', () => Token(const RangeToken(48, 57)));
        return Rule('start', () => digit() >> Token.char('-') >> digit());
      }),
      (parser) {
        expect(parser.recognize('1-2'), isTrue);
        expect(parser.recognize('1-'), isFalse);
        expect(parser.recognize('-2'), isFalse);
      },
    );

    testBoth(
      'Same rule called in both branches of Alt',
      Grammar(() {
        final item = Rule('item', () => Token.char('a'));
        return Rule('start', () => item() | (item() >> item()));
      }),
      (parser) {
        expect(parser.recognize('a'), isTrue);
        expect(parser.recognize('aa'), isTrue);
        expect(parser.recognize('aaa'), isFalse);
      },
    );
  });

  group('Edge Cases - Ambiguity Counts', () {
    testBoth(
      'S -> SS | a with n=4 has 5 parses (Catalan C_3)',
      Grammar(() {
        late final Rule s;
        s = Rule('S', () => (s() >> s()) | Token.char('a'));
        return s;
      }),
      (parser) {
        if (parser is SMParser) {
          expect(parser.countAllParses('aaaa'), equals(5));
          expect(parser.countAllParses('aaa'), equals(2));
          expect(parser.countAllParses('aa'), equals(1));
        } else {
          expect(parser.recognize('aaaa'), isTrue);
        }
      },
    );

    testBoth(
      'Ambiguous arithmetic a+a+a has exactly 2 parses',
      Grammar(() {
        late final Rule e;
        e = Rule('E', () => (e() >> Token.char('+') >> e()) | Token.char('a'));
        return e;
      }),
      (parser) {
        if (parser is SMParser) {
          expect(parser.countAllParses('a+a+a'), equals(2));
        } else {
          expect(parser.recognize('a+a+a'), isTrue);
        }
      },
    );
  });

  group('Edge Cases - Unicode / Boundary Tokens', () {
    testBoth(
      'Codepoint 0 token',
      Grammar(() {
        return Rule('start', () => Token(const ExactToken(0)));
      }),
      (parser) {
        expect(parser.recognize(String.fromCharCode(0)), isTrue);
        expect(parser.recognize('a'), isFalse);
      },
    );
  });

  group('Edge Cases - Unicode / Boundary Tokens', () {
    testBoth(
      'High codepoint token',
      Grammar(() {
        return Rule('start', () => Pattern.string('😀'));
      }),
      (parser) {
        expect(parser.recognize('😀'), isTrue);
        expect(parser.recognize('a'), isFalse);
      },
    );

    testBoth(
      'Codepoint 0 token',
      Grammar(() {
        return Rule('start', () => Token(const ExactToken(0)));
      }),
      (parser) {
        expect(parser.recognize(String.fromCharCode(0)), isTrue);
        expect(parser.recognize('a'), isFalse);
      },
    );
  });

  group('Edge Cases - Star/Plus Boundary Conditions', () {
    testBoth(
      'Plus requires at least one match',
      Grammar(() {
        return Rule('start', () => Token.char('a').plus());
      }),
      (parser) {
        expect(parser.recognize(''), isFalse);
        expect(parser.recognize('a'), isTrue);
        expect(parser.recognize('aaaa'), isTrue);
      },
    );

    testBoth(
      'Star matches zero',
      Grammar(() {
        return Rule('start', () => Token.char('a').star());
      }),
      (parser) {
        expect(parser.recognize(''), isTrue);
        expect(parser.recognize('a'), isTrue);
        expect(parser.recognize('b'), isFalse);
      },
    );

    testBoth(
      'Nested plus inside star',
      Grammar(() {
        return Rule('start', () => (Token.char('a').plus() >> Token.char('b')).star());
      }),
      (parser) {
        expect(parser.recognize(''), isTrue);
        expect(parser.recognize('ab'), isTrue);
        expect(parser.recognize('aab'), isTrue);
        expect(parser.recognize('ababab'), isTrue);
        expect(parser.recognize('ba'), isFalse);
      },
    );

    testBoth(
      'Star followed immediately by same token',
      Grammar(() {
        return Rule('start', () => Token.char('a').star() >> Token.char('a'));
      }),
      (parser) {
        // Ambiguous - star can consume 0..n-1 of the a's
        expect(parser.recognize('a'), isTrue);
        expect(parser.recognize('aaa'), isTrue);
        expect(parser.recognize(''), isFalse);
      },
    );
  });

  group('Edge Cases - Error Positions', () {
    testBoth(
      'Error position is correct for simple mismatch',
      Grammar(() {
        return Rule('start', () => Token.char('a') >> Token.char('b') >> Token.char('c'));
      }),
      (parser) {
        final outcome = parser.parse('abx');
        if (outcome is ParseError) {
          expect(outcome.position, equals(2));
        }
      },
    );

    testBoth(
      'Error at position 0',
      Grammar(() {
        return Rule('start', () => Token.char('a'));
      }),
      (parser) {
        final outcome = parser.parse('b');
        if (outcome is ParseError) {
          expect(outcome.position, equals(0));
        }
      },
    );
  });
}
