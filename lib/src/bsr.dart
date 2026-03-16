/// Binarised Shared Representation (BSR) for compact derivation recording.
///
/// A BSR set is populated *during* parsing. Each entry records that a rule
/// was successfully completed over a specific input span.  The SPPF can then
/// be derived on-demand from these entries rather than from an exhaustive
/// grammar walk.
///
/// Reference: Scott & Johnstone, "GLL Parse-Tree Generation" (2013).
library glush.bsr;

import 'package:glush/src/mark.dart';

import 'patterns.dart';
import 'sppf.dart';

/// A single rule-completion entry in the BSR.
///
/// Records that [rule] was successfully parsed over the input span
/// [[leftExtent], [rightExtent]).
typedef BsrEntry = (Rule rule, int leftExtent, int rightExtent);

extension BsrEntryMethods on BsrEntry {
  Rule get rule => $1;
  int get leftExtent => $2;
  int get rightExtent => $3;
}

/// The set of all [BsrEntry] instances accumulated during a parse.
///
/// Can be queried to check which rules were proven to match which spans,
/// and can construct an SPPF on demand restricted to proven spans.
class BsrSet {
  final Set<BsrEntry> _entries = {};

  /// Add a rule-completion entry.
  void add(Rule rule, int leftExtent, int rightExtent) {
    _entries.add((rule, leftExtent, rightExtent));
  }

  /// Returns true if [rule] was proven to match [[left], [right]).
  bool contains(Rule rule, int left, int right) => _entries.contains((rule, left, right));

  /// Returns all entries for the given rule.
  Iterable<BsrEntry> entriesForRule(Rule rule) => _entries.where((e) => e.rule == rule);

  /// Returns all entries matching a given span (any rule).
  Iterable<BsrEntry> entriesForSpan(int left, int right) =>
      _entries.where((e) => e.leftExtent == left && e.rightExtent == right);

  /// Total number of recorded rule-completion entries.
  int get length => _entries.length;

  /// Build an SPPF rooted at [startRule] over the full input of length
  /// [inputLength], using only spans that are proven in this BSR set.
  ///
  /// Returns null if the start rule has no proven entry for [0, inputLength].
  SymbolicNode? buildSppf(
    Rule startRule,
    String input,
    ForestNodeManager nodeManager,
  ) {
    final memo = <String, SymbolicNode?>{};
    final inProgress = <String, bool>{};
    return _buildNode(startRule, input, 0, input.length, nodeManager, memo, inProgress);
  }

  // ---------------------------------------------------------------------------
  // Internal SPPF construction (BSR-guided grammar walk)
  // ---------------------------------------------------------------------------

  SymbolicNode? _buildNode(
    Rule rule,
    String input,
    int start,
    int end,
    ForestNodeManager nodeManager,
    Map<String, SymbolicNode?> memo,
    Map<String, bool> inProgress,
  ) {
    // Fast-fail: only build SPPF for spans the BSR proves are reachable.
    if (!contains(rule, start, end)) return null;

    final key = '${rule.name}:$start:$end';
    if (memo.containsKey(key)) return memo[key];
    if (inProgress[key] == true) return null;

    inProgress[key] = true;
    final symNode = nodeManager.symbolic(start, end, rule);

    final childGroups =
        _patternChildGroups(rule.body(), input, start, end, nodeManager, memo, inProgress);
    for (final children in childGroups) {
      symNode.addFamily(Family(children));
    }

    inProgress[key] = false;
    final result = symNode.families.isNotEmpty ? symNode : null;
    memo[key] = result;
    return result;
  }

