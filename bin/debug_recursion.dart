import 'package:glush/glush.dart';
import 'package:glush/src/sm_parser.dart';

void main() {
  const depth = 1; // Minimal depth: 1+1
  final grammar = Grammar(() {
    late final Rule e;
    final digit = Token.char('1');
    final plus = Token.char('+');

    e = Rule('E', () => (digit >> plus >> e.call()) | digit);
    return e.call();
  });

  final input = '1+' * depth + '1';
  final parser = SMParser(grammar, fastMode: true);
  print('Input: $input');
  
  print('\nState Machine:');
  for (final state in parser.stateMachine.states) {
    print('State ${state.id}:');
    for (final action in state.actions) {
      if (action is TokenAction) {
        print('  Token: ${action.pattern} -> State ${action.nextState.id}');
      } else if (action is CallAction) {
        print('  Call: ${action.rule.name} -> Return State ${action.returnState.id}');
      } else if (action is ReturnAction) {
        print('  Return: ${action.rule.name}');
      } else if (action is AcceptAction) {
        print('  Accept');
      } else if (action is MarkAction) {
        print('  Mark: ${action.name} -> State ${action.nextState.id}');
      }
    }
  }

  print('\nInitial States: ${parser.stateMachine.initialStates.map((s) => s.id)}');
  print('Rule First States:');
  parser.stateMachine.ruleFirst.forEach((rule, states) {
    print('  ${rule.name}: ${states.map((s) => s.id)}');
  });

  print('\nRunning Parse...');
  final res = parser.recognize(input);
  print('Result: $res');
}
