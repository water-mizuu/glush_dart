import 'package:glush/glush.dart';

void main() {
  print('=== Math Expression Grammar - All Iteration Methods ===\n');

  // Grammar with MARKERS for mark-based evaluation
  final markerGrammar = Grammar(() {
    late Rule expr, term, factor;

    expr = Rule('expr', () {
      return (Marker('add') >> (Call(expr) >> Pattern.char('+') >> Call(term))) |
          (Marker('sub') >> (Call(expr) >> Pattern.char('-') >> Call(term))) |
          Call(term);
    });

    term = Rule('term', () {
      return (Marker('mul') >> (Call(term) >> Pattern.char('*') >> Call(factor))) |
          (Marker('div') >> (Call(term) >> Pattern.char('/') >> Call(factor))) |
          Call(factor);
    });

    factor = Rule('factor', () {
      return (Pattern.char('(') >> Call(expr) >> Pattern.char(')')) |
          (Marker('number') >> (Token(RangeToken(48, 57)).plus()));
    });

    return expr;
  });

  // Grammar with SEMANTIC ACTIONS for action-based evaluation
  final actionGrammar = Grammar(() {
    late Rule expr, term, factor;

    expr = Rule('expr', () {
      return (Call(expr) >> Pattern.char('+') >> Call(term)).withAction((span, results) {
            if (results case [[num l, '+'], num r]) {
              return l + r;
            }
            throw Exception(results);
          }) |
          (Call(expr) >> Pattern.char('-') >> Call(term)).withAction((span, results) {
            if (results case [[num l, '-'], num r]) {
              return l - r;
            }
            throw Exception(results);
          }) |
          Call(term);
    });

    term = Rule('term', () {
      return (Call(term) >> Pattern.char('*') >> Call(factor)).withAction((span, results) {
            if (results case [[num l, '*'], num r]) {
              return l * r;
            }
            throw Exception(results);
          }) |
          (Call(term) >> Pattern.char('/') >> Call(factor)).withAction((span, results) {
            if (results case [[num l, '/'], num r]) {
              return l / r;
            }
            throw Exception(results);
          }) |
          Call(factor);
    });

    factor = Rule('factor', () {
      return (Pattern.char('(') >> Call(expr) >> Pattern.char(')')).withAction((span, results) {
            if (results case [['(', num middle], ')']) {
              return middle;
            }
            throw Exception(results);
          }) |
          Token.charRange('0', '9').plus().withAction((span, results) => num.parse(span));
    });

    return expr;
  });

  // Grammar with no actions / markers.
  final cleanGrammar = Grammar(() {
    late Rule expr, term, factor;

    expr = Rule('expr', () {
      return (Call(expr) >> Pattern.char('+') >> Call(term)) |
          (Call(expr) >> Pattern.char('-') >> Call(term)) |
          Call(term);
    });

    term = Rule('term', () {
      return (Call(term) >> Pattern.char('*') >> Call(factor)) |
          (Call(term) >> Pattern.char('/') >> Call(factor)) |
          Call(factor);
    });

    factor = Rule('factor', () {
      return (Pattern.char('(') >> Call(expr) >> Pattern.char(')')) |
          Token.charRange('0', '9').plus();
    });

    return expr;
  });

  const input = '1+2*3+4';
  print('Input: "$input" (expected result: 1 + 2 * 3 + 4 = 11)\n');
  print('=' * 70 + '\n');

  // Method 1: parse() with marks
  print('Method 1: parse() -> returns marks');
  _methodParse(markerGrammar, input);

  // Method 2: enumerateAllParses()
  print('\n\nMethod 2: enumerateAllParses() -> returns parse trees');
  _methodEnumerateAllParses(actionGrammar, input);
  _methodEnumerateAllParses(markerGrammar, input);

  // Method 3: enumerateAllParsesWithResults()
  print('\n\nMethod 3: enumerateAllParsesWithResults() -> trees with values');
  _methodEnumerateAllParsesWithResults(actionGrammar, input);
  _methodEnumerateAllParsesWithResults(markerGrammar, input);
  _methodEnumerateAllParsesWithResults(cleanGrammar, input);

  // // Complex example
  const input2 = '(5-1)*2+3';
  print('\n\n' + '=' * 70);
  print('Complex Input: "$input2" (expected: $input2 = 11)\n');
  print('-' * 70);
  print('Method 1 - parse():');
  _methodParse(markerGrammar, input2);
  // Method 2: enumerateAllParses()
  print('\n\nMethod 2: enumerateAllParses() -> returns parse trees');
  _methodEnumerateAllParses(actionGrammar, input2);
  _methodEnumerateAllParses(markerGrammar, input2);
  print('\nMethod 3 - enumerateAllParsesWithResults():');
  _methodEnumerateAllParsesWithResults(actionGrammar, input2);
}

void _methodParse(GrammarInterface grammar, String input) {
  final parser = SMParser(grammar);
  final result = parser.parse(input);

  final evaluator = Evaluator(($) {
    return {
      'add': () => $<num>() + $<num>(),
      'sub': () => $<num>() - $<num>(),
      'mul': () => $<num>() * $<num>(),
      'div': () => $<num>() / $<num>(),
      'number': () => num.parse($<String>()),
    };
  });

  if (result is ParseSuccess) {
    print('Parse succeeded.');
    print('Marks: ${result.result.marks}');
    final value = evaluator.evaluate(result.result.marks);
    print('Evaluated result: $value');
  } else if (result is ParseError) {
    print('Parse failed at position ${result.position}');
  }
}

// ============================================================================
// METHOD 2: enumerateAllParses()
// ============================================================================
void _methodEnumerateAllParses(GrammarInterface grammar, String input) {
  final parser = SMParser(grammar);
  final parses = parser.enumerateAllParses(input).toList();

  if (parses.isNotEmpty) {
    print('Total parse trees: ${parses.length}');
    for (final (i, parse) in parses.indexed) {
      print('  Parse ${i + 1}:');
      print('    Tree: ${parse.toTreeString(input)}');
      final value = parser.evaluateParseDerivation(parse, input);
      print('    Raw structure: $value');
    }
  } else {
    print('No parses found.');
  }
}

// ============================================================================
// METHOD 3: enumerateAllParsesWithResults()
// ============================================================================
void _methodEnumerateAllParsesWithResults(GrammarInterface grammar, String input) {
  final parser = SMParser(grammar);
  final parses = parser.enumerateAllParsesWithResults(input).toList();

  if (parses.isNotEmpty) {
    print('Total parse trees: ${parses.length}');
    for (final (i, parse) in parses.indexed) {
      print('  Parse ${i + 1}:');
      print('    Result: ${parse.tree.toTreeString(input)}');
      var value = parse.value;
      print('    Evaluated result: $value');
    }
  } else {
    print('No parses found.');
  }
}
