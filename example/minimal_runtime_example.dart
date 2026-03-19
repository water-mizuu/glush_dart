import 'dart:io';
import 'package:glush/glush.dart';

/// Minimal Runtime Example
///
/// This example demonstrates how to:
/// 1. Define a grammar (Simple Addition/Subtraction)
/// 2. Generate a "Minimal Standalone" parser
/// 3. Save it to a file
/// 4. Use the generated parser with custom actions
void main() async {
  print('--- Glush Minimal Runtime Example ---\n');

  // 1. Define a simple grammar
  print('Step 1: Defining grammar...');
  final grammar = Grammar(() {
    late Rule expr, term;

    expr = Rule('expr', () {
      return (Call(expr) >> Pattern.char('+') >> Call(term)).withAction((span, results) {
            if (results case [[num l, '+'], num r]) return l + r;
            return null;
          }) |
          (Call(expr) >> Pattern.char('-') >> Call(term)).withAction((span, results) {
            if (results case [[num l, '-'], num r]) return l - r;
            return null;
          }) |
          Call(term);
    });

    term = Rule('term', () {
      return Token.charRange('0', '9').plus().withAction((span, results) => num.parse(span));
    });

    return expr;
  });

  // 2. Export and Generate Minimal Standalone Code
  print('Step 2: Exporting and generating minimal standalone code...');
  final exported = StateMachineExporter.export(grammar.stateMachine);
  final codegen = StateMachineCodeGenerator(exported, grammarName: 'MinimalMath');
  final generatedCode = codegen.generateMinimalStandalone();

  // 3. Save to a file
  final fileName = 'example/generated_minimal_math.dart';
  print('Step 3: Saving generated code to $fileName...');
  File(fileName).writeAsStringSync(generatedCode);

  print('\n✓ Minimal standalone parser generated successfully!');
  print('✓ The file "$fileName" is now self-contained and has NO external dependencies.');

  // 4. Demonstrate how to use it
  print('\nStep 4: Usage Demonstration');
  print('--------------------------------------------------');
  print('To use the generated parser, you would implement a script like this:\n');

  print('''
    import 'generated_minimal_math.dart';

    void main() {
      // Initialize the parser with custom semantic actions
      // The action IDs (e.g., 'act:S1:') are found in the generated stubs
      final parser = MinimalMathParser(actions: {
        // You can override the default stubs here:
        // 'act:S1:': (span, results) => ...
      });

      final input = "1+2-3+4";
      final outcome = parser.parse(input);

      if (outcome is ParseSuccess) {
        print('Result of "\$input" is: \${outcome.semanticValue}');
      }
    }
    ''');

  print('--------------------------------------------------');
  print('Note: Since we are running in the glush_dart workspace,');
  print('you can try running the generated example now if you wish.');
}
