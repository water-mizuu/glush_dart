/// Code generator for grammar files
library glush.grammar_codegen;

import 'dart:io';
import 'grammar_file_format.dart';
import 'grammar_file_parser.dart';
import 'runtime_bundle.dart';

/// Generates Dart code from a parsed grammar file
class GrammarCodeGenerator {
  final GrammarFile grammarFile;

  GrammarCodeGenerator(this.grammarFile);

  /// Generate a standalone Dart file that can be used independently without the glush library.
  String generateStandaloneGrammarFile() {
    final buffer = StringBuffer();
    final grammarName = _toPascalCase(grammarFile.name);

    buffer.writeln('/// Auto-generated standalone parser for ${grammarFile.name}');
    buffer.writeln('/// Generated: ${DateTime.now()}');
    buffer.writeln();
    buffer.writeln('// --- BEGIN GLUSH RUNTIME ---');
    buffer.writeln(runtimeBundle);
    buffer.writeln('// --- END GLUSH RUNTIME ---');
    buffer.writeln();
    buffer.writeln('GrammarInterface _create${grammarName}Grammar() {');
    buffer.writeln('  return Grammar(() {');
    buffer.writeln(_generateRuleDeclarations());
    buffer.writeln('    return ${_getRuleVariable(grammarFile.startRule!.name)};');
    buffer.writeln('  });');
    buffer.writeln('}');
    buffer.writeln();
    buffer.writeln('/// Lazy-initialized parser for ${grammarFile.name}');
    buffer.writeln(
        'late final SMParser _${grammarFile.name}Parser = SMParser(_create${grammarName}Grammar());');
    buffer.writeln();
    buffer.writeln('/// Parse input text using the ${grammarFile.name} grammar');
    buffer
        .writeln('/// Returns the parse outcome containing the parse forest or error information');
    buffer.writeln('Iterable<ParseDerivation> parse${grammarName}(String input) {');
    buffer.writeln('  return _${grammarFile.name}Parser.enumerateAllParses(input);');
    buffer.writeln('}');
    buffer.writeln();
    buffer.writeln('/// Parse input text using the ${grammarFile.name} grammar');
    buffer.writeln('/// Returns the marks from the grammar');
    buffer.writeln('ParseOutcome<Object?> parse${grammarName}Marks(String input) {');
    buffer.writeln('  return _${grammarFile.name}Parser.parse(input);');
    buffer.writeln('}');

    return buffer.toString();
  }

  /// Generate a complete Dart file with the grammar definition
  String generateGrammarFile({String packageName = 'glush'}) {
    final buffer = StringBuffer();
    final grammarName = _toPascalCase(grammarFile.name);

    buffer.writeln("import 'package:$packageName/glush.dart';");
    buffer.writeln();
    buffer.writeln('/// Auto-generated grammar library from ${grammarFile.name}');
    buffer.writeln('/// Generated: ${DateTime.now()}');
    buffer.writeln();
    buffer.writeln('GrammarInterface _create${grammarName}Grammar() {');
    buffer.writeln('  return Grammar(() {');
    buffer.writeln(_generateRuleDeclarations());
    buffer.writeln('    return ${_getRuleVariable(grammarFile.startRule!.name)};');
    buffer.writeln('  });');
    buffer.writeln('}');
    buffer.writeln();
    buffer.writeln('/// Lazy-initialized parser for ${grammarFile.name}');
    buffer.writeln(
        'late final SMParser _${grammarFile.name}Parser = SMParser(_create${grammarName}Grammar());');
    buffer.writeln();
    buffer.writeln('/// Parse input text using the ${grammarFile.name} grammar');
    buffer
        .writeln('/// Returns the parse outcome containing the parse forest or error information');
    buffer.writeln('ParseOutcome parse${grammarName}(String input) {');
    buffer.writeln('  return _${grammarFile.name}Parser.parse(input);');
    buffer.writeln('}');

    return buffer.toString();
  }

  /// Generate declarations and assignments for all rules
  String _generateRuleDeclarations() {
    final buffer = StringBuffer();

    // Collect all rule names for late binding (if rules are recursive)
    final ruleNames = grammarFile.rules.map((r) => r.name).toList();

    // Late declarations for mutually recursive rules
    if (ruleNames.length > 1) {
      buffer.writeln('    late Rule ${ruleNames.map((n) => _getRuleVariable(n)).join(', ')};');
    }

    // Rule definitions
    for (final rule in grammarFile.rules) {
      final ruleVar = _getRuleVariable(rule.name);
      buffer.write('    $ruleVar = Rule(' '"${rule.name}"' ', () => ');

      String patternCode = _generatePatternCode(rule.pattern, rule.precedenceLevels);
      if (rule.marks.isNotEmpty) {
        final marksCode = rule.marks.map((m) => 'Marker("$m")').join(' >> ');
        patternCode = '$marksCode >> ($patternCode)';
      }

      buffer.write(patternCode);
      buffer.writeln(');');
    }

    return buffer.toString();
  }

