import "package:glush/glush.dart";

void main() {
  const grammar = r"""
S = $2 &(S S) S S
  | $1 's'
""";

  var parser = grammar.toSMParser();
  var sm = parser.stateMachine;

  print("All rules in state machine:");
  for (var (index, rule) in sm.ruleFirst.whereType<State>().indexed) {
    print("  $index: entry state is State(${rule.id})");
  }

  print("\nAll states:");
  for (var state in sm.states) {
    print('State ${state.id}: ${state.actions.join(", ")}');
  }
}