  List<List<ForestNode>> _patternChildGroups(
    Pattern pattern,
    String input,
    int start,
    int end,
    ForestNodeManager nodeManager,
    Map<String, SymbolicNode?> memo,
    Map<String, bool> inProgress,
  ) {
    if (pattern is Token) {
      if (start + 1 == end && pattern.match(input.codeUnitAt(start))) {
        return [
          [nodeManager.terminal(start, end, pattern, input.codeUnitAt(start))]
        ];
      }
      return [];
    }

    if (pattern is Eps) {
      return start == end
          ? [
              [nodeManager.epsilon(start, pattern)]
            ]
          : [];
    }

    if (pattern is Marker) {
      if (start == end) {
        return [
          [nodeManager.marker(start, pattern)]
        ];
      }
      return [];
    }

    if (pattern is Alt) {
      final left =
          _patternChildGroups(pattern.left, input, start, end, nodeManager, memo, inProgress);
      final right =
          _patternChildGroups(pattern.right, input, start, end, nodeManager, memo, inProgress);
      return [...left, ...right];
    }

    if (pattern is Seq) {
      final result = <List<ForestNode>>[];
      for (int mid = start; mid <= end; mid++) {
        final leftGroups =
            _patternChildGroups(pattern.left, input, start, mid, nodeManager, memo, inProgress);
        if (leftGroups.isEmpty) continue;

        final rightGroups =
            _patternChildGroups(pattern.right, input, mid, end, nodeManager, memo, inProgress);
        if (rightGroups.isEmpty) continue;

        for (final l in leftGroups) {
          for (final r in rightGroups) {
            final node = nodeManager.intermediate(start, end, pattern, 'Seq');
            node.addFamily(Family([...l, ...r]));
            result.add([node]);
          }
        }
      }
      return result;
    }

    if (pattern is Call) {
      final child = _buildNode(pattern.rule, input, start, end, nodeManager, memo, inProgress);
      return child != null
          ? [
              [child]
            ]
          : [];
    }

    if (pattern is RuleCall) {
      final child = _buildNode(pattern.rule, input, start, end, nodeManager, memo, inProgress);
      return child != null
          ? [
              [child]
            ]
          : [];
    }

    if (pattern is Action) {
      final childGroups =
          _patternChildGroups(pattern.child, input, start, end, nodeManager, memo, inProgress);
      return childGroups.map((children) {
        final node = nodeManager.intermediate(start, end, pattern, 'Action<T>');
        node.addFamily(Family(children));
        return [node];
      }).toList();
    }

    if (pattern is Plus) {
      final result = <List<ForestNode>>[];
      for (int mid = start + 1; mid <= end; mid++) {
        final headGroups =
            _patternChildGroups(pattern.child, input, start, mid, nodeManager, memo, inProgress);
        if (headGroups.isEmpty) continue;

        final tailGroups =
            _patternChildGroups(pattern, input, mid, end, nodeManager, memo, inProgress);
        if (tailGroups.isEmpty) continue;

        for (final h in headGroups) {
          for (final t in tailGroups) {
            final node = nodeManager.intermediate(start, end, pattern, 'Plus');
            node.addFamily(Family([...h, ...t]));
            result.add([node]);
          }
        }
      }
      final singleGroups =
          _patternChildGroups(pattern.child, input, start, end, nodeManager, memo, inProgress);
      for (final s in singleGroups) {
        final node = nodeManager.intermediate(start, end, pattern, 'Plus');
        node.addFamily(Family(s));
        result.add([node]);
      }

      return result;
    }

    if (pattern is Star) {
      final result = <List<ForestNode>>[];
      for (int mid = start + 1; mid <= end; mid++) {
        final headGroups =
            _patternChildGroups(pattern.child, input, start, mid, nodeManager, memo, inProgress);
        if (headGroups.isEmpty) continue;

        final tailGroups =
            _patternChildGroups(pattern, input, mid, end, nodeManager, memo, inProgress);
        if (tailGroups.isEmpty) continue;

        for (final h in headGroups) {
          for (final t in tailGroups) {
            final node = nodeManager.intermediate(start, end, pattern, 'Star');
            node.addFamily(Family([...h, ...t]));
            result.add([node]);
          }
        }
      }
      if (start == end) {
        final node = nodeManager.intermediate(start, end, pattern, 'Star');
        node.addFamily(Family([nodeManager.epsilon(start, pattern)]));
        result.add([node]);
      }

      return result;
    }

    if (pattern is Conj) {
      if (start + 1 == end &&
          pattern.left.match(input.codeUnitAt(start)) &&
          pattern.right.match(input.codeUnitAt(start))) {
        final termNode = nodeManager.terminal(start, end, pattern, input.codeUnitAt(start));
        return [
          [termNode]
        ];
      }
      return [];
    }

    if (pattern is And || pattern is Not) {
      if (start == end) {
        return [
          [nodeManager.epsilon(start, pattern)]
        ];
      }
      return [];
    }

    if (pattern is PrecedenceLabeledPattern) {
      return _patternChildGroups(pattern.pattern, input, start, end, nodeManager, memo, inProgress);
    }

    return [];
  }

  @override
  String toString() => 'BsrSet(${_entries.length} entries)';
}

// ---------------------------------------------------------------------------
// Parse outcome types for BSR-based parsing
// ---------------------------------------------------------------------------

/// Sealed result type for [SMParser.parseToBsr].
sealed class BsrParseOutcome {}

/// Returned when BSR parsing fails.
final class BsrParseError implements BsrParseOutcome, Exception {
  final int position;

  const BsrParseError(this.position);

  @override
  String toString() => 'BsrParseError at position $position';
}

/// Returned when BSR parsing succeeds. Contains the [BsrSet] of proven spans.
final class BsrParseSuccess implements BsrParseOutcome {
  final BsrSet bsrSet;
  final List<Mark> marks;

  const BsrParseSuccess(this.bsrSet, this.marks);

  @override
  String toString() => 'BsrParseSuccess($bsrSet)';
}
