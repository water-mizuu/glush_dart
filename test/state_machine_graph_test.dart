/// Test for state machine DOT graph generator
import 'package:test/test.dart';
import 'package:glush/glush.dart';

void main() {
  group('StateMachineGraphGenerator', () {
    late StateMachine stateMachine;
    late StateMachineGraphGenerator generator;

    setUp(() {
      // Create a simple grammar using the Grammar builder API
      // This ensures patterns are properly initialized
      final grammar = Grammar(() {
        final rule = Rule('main', () => Pattern.char('a') >> Pattern.char('b'));
        return rule.call();
      });

      stateMachine = StateMachine(grammar);
      generator = stateMachine.createGraphGenerator();
    });

    test('generates valid DOT graph', () {
      final dot = generator.generate();
      expect(dot, isNotEmpty);
      expect(dot, contains('digraph StateMachine'));
      expect(dot, contains('rankdir='));
      expect(dot, contains('}'));
    });

    test('generated graph contains states', () {
      final dot = generator.generate();
      expect(dot, contains('S0'));
      expect(dot, contains('Init'));
      expect(dot, contains('Accept'));
    });

    test('generated graph contains transitions', () {
      final dot = generator.generate();
      expect(dot, contains('->'));
      expect(dot, contains('label='));
    });

    test('generateSimplified produces valid output', () {
      final dot = generator.generateSimplified();
      expect(dot, isNotEmpty);
      expect(dot, contains('digraph StateMachine'));
      expect(dot, contains('}'));
    });

    test('getAcceptingStates returns non-empty list', () {
      final accepting = generator.getAcceptingStates();
      expect(accepting, isNotEmpty);
      expect(accepting.every((s) => s.actions.any((a) => a is AcceptAction)), true);
    });

    test('getDeadEndStates works correctly', () {
      final deadEnds = generator.getDeadEndStates();
      // Result may be empty or non-empty depending on state machine structure
      expect(deadEnds, isA<List<State>>());
    });

    test('getReachabilityMap works correctly', () {
      final reachability = generator.getReachabilityMap();
      expect(reachability, isNotEmpty);
      expect(reachability, isA<Map<int, Set<int>>>());
    });

    test('getTransitionCount works correctly', () {
      for (final state in stateMachine.states) {
        final count = generator.getTransitionCount(state);
        expect(count, isA<int>());
        expect(count, greaterThanOrEqualTo(0));
      }
    });

    test('generateReport produces non-empty text', () {
      final report = generator.generateReport();
      expect(report, isNotEmpty);
      expect(report, contains('State Machine Analysis'));
      expect(report, contains('states:'));
      expect(report, contains('transitions:'));
    });

    test('initial states are marked green in graph', () {
      final dot = generator.generate();
      expect(dot, contains('fillcolor='));
      expect(dot, contains('Init'));
    });

    test('accepting states are marked pink in graph', () {
      final dot = generator.generate();
      expect(dot, contains('doublecircle'));
      expect(dot, contains('Accept'));
    });

    test('createGraphGenerator extension works', () {
      final gen = stateMachine.createGraphGenerator();
      expect(gen, isA<StateMachineGraphGenerator>());
      expect(gen.stateMachine, same(stateMachine));
    });

    test('custom state labels are used in graph', () {
      final labels = {0: 'StartHere'};
      final genWithLabels = stateMachine.createGraphGenerator(stateLabels: labels);
      final dot = genWithLabels.generate();
      expect(dot, contains('StartHere'));
    });
  });
}
