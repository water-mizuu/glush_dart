import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/common/frame.dart";
import "package:glush/src/parser/key/caller_key.dart";
import "package:glush/src/parser/state_machine/state_actions.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";

/// An interface for observing and recording the internal execution of the parser.
///
/// Implementations of [ParseTracer] can be used to generate logs, visualizations,
/// or diagnostic reports that help in understanding how the parser explores the
/// search space, handles ambiguities, and resolves complex conditions like
/// lookahead.
abstract class ParseTracer {
  /// Called once at the start of a parse session with the loaded [StateMachine].
  void onStart(StateMachine sm);

  /// Called at the beginning of each input position's processing.
  void onStepStart(int position, int? token, List<Frame> frames);

  /// Called when the parser begins processing a specific [State] in a [Frame].
  void onProcessState(Frame frame, State state);

  /// Called when a [StateAction] is executed, with a string describing the outcome.
  void onAction(StateAction action, String result);

  /// Called when a new configuration is enqueued for future processing.
  void onEnqueue(State state, int targetPosition, String reason);

  /// Called when a rule call is initiated.
  void onRuleCall(Rule rule, int position, CallerKey caller, State fromState, State toState);

  /// Called when a rule call returns.
  void onRuleReturn(Rule rule, int position, CallerKey caller, State? fromState);

  /// Called when a lookahead predicate sub-parse completes and resumes its parent.
  void onPredicateResumed(PatternSymbol symbol, int position, {required bool isAnd});

  /// Called when a tracker (predicate) is updated.
  void onTrackerUpdate(String type, String key, int pendingFrames, String action);

  /// Records an arbitrary diagnostic message.
  void onMessage(String message);

  /// Finalizes the tracer, closing any open resources.
  void finalize();
}

/// A [ParseTracer] implementation that writes human-readable execution logs to a file.
class SinkTracer implements ParseTracer {
  SinkTracer(this.sink);
  final StringSink sink;

  @override
  void onStart(StateMachine sm) {
    sink.writeln("STATE MACHINE VISUALIZATION");
    sink.writeln("=" * 80);
    for (var state in sm.states) {
      sink.writeln("State ${state.id}");
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
        sink.writeln("  [Action] $actionText$nextId");
      }
      sink.writeln("-" * 40);
    }
    sink.writeln("=" * 80 + "\n");
  }

  @override
  void onStepStart(int position, int? token, List<Frame> frames) {
    sink.writeln("\n${"=" * 80}");
    sink.writeln(
      "POSITION: $position, TOKEN: ${token != null ? "'${String.fromCharCode(token)}'" : 'EOF'}",
    );
    sink.writeln("-" * 80);
    sink.writeln("Active set of states (${frames.length} frames):");
    for (var i = 0; i < frames.length; i++) {
      var frame = frames[i];
      var states = frame.nextStates.map((s) => s.toString()).join(", ");
      sink.writeln("  Frame $i:");
      sink.writeln("    States:  {$states}");
      sink.writeln(
        "    Context: caller=${frame.context.caller}, marks=${frame.marks.evaluate().iterate().toList().length}",
      );
    }
    sink.writeln("=" * 80 + "\n");
  }

  @override
  void onProcessState(Frame frame, State state) {
    sink.writeln("  [* Process] $state");
    sink.writeln(
      "      Context: caller=${frame.context.caller}, marks=${frame.marks.evaluate().iterate().toList().length}",
    );
  }

  @override
  void onAction(StateAction action, String result) {
    sink.writeln("    [> Action]  $action -> $result");
  }

  @override
  void onEnqueue(State state, int targetPosition, String reason) {
    sink.writeln("  [+ Queue]   $state at pos $targetPosition ($reason)");
  }

  @override
  void onRuleCall(Rule rule, int position, CallerKey caller, State fromState, State toState) {
    sink.writeln("  [> Call]    State(${fromState.id}) -> State(${toState.id}) at pos $position");
  }

  @override
  void onRuleReturn(Rule rule, int position, CallerKey caller, State? fromState) {
    if (fromState != null) {
      sink.writeln("  [< Return]  State(${fromState.id}) at pos $position");
    }
  }

  @override
  void onPredicateResumed(PatternSymbol symbol, int position, {required bool isAnd}) {
    sink.writeln("    ! Predicate matched: $symbol (AND: $isAnd) at pos $position");
  }

  @override
  void onTrackerUpdate(String type, String key, int pendingFrames, String action) {
    sink.writeln("  [T Tracker] $type($key) -> $action (pendingFrames: $pendingFrames)");
  }

  @override
  void onMessage(String message) {
    sink.writeln("    ! $message");
  }

  @override
  void finalize() {}
}

// /// A [ParseTracer] implementation that writes human-readable execution logs to a file.
// class FileTracer extends SinkTracer {
//   /// Creates a [FileTracer] that writes to the file at [path].
//   FileTracer(String path) : super(File(path).openWrite());

//   @override
//   void finalize() {
//     unawaited((super._sink as IOSink).close());
//   }
// }

// class PrintTracer extends SinkTracer {
//   PrintTracer() : super(stdout);

//   @override
//   void finalize() {
//     unawaited(stdout.flush());
//   }
// }
