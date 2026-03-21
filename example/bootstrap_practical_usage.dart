import 'package:glush/glush.dart';

/// Practical Example: Using the Bootstrap System
///
/// This example demonstrates how to use the bootstrapped glush system
/// in a real application:
///
/// 1. Define a custom grammar file (.glush)
/// 2. Use GrammarCodeGenerator to create a parser
/// 3. Use that parser in production code
void main() {
  print('=== Practical Bootstrap Usage Example ===\n');

  // Step 1: Define a domain-specific language (DSL)
  print('Step 1: Define a simple configuration file format\n');

  const configGrammar = '''
config = setting+ ;
setting = key '=' value ;
key = [a-z]+ ;
value = [a-z0-9]+ ;
''';

  print('Grammar defined:');
  print(configGrammar);
  print('');

  // Step 2: Parse the grammar
  print('Step 2: Parse the grammar definition\n');

  final gfParser = GrammarFileParser(configGrammar);
  final grammarFile = gfParser.parse();

  print('✓ Parsed ${grammarFile.rules.length} rules');
  for (final rule in grammarFile.rules) {
    print('  - ${rule.name}');
  }
  print('');

  // Step 3: Generate Dart code
  print('Step 3: Generate Dart parser code\n');

  final codegen = GrammarCodeGenerator(grammarFile);
  final generatedCode = codegen.generateGrammarFile();

  print('✓ Generated ${generatedCode.length} bytes');
  print('');

  // Step 4: Create a parser from the generated grammar
  print('Step 4: Create parser and test it\n');

  final grammar = _createConfigGrammar();
  final parser = SMParser(grammar);

  // Test configuration files
  final testCases = [
    ('valid', 'name=example'),
    ('multiple', 'name=example version=1'),
    ('complex', 'host=localhost port=8080 debug=true'),
    ('invalid', 'name example'), // Missing =
  ];

  print('Testing configuration parser:');
  for (final (_, config) in testCases) {
    final result = parser.parse(config);
    if (result is ParseSuccess) {
      print('  ✓ "$config"');
    } else if (result is ParseError) {
      print('  ✗ "$config" (error at position ${result.position})');
    }
  }

  print('\n' + ('=' * 60));
  print('=== Bootstrap Application Summary ===');
  print('=' * 60);
  print('');
  print('The Bootstrap System enables:');
  print('  1. Rapid prototyping of domain-specific languages');
  print('  2. Automatic parser generation from grammar definitions');
  print('  3. Self-validating grammar format');
  print('  4. Meta-circular code generation');
  print('');
  print('Workflow:');
  print('  Grammar Definition (text) → Parser (Dart code) → Application');
  print('');
  print('Files generated:');
  print('  • lib/generated/glush_grammar_parser.g.dart');
  print('  • lib/generated/glush_meta_parser.g.dart');
  print('');
  print('These can be used in production without regeneration.');
  print('(They are stable, bootstrapped implementations)');
}

/// This is what the code generator produces from the config grammar
/// In a real application, you'd save this to a file and import it
GrammarInterface _createConfigGrammar() {
  return Grammar(() {
    late final config, setting, key, value;

    config = Rule('config', () => setting().plus());

    setting = Rule('setting', () => key() >> Token(ExactToken(61)) >> value()); // 61 = '='

    key = Rule('key', () => Token(RangeToken(97, 122)).plus()); // a-z

    value = Rule(
      'value',
      () => (Token(RangeToken(97, 122)) | Token(RangeToken(48, 57))).plus(),
    ); // a-z0-9

    return config;
  });
}
