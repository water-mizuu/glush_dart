import "dart:math" as math;

/// Represents a set of integer values as one unit range or a union of unit ranges.
///
/// A unit range uses half-open semantics: `[start, end)` includes `start` and
/// excludes `end`.
sealed class IntegerRange {
  /// Creates a range containing exactly one integer [value].
  const factory IntegerRange.single(int value) = SingleRange;

  /// Creates a half-open unit range `[start, end)`.
  const factory IntegerRange.unit(int start, int end) = UnitRange;

  /// Creates a union of unit ranges.
  const factory IntegerRange.union(List<UnitRange> ranges) = UnionRange;

  /// The empty range (contains no values).
  static const IntegerRange empty = UnionRange([]);

  /// Deserializes an [IntegerRange] from a JSON-like map.
  ///
  /// Supported payloads:
  /// - `{"type": "unit", "start": int, "end": int}`
  /// - `{"type": "union", "ranges": List<Map<String, Object?>>}`
  ///
  /// Throws [FormatException] when the payload shape or types are invalid.
  static IntegerRange fromJson(Map<String, Object?> value) {
    var type = value["type"];
    if (type == "unit") {
      var start = value["start"];
      var end = value["end"];
      if (start is! int || end is! int) {
        throw FormatException("Invalid unit range payload: $value");
      }
      return IntegerRange.unit(start, end);
    }

    if (type == "union") {
      var ranges = value["ranges"];
      if (ranges is! List) {
        throw FormatException("Invalid union range payload: $value");
      }

      var units = <UnitRange>[];
      for (var item in ranges) {
        if (item is! Map<String, Object?>) {
          throw FormatException("Invalid unit range payload: $item");
        }

        var parsed = IntegerRange.fromJson(item);
        if (parsed is UnitRange) {
          units.add(parsed);
        } else if (parsed is UnionRange) {
          units.addAll(parsed.units);
        }
      }

      return IntegerRange.union(units);
    }

    throw FormatException("Unknown IntegerRange type: $type");
  }

  /// The total number of integers represented by this range.
  int get length;

  /// Whether this range contains no values.
  bool get isEmpty;

  /// Whether this range contains at least one value.
  bool get isNotEmpty;

  /// Returns a canonical set of all contained integers.
  ///
  /// This is useful for testing and exact set comparison, but may be expensive
  /// for very large ranges.
  Set<int> get canonical;

  /// Iterates this range as unit ranges.
  ///
  /// For [UnitRange], this yields itself once. For [UnionRange], this yields
  /// each contained unit.
  Iterable<UnitRange> get units;

  /// Returns whether [value] is inside this range.
  bool contains(num value);

  /// Returns whether this range touches [other] at a boundary without overlap.
  bool touchesWith(IntegerRange other);

  /// Returns whether this range has any overlapping values with [other].
  bool intersectsWith(IntegerRange other);

  /// Returns whether this range fully covers all values of [other].
  bool covers(IntegerRange other);

  /// Returns the set union of this range and [other].
  IntegerRange union(IntegerRange other);

  /// Returns the set intersection of this range and [other].
  IntegerRange intersect(IntegerRange other);

  /// Returns the set difference `this - other`.
  IntegerRange difference(IntegerRange other);

  /// Serializes this range into a JSON-like map.
  Map<String, Object?> toJson();
}

final class SingleRange extends UnitRange {
  const SingleRange(int value) : super(value, value + 1);
}

final class UnitRange implements IntegerRange {
  const UnitRange(this.start, this.end);

  final int start;
  final int end;

  @override
  bool contains(num value) => start <= value && value < end;

  @override
  int get length => end - start;

  @override
  bool get isEmpty => length <= 0;

  @override
  bool get isNotEmpty => length > 0;

  @override
  Set<int> get canonical => {for (int i = start; i < end; i++) i};

  @override
  Iterable<UnitRange> get units sync* {
    yield this;
  }

  @override
  bool touchesWith(IntegerRange other) => switch (other) {
    UnitRange other => end == other.start || start == other.end,
    UnionRange other => other.units.any(touchesWith),
  };

  @override
  bool intersectsWith(IntegerRange other) => switch (other) {
    UnitRange other => !(end < other.start || start >= other.end),
    UnionRange other => other.units.any(intersectsWith),
  };