  /// Generate Dart code for a pattern expression
  /// Tracks precedence levels so they can be wrapped with PrecedenceLabeledPattern
  String _generatePatternCode(PatternExpr pattern,
      [Map<PatternExpr, int> precedenceLevels = const {}]) {
    if (pattern is LiteralPattern) {
      final codes = pattern.literal.split('').map((c) => c.codeUnitAt(0)).toList();
      if (codes.length == 1) {
        return 'Token(ExactToken(${codes[0]}))';
      }
      // Multiple characters: sequence of tokens
      final tokens = codes.map((code) => 'Token(ExactToken($code))').toList();
      return tokens.join(' >> ');
    }

    if (pattern is CharRangePattern) {
      if (pattern.ranges.length == 1) {
        final range = pattern.ranges[0];
        if (range.startCode == range.endCode) {
          return 'Token(ExactToken(${range.startCode}))';
        }
        return 'Token(RangeToken(${range.startCode}, ${range.endCode}))';
      }
      // Multiple ranges: alternation
      final tokens = pattern.ranges.map((range) {
        if (range.startCode == range.endCode) {
          return 'Token(ExactToken(${range.startCode}))';
        }
        return 'Token(RangeToken(${range.startCode}, ${range.endCode}))';
      }).toList();
      return tokens.join(' | ');
    }

    if (pattern is MarkerPattern) {
      return 'Marker("${pattern.name}")';
    }

    if (pattern is RuleRefPattern) {
      final ruleVar = _getRuleVariable(pattern.ruleName);
      String callCode;

      // Create RuleCall with precedence constraint if specified
      if (pattern.precedenceConstraint != null) {
        callCode = 'Call($ruleVar, minPrecedenceLevel: ${pattern.precedenceConstraint})';
      } else {
        callCode = 'Call($ruleVar)';
      }

      if (pattern.mark != null) {
        return 'Marker("${pattern.mark}") >> $callCode';
      }
      return callCode;
    }

    if (pattern is SequencePattern) {
      final parts = pattern.patterns.map((p) => _generatePatternCode(p, precedenceLevels)).toList();
      return parts.join(' >> ');
    }

    if (pattern is AlternationPattern) {
      final parts = pattern.patterns.map((p) {
        final code = _generatePatternCode(p, precedenceLevels);
        // Check if this pattern has a precedence level and wrap with .atLevel()
        if (precedenceLevels.containsKey(p)) {
          final level = precedenceLevels[p]!;
          final wrappedCode = (p is SequencePattern) ? '($code)' : code;
          return '$wrappedCode.atLevel($level)';
        }
        // Add parens if the part is a sequence
        if (p is SequencePattern) {
          return '($code)';
        }
        return code;
      }).toList();
      return parts.join(' | ');
    }

    if (pattern is RepetitionPattern) {
      final inner = _generatePatternCode(pattern.pattern, precedenceLevels);
      final code = (pattern.pattern is SequencePattern || pattern.pattern is AlternationPattern)
          ? '($inner)'
          : inner;

      return switch (pattern.kind) {
        RepetitionKind.zeroOrMore => '($code).star()',
        RepetitionKind.oneOrMore => '($code).plus()',
        RepetitionKind.optional => '($code).maybe()',
      };
    }

    if (pattern is GroupPattern) {
      return '(${_generatePatternCode(pattern.inner, precedenceLevels)})';
    }

    if (pattern is ConjunctionPattern) {
      final parts = pattern.patterns.map((p) => _generatePatternCode(p, precedenceLevels)).toList();
      return parts.join(' & ');
    }

    throw ArgumentError('Unknown pattern type: ${pattern.runtimeType}');
  }

  /// Generate a simple runner function
  String generateParserRunner({
    required String testInput,
    String functionName = 'parseExample',
  }) {
    final buffer = StringBuffer();

    buffer.writeln('/// Parse test input: "$testInput"');
    buffer.writeln('ParseOutcome parseExample() {');
    buffer.writeln('  final grammar = create${_toPascalCase(grammarFile.name)}Grammar();');
    buffer.writeln('  final parser = SMParser(grammar);');
    buffer.writeln('  final result = parser.parse(' '$testInput' ');');
    buffer.writeln('  return result;');
    buffer.writeln('}');

    return buffer.toString();
  }

  /// Convert snake_case or camelCase to PascalCase
  String _toPascalCase(String str) {
    return str
        .split(RegExp(r'[_-]'))
        .map((word) => word.isEmpty ? '' : word[0].toUpperCase() + word.substring(1))
        .join('');
  }

  /// Get the variable name for a rule (lowercase)
  String _getRuleVariable(String ruleName) {
    return ruleName[0].toLowerCase() + ruleName.substring(1);
  }
}

/// Helper function to generate a complete Dart file from grammar text
String generateGrammarDartFile(String grammarText, {String packageName = 'glush'}) {
  ensureRuntimeBundleUpToDate();
  final parser = GrammarFileParser(grammarText);
  final grammarFile = parser.parse();
  final generator = GrammarCodeGenerator(grammarFile);
  return generator.generateGrammarFile(packageName: packageName);
}

/// Helper function to generate a standalone Dart file from grammar text
/// This creates a self-contained file with no external dependencies
///
/// Automatically checks and regenerates the runtime bundle if lib/src/ has changed.
String generateStandaloneGrammarDartFile(String grammarText) {
  ensureRuntimeBundleUpToDate();
  final parser = GrammarFileParser(grammarText);
  final grammarFile = parser.parse();
  final generator = GrammarCodeGenerator(grammarFile);
  return generator.generateStandaloneGrammarFile();
}

/// Ensures the runtime bundle is up-to-date by checking file hashes.
/// If any files in lib/src/ have changed, this will automatically regenerate
/// the bundle and update the hash file.
///
/// This should be called before using [runtimeBundle] to ensure it contains
/// the latest code.
///
/// Returns true if the bundle was regenerated, false if it was already up-to-date.
bool ensureRuntimeBundleUpToDate() {
  try {
    final result = Process.runSync('dart', ['run', 'tool/check_bundle_hash.dart']);

    if (result.exitCode != 0) {
      print('WARNING: Bundle hash check failed');
      print(result.stderr);
      return false;
    }

    // The script will print whether it regenerated or not
    if (result.stdout.toString().contains('regenerated')) {
      return true;
    }
    return false;
  } catch (e) {
    print('WARNING: Could not run bundle hash check: $e');
    return false;
  }
}
