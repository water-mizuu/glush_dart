/// Core parser utilities and data structures for the Glush Dart parser.
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/parser/common/label_capture.dart";
import "package:glush/src/parser/common/step.dart" show Step;
import "package:glush/src/parser/key/caller_key.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";
import "package:meta/meta.dart";

/// Represents a unique parsing configuration at a specific input position.
///
/// A [Context] tracks the state of the \"virtual parser\" including:
/// - The caller stack (represented as a link to a GSS [Caller])
/// - Active lookahead predicates (the [predicateStack])
/// - Dynamic label captures (the [captures] map)
/// - Rule arguments (resolved once at construction)
@immutable
class Context {
  Context(
    this.caller, {
    this.arguments = const <String, Object?>{},
    this.captures = const CaptureBindings.empty(),
    this.predicateStack = const GlushList<PredicateCallerKey>.empty(),
    this.callStart = 0,
    this.position = 0,
    this.minPrecedenceLevel,
    this.precedenceLevel,
  }) : _hash = Object.hash(
         caller,
         callStart,
         position,
         minPrecedenceLevel,
         precedenceLevel,
         captures,
         predicateStack,
         _mapHashCode(arguments),
       ),
       isSimple = predicateStack.isEmpty && captures.isEmpty && arguments.isEmpty;

  final int _hash;

  /// Whether this context has no lookahead predicates, captures, or arguments.
  final bool isSimple;

  /// The GRAPH-SHARED STACK (GSS) node representing the current call hierarchy.
  final CallerKey caller;

  /// The resolved arguments for this context.
  final Map<String, Object?> arguments;

  /// Bindings for data captured via structural labels (name:pattern).
  final CaptureBindings captures;

  /// The stack of active lookahead predicates currently being evaluated.
  final GlushList<PredicateCallerKey> predicateStack;

  /// The position in the input where the current rule call began.
  final int callStart;

  /// Where this parse path has advanced to in the input.
  ///
  /// This is distinct from the position:
  /// - [Step.position]: the global current position the parser is processing
  /// - [Context.position]: how far THIS FRAME has consumed input
  ///
  /// These can differ when:
  /// - A frame is "lagging" (deferred sub-parse, predicate) and hasn't caught up yet
  /// - Multiple parse paths are interleaved (some at position 10, their frames
  ///   at [Context.position] 7)
  ///
  /// Lagging frames use Step.parseState.historyByPosition to retrieve tokens
  /// from their [Context.position] rather than the current Step.position.
  final int position;

  /// The current minimum precedence level allowed for rule expansion.
  final int? minPrecedenceLevel;

  /// The precedence level of the rule currently being parsed.
  final int? precedenceLevel;

  /// Creates a copy of this context with the specified fields updated.
  Context copyWith({
    CallerKey? caller,
    Map<String, Object?>? arguments,
    CaptureBindings? captures,
    GlushList<PredicateCallerKey>? predicateStack,
    int? callStart,
    int? position,
    int? minPrecedenceLevel,
    int? precedenceLevel,
  }) {
    return Context(
      caller ?? this.caller,
      arguments: arguments ?? this.arguments,
      captures: captures ?? this.captures,
      predicateStack: predicateStack ?? this.predicateStack,
      callStart: callStart ?? this.callStart,
      position: position ?? this.position,
      minPrecedenceLevel: minPrecedenceLevel ?? this.minPrecedenceLevel,
      precedenceLevel: precedenceLevel ?? this.precedenceLevel,
    );
  }

  /// Fast-path for the common case where only the position advances.
  /// Avoids recomputing the full hash when nothing else changes.
  Context advancePosition(int newPosition) {
    if (newPosition == position) {
      return this;
    }
    return Context(
      caller,
      arguments: arguments,
      captures: captures,
      predicateStack: predicateStack,
      callStart: callStart,
      position: newPosition,
      minPrecedenceLevel: minPrecedenceLevel,
      precedenceLevel: precedenceLevel,
    );
  }

  /// Creates a copy of this context for a rule call.
  Context withCaller(CallerKey nextCaller, {Map<String, Object?>? arguments}) {
    if (identical(nextCaller, caller) && arguments == null) {
      return this;
    }
    return Context(
      nextCaller,
      arguments:
          arguments ?? (nextCaller is Caller ? nextCaller.arguments : const <String, Object?>{}),
      captures: captures,
      predicateStack: predicateStack,
      callStart: callStart,
      position: position,
      minPrecedenceLevel: minPrecedenceLevel,
      precedenceLevel: precedenceLevel,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Context &&
          hashCode == other.hashCode &&
          caller == other.caller &&
          callStart == other.callStart &&
          position == other.position &&
          minPrecedenceLevel == other.minPrecedenceLevel &&
          precedenceLevel == other.precedenceLevel &&
          captures == other.captures &&
          predicateStack == other.predicateStack &&
          _mapEquals(arguments, other.arguments);

  static bool _mapEquals(Map<Object?, Object?>? a, Map<Object?, Object?>? b) {
    if (identical(a, b)) {
      return true;
    }
    if (a == null || b == null) {
      return false;
    }
    if (a.length != b.length) {
      return false;
    }
    for (var key in a.keys) {
      if (!b.containsKey(key) || b[key] != a[key]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => _hash;

  static int? _mapHashCode(Map<Object?, Object?>? m) {
    if (m == null || m.isEmpty) {
      return null;
    }
    return Object.hashAll(m.keys.cast<Object?>().followedBy(m.values));
  }
}

/// Helper for grouping context-equivalent frames during token transitions.
///
/// When multiple frames advance to the same state/caller/position, they are
/// grouped into a single [ContextGroup] so that their marks and derivations
/// can be merged into a single branched node.
final class ContextGroup {
  ContextGroup(this.state, this.context);

  final State state;
  final Context context;

  /// Batch mark accumulation: stored in a list, merged into a balanced tree on access.
  LazyGlushList<Mark>? _single;
  List<LazyGlushList<Mark>>? _batch;

  LazyGlushList<Mark> get mergedMarks {
    if (_batch case var batch?) {
      return _buildBalanced(batch, 0, batch.length);
    }
    return _single ?? const LazyGlushList<Mark>.empty();
  }

  void addMarks(LazyGlushList<Mark> marks) {
    if (_single == null && _batch == null) {
      _single = marks;
      return;
    }
    if (_batch == null) {
      _batch = [_single!, marks];
      _single = null;
    } else {
      _batch!.add(marks);
    }
  }

  static LazyGlushList<Mark> _buildBalanced(List<LazyGlushList<Mark>> items, int start, int end) {
    var len = end - start;
    if (len == 0) {
      return const LazyGlushList<Mark>.empty();
    }
    if (len == 1) {
      return items[start];
    }
    if (len == 2) {
      return LazyGlushList.branched(items[start], items[start + 1]);
    }
    var mid = start + (len >> 1);
    return LazyGlushList.branched(
      _buildBalanced(items, start, mid),
      _buildBalanced(items, mid, end),
    );
  }
}
