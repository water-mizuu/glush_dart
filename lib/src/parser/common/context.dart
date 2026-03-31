/// Core parser utilities and data structures for the Glush Dart parser.
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/common/caller_key.dart";
import "package:glush/src/parser/common/derivation_key.dart";
import "package:glush/src/parser/common/label_capture.dart";
import "package:glush/src/parser/state_machine.dart";
import "package:meta/meta.dart";

/// Represents a unique parsing configuration at a specific input position.
///
/// A [Context] tracks the state of the "virtual parser" including:
/// - The caller stack (represented as a link to a GSS [Caller])
/// - The marks (result forest) accumulated so far in this path
/// - Active lookahead predicates (the [predicateStack])
/// - Dynamic label captures (the [captures] map)
@immutable
class Context {
  const Context(
    this.caller,
    this.marks, {
    Map<String, Object?>? arguments,
    this.captures = const CaptureBindings.empty(),
    this.derivationPath = const GlushList<DerivationKey>.empty(),
    this.predicateStack = const GlushList<PredicateCallerKey>.empty(),
    this.bsrRuleSymbol,
    this.callStart,
    this.pivot,
    this.minPrecedenceLevel,
    this.precedenceLevel,
  }) : _arguments = arguments;

  /// The Graph-Shared Stack (GSS) node representing the current call hierarchy.
  final CallerKey caller;

  /// The accumulated results for this parse path.
  final GlushList<Mark> marks;

  /// The arguments passed to the current rule call.
  final Map<String, Object?>? _arguments;

  /// Returns the resolved arguments for this context, falling back to the caller's arguments.
  Map<String, Object?> get arguments =>
      _arguments ??
      switch (caller) {
        Caller(:var arguments) => arguments,
        _ => const <String, Object?>{},
      };

  /// Bindings for data captured via structural labels (name:pattern).
  final CaptureBindings captures;

  /// The structural history of this parse path, used to recover ambiguous derivations.
  final GlushList<DerivationKey> derivationPath;

  /// The stack of active lookahead predicates currently being evaluated.
  final GlushList<PredicateCallerKey> predicateStack;

  /// The symbol we are currently building a BSR/SPPF forest for.
  final PatternSymbol? bsrRuleSymbol;

  /// The position in the input where the current rule call began.
  final int? callStart;

  /// The input position of the last successful rule completion (for BSR/SPPF).
  final int? pivot;

  /// The current minimum precedence level allowed for rule expansion.
  final int? minPrecedenceLevel;

  /// The precedence level of the rule currently being parsed.
  final int? precedenceLevel;

  /// Creates a copy of this context with the given fields replaced.
  Context copyWith({
    CallerKey? caller,
    GlushList<Mark>? marks,
    Map<String, Object?>? arguments,
    CaptureBindings? captures,
    GlushList<DerivationKey>? derivationPath,
    GlushList<PredicateCallerKey>? predicateStack,
    PatternSymbol? bsrRuleSymbol,
    int? callStart,
    int? pivot,
    int? minPrecedenceLevel,
    int? precedenceLevel,
  }) {
    var nextCaller = caller ?? this.caller;
    var nextArguments =
        arguments ?? (identical(nextCaller, this.caller) ? _arguments : this.arguments);
    return Context(
      nextCaller,
      marks ?? this.marks,
      arguments: nextArguments,
      captures: captures ?? this.captures,
      derivationPath: derivationPath ?? this.derivationPath,
      predicateStack: predicateStack ?? this.predicateStack,
      bsrRuleSymbol: bsrRuleSymbol ?? this.bsrRuleSymbol,
      callStart: callStart ?? this.callStart,
      pivot: pivot ?? this.pivot,
      minPrecedenceLevel: minPrecedenceLevel ?? this.minPrecedenceLevel,
      precedenceLevel: precedenceLevel ?? this.precedenceLevel,
    );
  }

  /// Returns a new context with the given marks, avoiding allocation if they are identical.
  Context withMarks(GlushList<Mark> nextMarks) {
    if (identical(nextMarks, marks)) {
      return this;
    }
    return Context(
      caller,
      nextMarks,
      arguments: _arguments,
      captures: captures,
      derivationPath: derivationPath,
      predicateStack: predicateStack,
      bsrRuleSymbol: bsrRuleSymbol,
      callStart: callStart,
      pivot: pivot,
      minPrecedenceLevel: minPrecedenceLevel,
      precedenceLevel: precedenceLevel,
    );
  }

  /// Returns a new context with a different caller, updating arguments as needed.
  Context withCaller(CallerKey nextCaller) {
    if (identical(nextCaller, caller)) {
      return this;
    }
    return Context(
      nextCaller,
      marks,
      arguments: identical(nextCaller, caller) ? _arguments : arguments,
      captures: captures,
      derivationPath: derivationPath,
      predicateStack: predicateStack,
      bsrRuleSymbol: bsrRuleSymbol,
      callStart: callStart,
      pivot: pivot,
      minPrecedenceLevel: minPrecedenceLevel,
      precedenceLevel: precedenceLevel,
    );
  }

  /// Returns a new context with a different caller and marks, optimizing for identity.
  Context withCallerAndMarks(CallerKey nextCaller, GlushList<Mark> nextMarks) {
    if (identical(nextCaller, caller) && identical(nextMarks, marks)) {
      return this;
    }

    return Context(
      nextCaller,
      nextMarks,
      arguments: identical(nextCaller, caller) ? _arguments : arguments,
      captures: captures,
      derivationPath: derivationPath,
      predicateStack: predicateStack,
      bsrRuleSymbol: bsrRuleSymbol,
      callStart: callStart,
      pivot: pivot,
      minPrecedenceLevel: minPrecedenceLevel,
      precedenceLevel: precedenceLevel,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Context &&
          caller == other.caller &&
          marks == other.marks &&
          arguments == other.arguments &&
          captures == other.captures &&
          predicateStack == other.predicateStack &&
          callStart == other.callStart &&
          pivot == other.pivot &&
          minPrecedenceLevel == other.minPrecedenceLevel &&
          precedenceLevel == other.precedenceLevel;

  @override
  int get hashCode => Object.hash(
    caller,
    marks,
    // arguments,
    // captures,
    // predicateStack,
    // callStart,
    // pivot,
    // minPrecedenceLevel,
    // precedenceLevel,
  );
}

/// Helper for grouping context-equivalent frames during token transitions.
///
/// When multiple frames advance to the same state/caller/position, they are
/// grouped into a single [ContextGroup] so that their marks and derivations
/// can be merged into a single branched node.
final class ContextGroup {
  ContextGroup({
    required this.state,
    required this.caller,
    required this.minPrecedenceLevel,
    required this.predicateStack,
    required this.captures,
  });

  final State state;
  final CallerKey caller;
  final int? minPrecedenceLevel;
  final GlushList<PredicateCallerKey> predicateStack;
  final CaptureBindings captures;
  final List<GlushList<Mark>> marks = [];
  final List<GlushList<DerivationKey>> derivationPaths = [];
}
