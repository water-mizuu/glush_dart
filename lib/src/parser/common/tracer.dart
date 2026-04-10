import "dart:async";
import "dart:io";

import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/common/frame.dart";
import "package:glush/src/parser/key/caller_key.dart";
import "package:glush/src/parser/state_machine/state_actions.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";

/// Interface for tracing parser execution.
abstract class ParseTracer {
  void onStart(StateMachine sm);
  void onStepStart(int position, int? token, List<Frame> frames);
  void onProcessState(Frame frame, State state);
  void onAction(StateAction action, String result);
  void onEnqueue(State state, int targetPosition, String reason);
  void onRuleCall(Rule rule, int position, CallerKey caller);
  void onRuleReturn(Rule rule, int position, CallerKey caller);
  void onPredicateResumed(PatternSymbol symbol, int position, {required bool isAnd});
  void onTrackerUpdate(String type, String key, int activeFrames, String action);
  void onMessage(String message);
  void finalize();
}

/// A tracer that writes to a file.
class FileTracer implements ParseTracer {
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
        } else if (action is BackreferenceAction) {
          next = action.nextState;
        } else if (action is ParameterAction) {
          next = action.nextState;
        } else if (action is ConjunctionAction) {
          next = action.nextState;
        } else if (action is NegationAction) {
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
  void onRuleCall(Rule rule, int position, CallerKey caller) {
    _sink.writeln("  [> Call]    ${rule.name} at pos $position (caller: $caller)");
  }

  @override
  void onRuleReturn(Rule rule, int position, CallerKey caller) {
    _sink.writeln("  [< Return]  ${rule.name} at pos $position (to: $caller)");
  }

  @override
  void onPredicateResumed(PatternSymbol symbol, int position, {required bool isAnd}) {
    _sink.writeln("    ! Predicate matched: $symbol (AND: $isAnd) at pos $position");
  }

  @override
  void onTrackerUpdate(String type, String key, int activeFrames, String action) {
    _sink.writeln("  [T Tracker] $type($key) -> $action (activeFrames: $activeFrames)");
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

/// A no-op tracer.
class NullTracer implements ParseTracer {
  const NullTracer();

  @override
  void onStart(StateMachine sm) {}

  @override
  void onStepStart(int position, int? token, List<Frame> frames) {}

  @override
  void onProcessState(Frame frame, State state) {}

  @override
  void onAction(StateAction action, String result) {}

  @override
  void onEnqueue(State state, int targetPosition, String reason) {}

  @override
  void onRuleCall(Rule rule, int position, CallerKey caller) {}

  @override
  void onRuleReturn(Rule rule, int position, CallerKey caller) {}

  @override
  void onPredicateResumed(PatternSymbol symbol, int position, {required bool isAnd}) {}

  @override
  void onTrackerUpdate(String type, String key, int activeFrames, String action) {}

  @override
  void onMessage(String message) {}

  @override
  void finalize() {}
}
