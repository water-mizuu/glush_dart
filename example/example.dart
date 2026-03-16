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
            print(results);
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

  // Grammar with SEMANTIC ACTIONS for action-based evaluation
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

  // Method 4: enumerateForest()
  print('\n\nMethod 4: enumerateForest() -> parse trees from SPPF');
  _methodEnumerateForest(markerGrammar, input);

  // Method 5: enumerateForestWithResults()
  print('\n\nMethod 5: enumerateForestWithResults() -> values from SPPF');
  _methodEnumerateForestWithResults(actionGrammar, input);

  // // Complex example
  const input2 = '(5-1)*2+3';
  print('\n\n' + '=' * 70);
  print('Complex Input: "$input2" (expected: ((5-1)*2)+3 = 11)\n');
  print('-' * 70);
  print('Method 1 - parse():');
  _methodParse(markerGrammar, input2);
  // Method 2: enumerateAllParses()
  print('\n\nMethod 2: enumerateAllParses() -> returns parse trees');
  _methodEnumerateAllParses(actionGrammar, input2);
  _methodEnumerateAllParses(markerGrammar, input2);
  print('\nMethod 3 - enumerateAllParsesWithResults():');
  _methodEnumerateAllParsesWithResults(actionGrammar, input2);

  // Method 4: enumerateForest()
  print('\n\nMethod 4: enumerateForest() -> parse trees from SPPF');
  _methodEnumerateForest(markerGrammar, input2);

  // Method 5: enumerateForestWithResults()
  print('\n\nMethod 5: enumerateForestWithResults() -> values from SPPF');
  _methodEnumerateForestWithResults(actionGrammar, input2);
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
      'number': () => num.parse($<String>())
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
      final result = _evaluateCleanStructure(value);
      print('    Raw structure: $value');
      print('    Evaluated result: $result');
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
      if (value is! num) {
        value = _evaluateCleanStructure(value);
      }
      print('    Evaluated result: $value');
    }
  } else {
    print('No parses found.');
  }
}

// ============================================================================
// METHOD 4: enumerateForest()
// ============================================================================
void _methodEnumerateForest(GrammarInterface grammar, String input) {
  final parser = SMParser(grammar);
  final parseResult = parser.parseWithForest(input);

  if (parseResult is ParseForestSuccess) {
    final trees = parseResult.forest.extract().toList();

    if (trees.isNotEmpty) {
      print('Total parse trees from forest: ${trees.length}');
      for (final (i, parse) in trees.indexed) {
        var value = parser.evaluateParseTree(parse, input);

        print(parse.toPrecedenceString(input));
        print('  Parse ${i + 1}: Result = $value');
      }
    } else {
      print('No parses found in forest.');
    }
  } else if (parseResult is ParseError) {
    print('Parse failed at position ${parseResult.position}');
  }
}

// ============================================================================
// METHOD 5: enumerateForestWithResults()
// ============================================================================
void _methodEnumerateForestWithResults(GrammarInterface grammar, String input) {
  final parser = SMParser(grammar);
  final result = parser.parseWithForest(input);

  if (result is ParseForestSuccess) {
    final results = parser.enumerateForestWithResults(result, input).toList();

    if (results.isNotEmpty) {
      print('Total parse trees from forest: ${results.length}');
      for (final (i, parseResult) in results.indexed) {
        var value = parseResult.value;
        if (value is! num) {
          value = _evaluateCleanStructure(value);
        }
        print('  Parse ${i + 1}: Result = $value');
      }
    } else {
      print('No parses found in forest.');
    }
  } else if (result is ParseError) {
    print('Parse failed at position ${result.position}');
  }
}

// ============================================================================
// EVALUATOR HELPER: Evaluate raw parse structures (without marks/actions)
// ============================================================================
/// Recursively evaluates a parse structure into a numeric result.
/// Handles nested lists with operators and operands.
dynamic _evaluateCleanStructure(dynamic value) {
  // If it's already a number, return it
  if (value is num) {
    return value;
  }

  // If it's a string, try to parse as number or return as-is
  if (value is String) {
    final parsed = num.tryParse(value);
    return parsed ?? value;
  }

  // If it's a list, evaluate the structure
  if (value is List) {
    if (value.isEmpty) {
      return null;
    }

    // Recursively evaluate all elements
    final evaluated = value.map(_evaluateCleanStructure).toList();

    // Try to interpret as: [operand, operator, operand, ...]
    // For binary operators
    if (evaluated.length >= 3) {
      // Check for pattern: [num, operator, num]
      if (evaluated[0] is num && evaluated[1] is String && evaluated[2] is num) {
        final left = evaluated[0] as num;
        final op = evaluated[1] as String;
        final right = evaluated[2] as num;

        final result = switch (op) {
          '+' => left + right,
          '-' => left - right,
          '*' => left * right,
          '/' => left / right,
          _ => evaluated,
        };

        // Continue evaluating with remaining elements (for left-associativity)
        if (evaluated.length > 3) {
          return _evaluateCleanStructure([result, ...evaluated.sublist(3)]);
        }
        return result;
      }
    }

    // If it's a single-element list, unwrap and evaluate
    if (evaluated.length == 1) {
      return evaluated[0];
    }

    return evaluated;
  }

  return value;
}
