import 'dart:io';

import 'package:glush/glush.dart';

/// Example: Export and Import State Machine
///
/// This demonstrates the full pipeline:
/// 1. Define a grammar (math expressions)
/// 2. Export the state machine to code
/// 3. Import and use it with semantic actions
void main() {
  print('===== STATE MACHINE EXPORT/IMPORT PIPELINE =====\n');

  // =========================================================================
  // PHASE 1: GRAMMAR DEFINITION & STATE MACHINE BUILD
  // =========================================================================
  print('Phase 1: Building grammar...\n');

  final grammar = Grammar(() {
    late Rule expr, term, factor;

    expr = Rule('expr', () {
      return (expr() >> Pattern.char('+') >> term()).withAction((span, results) {
            if (results case [[num l, '+'], num r]) {
              return l + r;
            }
            return null;
          }) |
          (expr() >> Pattern.char('-') >> term()).withAction((span, results) {
            if (results case [[num l, '-'], num r]) {
              return l - r;
            }
            return null;
          }) |
          term();
    });

    term = Rule('term', () {
      return (term() >> Pattern.char('*') >> factor()).withAction((span, results) {
            if (results case [[num l, '*'], num r]) {
              return l * r;
            }
            return null;
          }) |
          (term() >> Pattern.char('/') >> factor()).withAction((span, results) {
            if (results case [[num l, '/'], num r]) {
              return l / r;
            }
            return null;
          }) |
          factor();
    });

    factor = Rule('factor', () {
      return (Pattern.char('(') >> expr() >> Pattern.char(')')).withAction((span, results) {
            if (results case [['(', num middle], ')']) {
              return middle;
            }
            return null;
          }) |
          Token.charRange('0', '9').plus().withAction((span, results) => num.parse(span));
    });

    return expr;
  });

  final stateMachine = grammar.stateMachine;
  print('✓ State machine built with ${stateMachine.states.length} states');
  print('✓ Grammar has ${stateMachine.rules.length} rules\n');

  // =========================================================================
  // PHASE 2: EXPORT STATE MACHINE
  // =========================================================================
  print('Phase 2: Exporting state machine...\n');

  final exported = StateMachineExporter.export(stateMachine);

  // For demo, print the JSON (in real use, you'd save this to a file)
  final exportedJson = exported.toJson();
  File("test.json")
    ..createSync(recursive: true)
    ..writeAsStringSync(exportedJson);
  print('✓ Exported to JSON (${exportedJson.length} chars)');
  print('✓ Contains ${exported.states.length} states');
  print('✓ Contains ${exported.rules.length} rules\n');

  // Generate Dart code
  final codeGen = StateMachineCodeGenerator(exported, grammarName: 'math');
  final generatedCode = codeGen.generateStandalone();
  print('✓ Generated standalone Dart code');
  print('  Code length: ${generatedCode.length} chars\n');

  // (In a real scenario, you would save this to a file and import it separately)
  print('Sample generated code structure:');
  print('  - Embedded state machine JSON as constant');
  print('  - load_mathStateMachine() function');
  print('  - MathActions stub class with action methods');
  print('  - MathParser factory class\n');

  // =========================================================================
  // PHASE 3: IMPORT & USE (simulated - recreate from exported spec)
  // =========================================================================
  print('Phase 3: Importing and using exported state machine...\n');

  // Re-import the exported state machine
  final reimported = ExportedStateMachine.fromJson(exportedJson);
  print('✓ Re-imported from JSON');
  print('✓ ${reimported.states.length} states, ${reimported.rules.length} rules\n');

  // Create an imported state machine with action attachment
  final imported = ImportedStateMachine(reimported);
  print('✓ Created ImportedStateMachine\n');

  // Attach semantic actions (in the real scenario, these would be defined in MathActions)
  imported.attachAction('stub', (String span, List results) {
    // For tokens - just return the value
    return results.isNotEmpty ? results[0] : span;
  });

  // Create a parser from the imported machine
  final parser = imported.createParser();
  print('✓ Created parser from imported state machine\n');

  // =========================================================================
  // PHASE 4: PARSE AND EVALUATE
  // =========================================================================
  print('Phase 4: Parsing and evaluation...\n');

  const testInputs = ['5', '2+3', '2+3*4', '(2+3)*4'];

  for (final input in testInputs) {
    print('Input: "$input"');
    final result = parser.parse(input);

    if (result is ParseSuccess) {
      print('  ✓ Parse succeeded');
      if (result.result.marks.isNotEmpty) {
        print('  Marks: ${result.result.marks}');
      }
    } else if (result is ParseError) {
      print('  ✗ Parse failed at position ${result.position}');
    }
    print('');
  }

  // =========================================================================
  // PHASE 5: SHOW HOW ACTIONS WOULD BE IMPLEMENTED
  // =========================================================================
  print('=' * 60);
  print('How to implement in generated code (MathActions):\n');

  print('''
class MathActions {
  static Object? expr_action_1(String span, List results) {
    // Addition: [left_expr, '+', right_term]
    if (results case [num left, '+', num right]) {
      return left + right;
    }
    return null;
  }

  static Object? expr_action_2(String span, List results) {
    // Subtraction: [left_expr, '-', right_term]
    if (results case [num left, '-', num right]) {
      return left - right;
    }
    return null;
  }

  static Object? term_action_1(String span, List results) {
    // Multiplication: [left_term, '*', right_factor]
    if (results case [num left, '*', num right]) {
      return left * right;
    }
    return null;
  }

  // ... and so on for other actions
}
''');

  print('\nThen create a parser with custom actions:');
  print('''
final customParser = MathParser(
  actions: {
    'expr_action_1': MathActions.expr_action_1,
    'expr_action_2': MathActions.expr_action_2,
    // ... attach all your actions
  }
);

final result = customParser.parse('2+3*4');
''');
}
