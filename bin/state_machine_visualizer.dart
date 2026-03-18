#!/usr/bin/env dart

/// Command-line utility for generating state machine DOT graphs
///
/// Usage:
///   dart run bin/state_machine_visualizer.dart <grammar_file> [output.dot]
///
/// Example:
///   dart run bin/state_machine_visualizer.dart grammar.glush output.dot
///   dot -Tpng output.dot -o output.png

import 'package:glush/glush.dart';
import 'dart:io';
import 'dart:async';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    printUsage();
    exit(1);
  }

  final grammarFile = args[0];
  final outputFile = args.length > 1 ? args[1] : 'state_machine.dot';
  final simplified = args.contains('--simplified');
  final report = args.contains('--report');
  final rankdir = !args.contains('--vertical');

  try {
    // Read grammar file
    if (!File(grammarFile).existsSync()) {
      stderr.writeln('Error: Grammar file not found: $grammarFile');
      exit(1);
    }

    final content = File(grammarFile).readAsStringSync();
    print('Reading grammar from: $grammarFile');

    // Parse and compile grammar
    print('Compiling grammar...');
    final parser = GrammarFileParser(content);
    final parsedGrammarFile = parser.parse();
    final compiler = GrammarFileCompiler(parsedGrammarFile);
    final grammar = compiler.compile();

    // Compile to state machine
    print('Building state machine...');
    final stateMachine = StateMachine(grammar);

    // Generate graph
    print('Generating ${simplified ? 'simplified ' : ''}DOT graph...');
    final generator = stateMachine.createGraphGenerator(rankdir: rankdir);
    final dot = simplified ? generator.generateSimplified() : generator.generate();

    // Write output
    File(outputFile).writeAsStringSync(dot);
    print('✓ DOT graph saved to: $outputFile');

    if (report) {
      final reportText = generator.generateReport();
      print('\n$reportText');

      // Also save report to file
      final reportFile = outputFile.replaceAll('.dot', '.txt');
      File(reportFile).writeAsStringSync(reportText);
      print('✓ Report saved to: $reportFile');
    }

    // Print next steps
    print('\nNext steps:');
    print('  1. Visualize with Graphviz:');
    print('     dot -Tpng $outputFile -o ${outputFile.replaceAll('.dot', '.png')}');
    print('  2. Or use other formats: -Tsvg, -Tpdf, etc.');
    print('  3. View the image with your favorite image viewer');
  } catch (e, st) {
    stderr.writeln('Error: $e');
    if (args.contains('--verbose')) {
      stderr.writeln(st);
    }
    exit(1);
  }
}

void printUsage() {
  print('''
State Machine DOT Graph Generator

Usage:
  dart run bin/state_machine_visualizer.dart <grammar_file> [options] [output_file]

Arguments:
  grammar_file    Path to .glush grammar file (required)
  output_file     Output DOT file (default: state_machine.dot)

Options:
  --simplified    Generate simplified graph (fewer details)
  --report        Also generate and save a text report
  --vertical      Use vertical layout (default is left-to-right)
  --verbose       Show detailed error messages
  --help          Show this help message

Examples:
  # Generate default DOT graph
  dart run bin/state_machine_visualizer.dart grammar.glush

  # Generate with custom output filename
  dart run bin/state_machine_visualizer.dart grammar.glush my_graph.dot

  # Generate simplified graph and report
  dart run bin/state_machine_visualizer.dart grammar.glush --simplified --report

  # Generate and immediately visualize (requires Graphviz)
  dart run bin/state_machine_visualizer.dart grammar.glush output.dot && \\
    dot -Tpng output.dot -o output.png && \\
    open output.png

Tips:
  - Install Graphviz: https://graphviz.org/download/
  - On macOS: brew install graphviz
  - On Linux: apt-get install graphviz
  - On Windows: choco install graphviz
''');
}
