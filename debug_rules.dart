import "package:glush/glush.dart";

void main() {
  const grammar = r"""
S = $2 &(S S) S S
  | $1 's'
""";

  var parser = grammar.toSMParser();
  var sm = parser.stateMachine;

  print("All rules in state machine:");
  for (var state in sm.states) {
    print('State ${state.id}: ${state.actions.join(", ")}');
  }
}
