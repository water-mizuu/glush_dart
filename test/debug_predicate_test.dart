import 'package:test/test.dart';
import 'package:glush/glush.dart';

void main() {
  // Simple test to debug predicates
  test('Simple AND predicate test', () {
    // Grammar: &'a' >> 'a'
    // This should match 'a' and only 'a'
    final grammar = Grammar(() {
      final a = Token(ExactToken(97)); // 'a'
      return Rule('test', () => a.and() >> a);
    });

    final parser = SMParser(grammar);

    print('Testing predicate grammar...');
    print('Recognize "a": ${parser.recognize("a")}');
    print('Recognize "b": ${parser.recognize("b")}');

    // Show what's in the state machine
    final sm = parser.stateMachine;
    print('\n=== State Machine Debug ===');
    print('Initial states: ${sm.initialStates}');
    print('Total states: ${sm.states.length}');
    for (final state in sm.states.take(5)) {
      print('  State $state:');
      for (final action in state.actions) {
        print('    Action: $action');
      }
    }
  });
}
