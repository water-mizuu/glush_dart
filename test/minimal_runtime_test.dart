import 'dart:io';
import 'package:test/test.dart';
import 'package:glush/src/grammar.dart';
import 'package:glush/src/state_machine_export.dart';
import 'package:glush/src/state_machine_codegen.dart';
import 'package:glush/src/patterns.dart';

void main() {
  group('Minimal Runtime Codegen', () {
    test('Generated code is self-contained and works', () async {
      final grammar = Grammar(() {
        final a = Rule('A', () => Pattern.char('a') | Pattern.char('b'));
        return a;
      });

      final exported = StateMachineExporter.export(grammar.stateMachine);

      final codegen = StateMachineCodeGenerator(exported, grammarName: 'simple');
      final generated = codegen.generateMinimalStandalone();

      // Ensure it contains the necessary parts
      expect(generated, contains('class SimpleParser'));
      expect(generated, contains('class SimpleActions'));
      expect(generated, contains('const String _simpleStateMachineJson'));
      expect(generated, contains('class SMParser'));
      expect(generated, contains('import \'dart:convert\';'));

      // Ensure it does NOT contain glush imports
      expect(generated, isNot(contains('package:glush/')));

      // Write to a temporary file
      final tempDir = Directory.systemTemp.createTempSync('glush_test');
      final parserFile = File('${tempDir.path}/simple_parser.dart');
      parserFile.writeAsStringSync(generated);

      // Create a driver script
      final driverFile = File('${tempDir.path}/driver.dart');
      driverFile.writeAsStringSync('''
        import 'simple_parser.dart';
        import 'dart:io';

        void main() {
          final parser = SimpleParser();

          final result1 = parser.parse('a');
          if (result1 is! ParseSuccess) {
            print('FAIL: Expected success for "a"');
            exit(1);
          }

          final result2 = parser.parse('b');
          if (result2 is! ParseSuccess) {
            print('FAIL: Expected success for "b"');
            exit(1);
          }

          final result3 = parser.parse('c');
          if (result3 is ParseSuccess) {
            print('FAIL: Expected error for "c"');
            exit(1);
          }

          print('SUCCESS');
        }
        ''');

      // Run the driver
      final result = await Process.run('dart', ['run', driverFile.path]);

      if (result.exitCode != 0) {
        print('Stdout: ${result.stdout}');
        print('Stderr: ${result.stderr}');
      }

      expect(result.exitCode, equals(0));
      expect(result.stdout.trim(), contains('SUCCESS'));

      // Clean up
      tempDir.deleteSync(recursive: true);
    });

    test('Works with semantic actions', () async {
      final grammar = Grammar(() {
        final a = Rule(
          'A',
          () => (Pattern.char('a') | Pattern.char('b')).withAction((span, _) => span.toUpperCase()),
        );
        return a;
      });

      final exported = StateMachineExporter.export(grammar.stateMachine);

      final codegen = StateMachineCodeGenerator(exported, grammarName: 'action');
      final generated = codegen.generateMinimalStandalone();

      final actionIdMatch = RegExp(r'_machine\.attachAction\("([^"]+)",').firstMatch(generated);
      final actionId = actionIdMatch?.group(1) ?? 'act:A_action:';

      print('DEBUG: Found actionId: $actionId');

      final tempDir = Directory.systemTemp.createTempSync('glush_test_action');
      final parserFile = File('${tempDir.path}/action_parser.dart');
      parserFile.writeAsStringSync(generated);

      final driverFile = File('${tempDir.path}/driver.dart');
      driverFile.writeAsStringSync('''
        import 'action_parser.dart';
        import 'dart:io';

        void main() {
          // Override the action
          final parser = ActionParser(actions: {
            '$actionId': (String span, List results) => span.toUpperCase(),
          });

          final result = parser.parse('a');
          if (result is ParseSuccess) {
            if (result.semanticValue != 'A') {
              print('FAIL: Expected "A", got "\${result.semanticValue}"');
              print('DEBUG: actionId matched was $actionId');
              exit(1);
            }
            print('SUCCESS');
          } else {
            print('FAIL: Parse failed');
            exit(1);
          }
        }
        ''');

      final result = await Process.run('dart', ['run', driverFile.path]);
      if (result.exitCode != 0) {
        print('Stdout: ${result.stdout}');
        print('Stderr: ${result.stderr}');
        print('Generated parser content:\n$generated');
      }
      expect(result.exitCode, equals(0));
      expect(result.stdout.trim(), contains('SUCCESS'));

      tempDir.deleteSync(recursive: true);
    });
  });
}
