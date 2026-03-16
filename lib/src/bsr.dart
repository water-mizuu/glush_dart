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
final class BsrEntry {
  final Rule rule;
  final int leftExtent;
  final int rightExtent;

  const BsrEntry(this.rule, this.leftExtent, this.rightExtent);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BsrEntry &&
          rule == other.rule &&
          leftExtent == other.leftExtent &&
          rightExtent == other.rightExtent;

  @override
  int get hashCode => rule.hashCode ^ leftExtent.hashCode ^ rightExtent.hashCode;

  @override
  String toString() => 'BSR(${rule.name}, $leftExtent:$rightExtent)';
}

/// The set of all [BsrEntry] instances accumulated during a parse.
///
/// Can be queried to check which rules were proven to match which spans,
/// and can construct an SPPF on demand restricted to proven spans.
class BsrSet {
  final Set<BsrEntry> _entries = {};

  /// Add a rule-completion entry.
  void add(Rule rule, int leftExtent, int rightExtent) {
    final entry = BsrEntry(rule, leftExtent, rightExtent);
    _entries.add(entry);
  }

  /// Check if a rule was completed over [leftExtent, rightExtent).
  bool contains(Rule rule, int leftExtent, int rightExtent) {
    return _entries.contains(BsrEntry(rule, leftExtent, rightExtent));
  }

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
  ParseForest toForest(Rule startRule, String input, [List<Mark>? marks]) {
    final nodeManager = ForestNodeManager();
    final memoNodes = <_BsrTask, SymbolicNode?>{};
    final memoGroups = <_BsrTask, List<List<ForestNode>>>{};
    final taskStates = <_BsrTask, int>{}; // 0 = New, 1 = Pushed, 2 = Done
    final stack = <_BsrTask>[];

    final startTask = _BsrTask(0, startRule, 0, input.length);
    stack.add(startTask);

    while (stack.isNotEmpty) {
      final task = stack.last;
      final state = taskStates[task] ?? 0;

      if (state == 1) {
        // Second visit: children are processed, collect results
        if (task.type == 0) {
          final symNode = nodeManager.symbolic(task.start, task.end, task.rule!);
          final groups = memoGroups[_BsrTask(1, task.rule!.body(), task.start, task.end)];
          if (groups != null) {
            for (final children in groups) {
              symNode.addFamily(Family(children));
            }
          }
          memoNodes[task] = symNode.families.isNotEmpty ? symNode : null;
        } else {
          final p = task.pattern!;
          final result = <List<ForestNode>>[];
          if (p is Alt) {
            result.addAll(memoGroups[_BsrTask(1, p.left, task.start, task.end)] ?? []);
            result.addAll(memoGroups[_BsrTask(1, p.right, task.start, task.end)] ?? []);
            memoGroups[task] = result;
          } else if (p is Seq) {
            if (task.start == 0 && task.end == input.length) {
              print('DEBUG: Tracing Seq split for 0:${input.length}');
            }
            for (int mid = task.start; mid <= task.end; mid++) {
              final lefts = memoGroups[_BsrTask(1, p.left, task.start, mid)];
              final rights = memoGroups[_BsrTask(1, p.right, mid, task.end)];
              
              if (task.start == 0 && task.end == input.length && mid == 2) {
                 print('DEBUG: Mid 2 lefts: ${lefts?.length}, rights: ${rights?.length}');
              }

              if (lefts != null && rights != null) {
                for (final l in lefts) {
                  for (final r in rights) {
                    final node = nodeManager.intermediate(task.start, task.end, p, 'Seq');
                    node.addFamily(Family([...l, ...r]));
                    result.add([node]);
                  }
                }
              }
            }
            memoGroups[task] = result;
          } else if (p is Call || p is RuleCall) {
            final rule = (p as dynamic).rule as Rule;
            final child = memoNodes[_BsrTask(0, rule, task.start, task.end)];
            if (child != null) {
              result.add([child]);
            }
            memoGroups[task] = result;
          } else if (p is Action) {
            final groups = memoGroups[_BsrTask(1, p.child, task.start, task.end)];
            if (groups != null) {
              for (final children in groups) {
                final intermediateNode = nodeManager.intermediate(task.start, task.end, p, 'Action');
                intermediateNode.addFamily(Family(children));
                result.add([intermediateNode]);
              }
            }
            memoGroups[task] = result;
          } else if (p is Plus) {
            for (int mid = task.start + 1; mid <= task.end; mid++) {
              final heads = memoGroups[_BsrTask(1, p.child, task.start, mid)];
              final tails = memoGroups[_BsrTask(1, p, mid, task.end)];
              if (heads != null && tails != null) {
                for (final h in heads) {
                  for (final t in tails) {
                    final node = nodeManager.intermediate(task.start, task.end, p, 'Plus');
                    node.addFamily(Family([...h, ...t]));
                    result.add([node]);
                  }
                }
              }
            }
            final singles = memoGroups[_BsrTask(1, p.child, task.start, task.end)];
            if (singles != null) {
              for (final s in singles) {
                final node = nodeManager.intermediate(task.start, task.end, p, 'Plus');
                node.addFamily(Family(s));
                result.add([node]);
              }
            }
            memoGroups[task] = result;
          } else if (p is Star) {
            final result = <List<ForestNode>>[];
            for (int mid = task.start + 1; mid <= task.end; mid++) {
              final heads = memoGroups[_BsrTask(1, p.child, task.start, mid)];
              final tails = memoGroups[_BsrTask(1, p, mid, task.end)];
              if (heads != null && tails != null) {
                for (final h in heads) {
                  for (final t in tails) {
                    final node = nodeManager.intermediate(task.start, task.end, p, 'Star');
                    node.addFamily(Family([...h, ...t]));
                    result.add([node]);
                  }
                }
              }
            }
            if (task.start == task.end) {
              final node = nodeManager.intermediate(task.start, task.end, p, 'Star');
              node.addFamily(Family([nodeManager.epsilon(task.start, p)]));
              result.add([node]);
            }
            memoGroups[task] = result;
          } else if (p is PrecedenceLabeledPattern) {
            memoGroups[task] = memoGroups[_BsrTask(1, p.pattern, task.start, task.end)] ?? [];
          }
        }
        taskStates[task] = 2; // Done
        stack.removeLast();
        continue;
      }

      if (state == 2) {
        // Already done
        stack.removeLast();
        continue;
      }

      // First visit: determine match and push children
      taskStates[task] = 1;

      if (task.type == 0) {
        final rule = task.rule!;
        if (!contains(rule, task.start, task.end)) {
          memoNodes[task] = null;
          taskStates[task] = 2;
          stack.removeLast();
          continue;
        }
        stack.add(_BsrTask(1, rule.body(), task.start, task.end));
      } else {
        final p = task.pattern!;
        final start = task.start;
        final end = task.end;

        if (p is Token) {
          if (start + 1 == end && p.match(input.codeUnitAt(start))) {
            memoGroups[task] = [
              [nodeManager.terminal(start, end, p, input.codeUnitAt(start))]
            ];
          } else {
            memoGroups[task] = [];
          }
          taskStates[task] = 2;
          stack.removeLast();
        } else if (p is Eps) {
          memoGroups[task] = start == end ? [[nodeManager.epsilon(start, p)]] : [];
          taskStates[task] = 2;
          stack.removeLast();
        } else if (p is Marker) {
          memoGroups[task] = start == end ? [[nodeManager.marker(start, p)]] : [];
          taskStates[task] = 2;
          stack.removeLast();
        } else if (p is Alt) {
          stack.add(_BsrTask(1, p.left, start, end));
          stack.add(_BsrTask(1, p.right, start, end));
        } else if (p is Seq) {
          for (int mid = start; mid <= end; mid++) {
            stack.add(_BsrTask(1, p.left, start, mid));
            stack.add(_BsrTask(1, p.right, mid, end));
          }
        } else if (p is Call || p is RuleCall) {
          final rule = (p as dynamic).rule as Rule;
          stack.add(_BsrTask(0, rule, start, end));
        } else if (p is Action) {
          stack.add(_BsrTask(1, p.child, start, end));
        } else if (p is Plus) {
          for (int mid = start + 1; mid <= end; mid++) {
            stack.add(_BsrTask(1, p.child, start, mid));
            stack.add(_BsrTask(1, p, mid, end));
          }
          stack.add(_BsrTask(1, p.child, start, end));
        } else if (p is Star) {
          for (int mid = start + 1; mid <= end; mid++) {
            stack.add(_BsrTask(1, p.child, start, mid));
            stack.add(_BsrTask(1, p, mid, end));
          }
        } else if (p is Conj) {
          if (start + 1 == end &&
              p.left.match(input.codeUnitAt(start)) &&
              p.right.match(input.codeUnitAt(start))) {
            memoGroups[task] = [
              [nodeManager.terminal(start, end, p, input.codeUnitAt(start))]
            ];
          } else {
            memoGroups[task] = [];
          }
          taskStates[task] = 2;
          stack.removeLast();
        } else if (p is And || p is Not) {
          memoGroups[task] = start == end ? [[nodeManager.epsilon(start, p)]] : [];
          taskStates[task] = 2;
          stack.removeLast();
        } else if (p is PrecedenceLabeledPattern) {
          stack.add(_BsrTask(1, p.pattern, start, end));
        } else {
          memoGroups[task] = [];
          taskStates[task] = 2;
          stack.removeLast();
        }
      }
    }

    final root = memoNodes[startTask];
    if (root == null) {
      print('DEBUG: Trace failure for ${startRule.name}:0:${input.length}');
      final bodyTask = _BsrTask(1, startRule.body(), 0, input.length);
      final bodyGroups = memoGroups[bodyTask];
      print('DEBUG: Body ${startRule.body().runtimeType} for 0:${input.length} groups: ${bodyGroups?.length}');

      if (bodyGroups == null || bodyGroups.isEmpty) {
         final body = startRule.body();
         if (body is Alt) {
            final lGroups = memoGroups[_BsrTask(1, body.left, 0, input.length)];
            final rGroups = memoGroups[_BsrTask(1, body.right, 0, input.length)];
            print('DEBUG: Alt left groups: ${lGroups?.length}, right groups: ${rGroups?.length}');
         }
      }
      throw StateError("Failed to reconstruct forest root for ${startRule.name}");
    }
    return ParseForest(nodeManager, root, marks ?? []);
  }

  @override
  String toString() => 'BsrSet(${_entries.length} entries)';
}

class _BsrTask {
  final int type; // 0 = Rule, 1 = Pattern
  final Rule? rule;
  final Pattern? pattern;
  final int start;
  final int end;

  _BsrTask(this.type, dynamic target, this.start, this.end)
      : rule = target is Rule ? target : null,
        pattern = target is Pattern ? target : null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _BsrTask &&
          type == other.type &&
          rule == other.rule &&
          pattern == other.pattern &&
          start == other.start &&
          end == other.end;

  @override
  int get hashCode => Object.hash(type, rule, pattern, start, end);

  @override
  String toString() => type == 0 ? '${rule!.name}:$start:$end' : 'p:${pattern.hashCode}:$start:$end';
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
