import "dart:async";
import "dart:io";

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
/// lookahead or conjunctions.
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

  /// Called when a tracker (predicate or conjunction) is updated.
  void onTrackerUpdate(String type, String key, int pendingFrames, String action);

  /// Records an arbitrary diagnostic message.
  void onMessage(String message);

  /// Finalizes the tracer, closing any open resources.
  void finalize();
}

/// A [ParseTracer] implementation that writes human-readable execution logs to a file.
class FileTracer implements ParseTracer {
  /// Creates a [FileTracer] that writes to the file at [path].
  FileTracer(String path) : _sink = File(path).openWrite();
  final IOSink _sink;

  @override
  void onStart(StateMachine sm) {
    _sink.writeln("STATE MACHINE VISUALIZATION");
    _sink.writeln("=" * 80);
    for (var state in sm.states) {
      _sink.writeln("State ${state.id}");
      for (var action in state.actions) {
        var actionText = action.toString();
        var nextId = "";

        // Safely extract nextState ID if available on the action type
        State? next;
        if (action is TokenAction) {
          next = action.nextState;
        } else if (action is MarkAction) {
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
        } else if (action is ParameterAction) {
          next = action.nextState;
        } else if (action is ConjunctionAction) {
          next = action.nextState;
        }

        if (next != null) {
          nextId = " -> State ${next.id}";
        } else if (action is ReturnAction || action is TailCallAction) {
          nextId = " -> [GSS Return]";
        }
        _sink.writeln("  [Action] $actionText$nextId");
      }
      _sink.writeln("-" * 40);
    }
    _sink.writeln("=" * 80 + "\n");
  }

  @override
  void onStepStart(int position, int? token, List<Frame> frames) {
    _sink.writeln("\n${"=" * 80}");
    _sink.writeln(
      "POSITION: $position, TOKEN: ${token != null ? "'${String.fromCharCode(token)}'" : 'EOF'}",
    );
    _sink.writeln("-" * 80);
    _sink.writeln("Active set of states (${frames.length} frames):");
    for (var i = 0; i < frames.length; i++) {
      var frame = frames[i];
      var states = frame.nextStates.map((s) => s.toString()).join(", ");
      _sink.writeln("  Frame $i:");
      _sink.writeln("    States:  {$states}");
      _sink.writeln(
        "    Context: caller=${frame.context.caller}, marks=${frame.marks.evaluate().iterate().toList().length}",
      );
    }
    _sink.writeln("=" * 80 + "\n");
  }

  @override
  void onProcessState(Frame frame, State state) {
    _sink.writeln("  [* Process] $state");
    _sink.writeln(
      "      Context: caller=${frame.context.caller}, marks=${frame.marks.evaluate().iterate().toList().length}",
    );
  }

  @override
  void onAction(StateAction action, String result) {
    _sink.writeln("    [> Action]  $action -> $result");
  }

  @override
  void onEnqueue(State state, int targetPosition, String reason) {
    _sink.writeln("  [+ Queue]   $state at pos $targetPosition ($reason)");
  }

  @override
  void onRuleCall(Rule rule, int position, CallerKey caller, State fromState, State toState) {
    _sink.writeln("  [> Call]    State(${fromState.id}) -> State(${toState.id}) at pos $position");
  }

  @override
  void onRuleReturn(Rule rule, int position, CallerKey caller, State? fromState) {
    if (fromState != null) {
      _sink.writeln("  [< Return]  State(${fromState.id}) at pos $position");
    }
  }

  @override
  void onPredicateResumed(PatternSymbol symbol, int position, {required bool isAnd}) {
    _sink.writeln("    ! Predicate matched: $symbol (AND: $isAnd) at pos $position");
  }

  @override
  void onTrackerUpdate(String type, String key, int pendingFrames, String action) {
    _sink.writeln("  [T Tracker] $type($key) -> $action (pendingFrames: $pendingFrames)");
  }

  @override
  void onMessage(String message) {
    _sink.writeln("    ! $message");
  }

  @override
  void finalize() {
    unawaited(_sink.close());
  }
}
