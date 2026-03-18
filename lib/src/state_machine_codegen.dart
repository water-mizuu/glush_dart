/// Code generation for exported state machines
library glush.state_machine_codegen;

import 'state_machine_export.dart';

class StateMachineCodeGenerator {
  final ExportedStateMachine exported;
  final String grammarName;

  StateMachineCodeGenerator(this.exported, {required this.grammarName});

  /// Generate a standalone Dart file that can be imported and used
  String generateStandalone() {
    final buffer = StringBuffer();
    final pascalName = _toPascalCase(grammarName);

    buffer.writeln('/// Auto-generated state machine for $grammarName grammar');
    buffer.writeln('/// Generated: ${DateTime.now()}');
    buffer.writeln("import 'package:glush/glush.dart';");
    buffer.writeln();

    // Generate state machine data
    _generateStateData(buffer, pascalName);
    buffer.writeln();

    // Generate loader function
    _generateLoaderFunction(buffer, pascalName);
    buffer.writeln();

    // Generate parser factory
    _generateParserFactory(buffer, pascalName);

    return buffer.toString();
  }

  void _generateStateData(StringBuffer buffer, String pascalName) {
    // Export as JSON constant for easy serialization
    buffer.writeln('/// Exported state machine specification as JSON');
    buffer.writeln('const String _${grammarName}StateMachineJson = r"""');
    buffer.writeln(exported.toJson());
    buffer.writeln('""";');
  }

  void _generateLoaderFunction(StringBuffer buffer, String pascalName) {
    buffer.writeln('/// Load the exported state machine specification');
    buffer.writeln(
      'ExportedStateMachine load${pascalName}StateMachine() => '
      'ExportedStateMachine.fromJson(_${grammarName}StateMachineJson);',
    );
  }

  void _generateParserFactory(StringBuffer buffer, String pascalName) {
    buffer.writeln();
    buffer.writeln('/// Create an imported state machine with action stubs');
    buffer.writeln('class ${pascalName}Actions {');
    buffer.writeln('  /// Override these methods with your semantic actions');
    buffer.writeln();

    // Generate stub methods for each rule
    for (final entry in exported.rules.entries) {
      final ruleName = entry.key;
      // final ruleMetadata = entry.value;
      buffer.writeln('  /// Semantic action stub for rule: $ruleName');
      buffer.writeln(
        '  static Object? ${_toSnakeCase(ruleName)}Action(String span, List results) {',
      );
      buffer.writeln('    // TODO: Implement semantic action for $ruleName');
      buffer.writeln('    // span: the matched substring');
      buffer.writeln('    // results: list of child semantic values');
      buffer.writeln('    throw UnimplementedError("Action not implemented for $ruleName");');
      buffer.writeln('  }');
      buffer.writeln();
    }

    buffer.writeln('}');
    buffer.writeln();

    buffer.writeln('/// Create a parser using the ${pascalName} grammar');
    buffer.writeln('class ${pascalName}Parser {');
    buffer.writeln('  late final ImportedStateMachine _machine;');
    buffer.writeln('  late final SMParser _parser;');
    buffer.writeln();
    buffer.writeln('  ${pascalName}Parser({Map<String, Function>? actions}) {');
    buffer.writeln('    final spec = load${pascalName}StateMachine();');
    buffer.writeln('    _machine = ImportedStateMachine(spec);');
    buffer.writeln();
    buffer.writeln('    // Attach default actions');
    for (final ruleName in exported.rules.keys) {
      buffer.writeln(
        '    _machine.attachAction("${ruleName}_action", ${pascalName}Actions.${_toSnakeCase(ruleName)}Action);',
      );
    }
    buffer.writeln();
    buffer.writeln('    // Override with user-provided actions');
    buffer.writeln('    actions?.forEach((id, fn) => _machine.attachAction(id, fn));');
    buffer.writeln();
    buffer.writeln('    _parser = _machine.createParser();');
    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  SMParser get parser => _parser;');
    buffer.writeln('  ImportedStateMachine get machine => _machine;');
    buffer.writeln();
    buffer.writeln('  ParseOutcome parse(String input) => _parser.parse(input);');
    buffer.writeln('  Iterable<ParseDerivation> enumerateAllParses(String input) =>');
    buffer.writeln('    _parser.enumerateAllParses(input);');
    buffer.writeln(
      '  Iterable<ParseDerivationWithValue> enumerateAllParsesWithResults(String input) =>',
    );
    buffer.writeln('    _parser.enumerateAllParsesWithResults(input);');
    buffer.writeln('}');
  }

  String _toPascalCase(String input) {
    return input
        .split('_')
        .map((word) => word[0].toUpperCase() + word.substring(1).toLowerCase())
        .join('');
  }

  String _toSnakeCase(String input) {
    return input.replaceAllMapped(
      RegExp(r'([a-z])([A-Z])'),
      (m) => '${m[1]}_${m[2]}'.toLowerCase(),
    );
  }
}
