/// Example demonstrating state machine DOT graph generation and visualization
/// This example shows how to generate DOT graphs from a compiled state machine
/// and save them for visualization with Graphviz.

import 'package:glush/glush.dart';
import 'dart:io';

class SimpleExampleGrammar implements GrammarInterface {
  final main_rule = Rule('main', () {
    final hello = Pattern.string('hello');
    final space = Pattern.char(' ');
    final digit = Token.charRange('0', '9');
    final number = digit.plus();
    return hello >> space >> number;
  });

  @override
  Map<String, Pattern> get symbolRegistry => {};

  @override
  RuleCall get startCall => main_rule();

  @override
  List<Rule> get rules => [main_rule];

  @override
  bool isEmpty() => false;
}

void main() {
  // Example 1: Simple pattern matching grammar
  print('=== Example 1: Simple Pattern Matching ===\n');
  simplePatternExample();

  print('\n\n=== Example 2: Rules and Calls ===\n');
  rulesExample();

  print('\n\n=== Example 3: Complex Grammar ===\n');
  complexGrammarExample();
}

void simplePatternExample() {
  final grammar = SimpleExampleGrammar();
  final stateMachine = StateMachine(grammar);

  // Generate graph
  final generator = stateMachine.createGraphGenerator();

  // Print full DOT graph
  print('Full Graph (DOT format):');
  print(generator.generate());

  // Print statistics
  print('\n\nStatistics:');
  print(generator.generateReport());

  // Find special states
  print('\nAccepting states: ${generator.getAcceptingStates().map((s) => s.id).toList()}');
  print('Dead-end states: ${generator.getDeadEndStates().map((s) => s.id).toList()}');
  print('Initial states: ${stateMachine.initialStates.map((s) => s.id).toList()}');

  // Save to file
  final dotFile = File('state_machine_simple.dot');
  dotFile.writeAsStringSync(generator.generate());
  print('\nDOT graph saved to: state_machine_simple.dot');
  print('Visualize with: dot -Tpng state_machine_simple.dot -o state_machine_simple.png');
}

class ExprGrammar implements GrammarInterface {
  late final Rule exprRule;
  late final Rule termRule;
  late final Rule factorRule;

  ExprGrammar() {
    factorRule = Rule('factor', () {
      return (Pattern.char('(') >> exprRule() >> Pattern.char(')')) |
          (Token.charRange('0', '9').plus());
    });

    termRule = Rule('term', () {
      return factorRule() >>
          (((Pattern.char('*') | Pattern.char('/')) >> factorRule()).star());
    });

    exprRule = Rule('expr', () {
      return termRule() >>
          (((Pattern.char('+') | Pattern.char('-')) >> termRule()).star());
    });
  }

  @override
  Map<String, Pattern> get symbolRegistry => {};

  @override
  RuleCall get startCall => exprRule();

  @override
  List<Rule> get rules => [exprRule, termRule, factorRule];

  @override
  bool isEmpty() => false;
}

void rulesExample() {
  final grammar = ExprGrammar();
  final stateMachine = StateMachine(grammar);

  final generator = stateMachine.createGraphGenerator();

  print('Expression Grammar State Machine:');
  print(generator.generateSimplified()); // Use simplified version for complex grammars

  print('\n\nRules in grammar:');
  for (final rule in stateMachine.rules) {
    final firstStates = stateMachine.ruleFirst[rule];
    print('  ${rule.name}: ${firstStates?.length ?? 0} first states');
  }

  // Reachability analysis
  print('\n\nReachability Analysis:');
  final reachability = generator.getReachabilityMap();
  for (final entry in reachability.entries.take(5)) {
    print('  State ${entry.key} can reach: ${entry.value}');
  }
}

class VarDeclGrammar implements GrammarInterface {
  late final identifierRule = Rule('identifier', () {
    final letter = Token.charRange('a', 'z') | Token.charRange('A', 'Z');
    final digit = Token.charRange('0', '9');
    final underscore = Pattern.char('_');
    return (letter | underscore) >> (letter | digit | underscore).star();
  });

  late final declaration = Rule('declaration', () {
    final varKeyword = Pattern.string('var');
    final space = Pattern.char(' ');
    final spaces = space.plus();
    final equals = Pattern.char('=');
    final semicolon = Pattern.char(';');
    final digit = Token.charRange('0', '9');

    return varKeyword >>
        spaces >>
        identifierRule() >>
        spaces >>
        equals >>
        spaces >>
        (digit.plus()) >>
        semicolon;
  });

  @override
  Map<String, Pattern> get symbolRegistry => {};

  @override
  RuleCall get startCall => declaration();

  @override
  List<Rule> get rules => [declaration, identifierRule];

  @override
  bool isEmpty() => false;
}

void complexGrammarExample() {
  final grammar = VarDeclGrammar();
  final stateMachine = StateMachine(grammar);

  final generator = stateMachine.createGraphGenerator();

  print('Complex Grammar with Rules:');
  print(generator.generateSimplified());

  print('\n\nDetailed Report:');
  print(generator.generateReport());

  print('\n\nState Distribution:');
  print('Total states: ${stateMachine.states.length}');

  int totalActions = 0;
  final actionCounts = <String, int>{};

  for (final state in stateMachine.states) {
    for (final action in state.actions) {
      final actionType = action.runtimeType.toString();
      actionCounts[actionType] = (actionCounts[actionType] ?? 0) + 1;
      totalActions++;
    }
  }

  print('Action breakdown:');
  for (final entry in actionCounts.entries) {
    print('  ${entry.key}: ${entry.value}');
  }
  print('Total actions: $totalActions');
}
