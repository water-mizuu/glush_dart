/// Core parser utilities and data structures for the Glush Dart parser.
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/parser/key/caller_key.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";
import "package:meta/meta.dart";

/// Represents a unique parsing configuration at a specific input position.
///
/// A [Context] tracks the state of a "virtual parser" as it moves through the
/// grammar. Because Glush is a non-deterministic parser, it can maintain
/// multiple active contexts simultaneously, each representing a different
/// interpretation of the input or a different path through the grammar.
///
/// Each context is immutable and includes:
/// - The GSS [caller] stack node.
/// - The [predicateStack] for nested lookahead predicates.
/// - Precedence constraints ([minPrecedenceLevel], [precedenceLevel]).
@immutable
class Context {
  /// Creates a [Context] with the given configuration.
  Context(
    CallerKey caller, {
    GlushList<PredicateCallerKey> predicateStack = const GlushList<PredicateCallerKey>.empty(),
    int callStart = 0,
    int position = 0,
    int? minPrecedenceLevel,
    int? precedenceLevel,
  }) : this._(
         caller,
         Object.hash(
           caller,
           callStart,
           position,
           minPrecedenceLevel,
           precedenceLevel,
           predicateStack,
         ),
         isSimple: predicateStack.isEmpty,
         predicateStack: predicateStack,
         callStart: callStart,
         position: position,
         minPrecedenceLevel: minPrecedenceLevel,
         precedenceLevel: precedenceLevel,
       );

  const Context._(
    this.caller,
    this._hash, {
    required this.isSimple,
    this.predicateStack = const GlushList<PredicateCallerKey>.empty(),
    this.callStart = 0,
    this.position = 0,
    this.minPrecedenceLevel,
    this.precedenceLevel,
  });

  final int _hash;

  /// Whether this context has no lookahead predicates or captures.
  ///
  /// Simple contexts are optimized for comparison and hashing, and are common
  /// in grammars that don't use advanced semantic features.
  final bool isSimple;

  /// The Graph-Shared Stack (GSS) node representing the call hierarchy.
  final CallerKey caller;

  /// The stack of lookahead predicates currently being evaluated.
  ///
  /// This ensures that nested predicates are tracked correctly and that
  /// predicates can access the context of the outer rules.
  final GlushList<PredicateCallerKey> predicateStack;

  /// The stack of open labels in the current branch.
  /// The position in the input where the current rule call was initiated.
  final int callStart;

  /// The current input position of this specific parse path.
  ///
  /// This is distinct from the global parser position because different paths
  /// or lookahead predicates may be at different points in the input stream.
  final int position;

  /// The minimum precedence level allowed for continuing this path.
  final int? minPrecedenceLevel;

  /// The precedence level of the rule currently being matched.
  final int? precedenceLevel;

  /// Creates a copy of this context with the specified fields updated.
  Context copyWith({
    CallerKey? caller,
    GlushList<PredicateCallerKey>? predicateStack,
    int? callStart,
    int? position,
    int? minPrecedenceLevel,
    int? precedenceLevel,
  }) {
    return Context(
      caller ?? this.caller,
      predicateStack: predicateStack ?? this.predicateStack,
      callStart: callStart ?? this.callStart,
      position: position ?? this.position,
      minPrecedenceLevel: minPrecedenceLevel ?? this.minPrecedenceLevel,
      precedenceLevel: precedenceLevel ?? this.precedenceLevel,
    );
  }

  /// Returns a new context advanced to [newPosition].
  ///
  /// This is a fast-path optimization that avoids full re-hashing when
  /// only the position changes.
  Context advancePosition(int newPosition) {
    if (newPosition == position) {
      return this;
    }
    return Context(
      caller,
      predicateStack: predicateStack,
      callStart: callStart,
      position: newPosition,
      minPrecedenceLevel: minPrecedenceLevel,
      precedenceLevel: precedenceLevel,
    );
  }

  /// Returns a new context with a new [nextCaller].
  Context withCaller(CallerKey nextCaller) {
    if (identical(nextCaller, caller)) {
      return this;
    }
    return Context(
      nextCaller,
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
          predicateStack == other.predicateStack;

  @override
  int get hashCode => _hash;
}

/// A grouping of frames that have arrived at the same [state] and [context].
///
/// In an ambiguous parse, multiple derivation paths may lead to the same
/// state/context combination. [ContextGroup] allows the parser to merge these
/// paths, aggregating their marks and derivations into a single branched
/// forest node. This is critical for preventing exponential explosion in
/// highly ambiguous grammars.
final class ContextGroup {
  /// Creates a [ContextGroup] for a specific [state] and [context].
  ContextGroup(this.state, this.context);

  /// The state machine state that all frames in this group share.
  final State state;

  /// The common parsing context for this group.
  final Context context;

  LazyGlushList<Mark>? _single;
  List<LazyGlushList<Mark>>? _batch;

  /// Returns the merged mark list for all paths that joined this group.
  ///
  /// This generates a branched lazy list if multiple paths contributed marks.
  LazyGlushList<Mark> get mergedMarks {
    if (_batch case var batch?) {
      return _buildBalanced(batch, 0, batch.length);
    }
    return _single ?? const LazyGlushList<Mark>.empty();
  }

  /// Adds a new set of [marks] to this group's derivation paths.
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