  @override
  bool covers(IntegerRange other) => switch (other) {
    UnitRange other => other.isEmpty || start <= other.start && end >= other.end,
    UnionRange other => covers(other.cell),
  };

  @override
  IntegerRange union(IntegerRange other) => switch (other) {
    UnitRange other => switch (null) {
      _ when covers(other) => this,
      _ when other.covers(this) => other,
      _ when intersectsWith(other) || touchesWith(other) => IntegerRange.unit(
        math.min(start, other.start),
        math.max(end, other.end),
      ),
      _ => UnionRange([if (isNotEmpty) this, if (other.isNotEmpty) other]),
    },
    UnionRange other =>
      other
          .units //
          .fold(this, (result, current) => current.isEmpty ? result : result.union(current)),
  };

  @override
  IntegerRange intersect(IntegerRange other) => switch (other) {
    UnitRange other => switch (null) {
      _ when intersectsWith(other) => IntegerRange.unit(
        math.max(start, other.start),
        math.min(end, other.end),
      ),
      _ => IntegerRange.empty,
    },
    UnionRange other => other.units.map(intersect).union(),
  };

  @override
  IntegerRange difference(IntegerRange other) => switch (other) {
    UnitRange other => switch (null) {
      _ when intersectsWith(other) => IntegerRange.unit(
        start,
        other.start,
      ).union(IntegerRange.unit(other.end, end)),
      null => this,
    },
    UnionRange other => other.units.fold(this, (result, current) => result.difference(current)),
  };

  @override
  Map<String, Object?> toJson() => {"type": "unit", "start": start, "end": end};

  @override
  String toString() => "[$start, $end)";
}

final class UnionRange implements IntegerRange {
  const UnionRange(this.units);

  @override
  final List<UnitRange> units;

  UnitRange get cell {
    if (units.isEmpty) {
      return const UnitRange(0, 0);
    }

    var UnitRange(start: min, end: max) = units.first;
    for (var UnitRange(:start, :end) in units) {
      min = math.min(start, min);
      max = math.max(end, max);
    }

    return UnitRange(min, max);
  }

  @override
  bool contains(num value) => units.any((unit) => unit.contains(value));

  @override
  int get length => units.map((r) => r.length).fold(0, (a, b) => a + b);

  @override
  bool get isEmpty => length <= 0;

  @override
  bool get isNotEmpty => length > 0;

  @override
  Set<int> get canonical => units.expand((r) => r.canonical).toSet();

  @override
  bool touchesWith(IntegerRange other) => units.any((unit) => unit.touchesWith(other));

  @override
  bool intersectsWith(IntegerRange other) => units.any((unit) => unit.intersectsWith(other));

  @override
  bool covers(IntegerRange other) =>
      units.fold(other, (other, unit) => other.difference(unit)).isEmpty;

  @override
  IntegerRange union(IntegerRange other) => switch (other) {
    UnitRange other =>
      intersectsWith(other) ||
              touchesWith(other) //
          ? units.fold(other, (a, b) => a.union(b))
          : IntegerRange.union([...units, if (other.isNotEmpty) other]),
    UnionRange other => units.followedBy(other.units).union(),
  };

  @override
  IntegerRange intersect(IntegerRange other) =>
      other
          .isEmpty //
      ? IntegerRange.empty
      : units.map((unit) => unit.intersect(other)).union();

  @override
  IntegerRange difference(IntegerRange other) => switch (other) {
    UnitRange other => units.map((unit) => unit.difference(other)).union(),
    UnionRange other => other.units.fold(this, (result, current) => result.difference(current)),
  };

  @override
  Map<String, Object?> toJson() => {
    "type": "union",
    "ranges": [for (var unit in units) unit.toJson()],
  };

  @override
  String toString() => switch ((units.toList()..sort((a, b) => a.start - b.start))
      .map((v) => v.toString())
      .join(" | ")) {
    "" => "∅",
    String v => v,
  };
}

extension RangeExtension on IntegerRange {
  IntegerRange operator &(IntegerRange other) => intersect(other);
  IntegerRange operator |(IntegerRange other) => union(other);
  IntegerRange operator -(IntegerRange other) => difference(other);
}

extension RangeIterableExtension<R extends IntegerRange> on Iterable<IntegerRange> {
  IntegerRange union() => fold(IntegerRange.empty, (a, b) => a.union(b));
}
