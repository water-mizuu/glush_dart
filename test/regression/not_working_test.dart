import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("related bugs", () {
    var parser = "S = S S S | S S | 's'".toSMParser();
    const testInput = "ss";
    var derivationCount = parser.countAllParses(testInput);
    var derivations =
        parser
            .parseAmbiguous(testInput, tracer: PrintTracer())
            .ambiguousSuccess()
            ?.forest
            .allMarkPaths()
            .toList() ??
        [];

    var result = parser.parseAmbiguous(testInput);
    test("Grammar", () {
      expect(result, isA<ParseAmbiguousSuccess>());

      // Verify counts match
      expect(derivations.length, equals(derivationCount.toInt()));
    });
  });
}

class PrintTracer implements ParseTracer {
  PrintTracer();

  @override
  void onStart(StateMachine sm) {
    print("STATE MACHINE VISUALIZATION");
    print("=" * 80);
    for (var state in sm.states) {
      print("State ${state.id}");
      for (var action in state.actions) {
        var actionText = action.toString();
        var nextId = "";

        // Safely extract nextState ID if available on the action type
        State? next;
        if (action is TokenAction) {
          next = action.nextState;
        } else if (action is CallAction) {
          next = action.returnState;
        } else if (action is PredicateAction) {
          next = action.nextState;
        } else if (action is BoundaryAction) {
          next = action.nextState;
        } else if (action is LabelStartAction) {
          next = action.nextState;
        } else if (action is LabelEndAction) {
          next = action.nextState;
        }

        if (next != null) {
          nextId = " -> State ${next.id}";
        } else if (action is ReturnAction || action is TailCallAction) {
          nextId = " -> [GSS Return]";
        }
        print("  [Action] $actionText$nextId");
      }
      print("-" * 40);
    }
    print("=" * 80 + "\n");
  }

  @override
  void onStepStart(int position, int? token, List<Frame> frames) {
    print("\n${"=" * 80}");
    print(
      "POSITION: $position, TOKEN: ${token != null ? "'${String.fromCharCode(token)}'" : 'EOF'}",
    );
    print("-" * 80);
    print("Active set of states (${frames.length} frames):");
    for (var i = 0; i < frames.length; i++) {
      var frame = frames[i];
      var states = frame.nextStates.map((s) => s.toString()).join(", ");
      print("  Frame $i:");
      print("    States:  {$states}");
      print(
        "    Context: caller=${frame.context.caller}, marks=${frame.marks.evaluate().iterate().toList().length}",
      );
    }
    print("=" * 80 + "\n");
  }

  @override
  void onProcessState(Frame frame, State state) {
    print("  [* Process] $state");
    print(
      "      Context: caller=${frame.context.caller}, marks=${frame.marks.evaluate().iterate().toList().length}",
    );
  }

  @override
  void onAction(StateAction action, String result) {
    print("    [> Action]  $action -> $result");
  }

  @override
  void onEnqueue(State state, int targetPosition, String reason) {
    print("  [+ Queue]   $state at pos $targetPosition ($reason)");
  }

  @override
  void onRuleCall(Rule rule, int position, CallerKey caller, State fromState, State toState) {
    print("  [> Call]    State(${fromState.id}) -> State(${toState.id}) at pos $position");
  }

  @override
  void onRuleReturn(Rule rule, int position, CallerKey caller, State? fromState) {
    if (fromState != null) {
      print("  [< Return]  State(${fromState.id}) at pos $position");
    }
  }

  @override
  void onPredicateResumed(PatternSymbol symbol, int position, {required bool isAnd}) {
    print("    ! Predicate matched: $symbol (AND: $isAnd) at pos $position");
  }

  @override
  void onTrackerUpdate(String type, String key, int pendingFrames, String action) {
    print("  [T Tracker] $type($key) -> $action (pendingFrames: $pendingFrames)");
  }

  @override
  void onMessage(String message) {
    print("    ! $message");
  }

  @override
  void finalize() {}
}
