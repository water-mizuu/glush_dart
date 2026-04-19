import "dart:collection";

/// A point-in-time snapshot of the internal profiler state.
///
/// [GlushProfileSnapshot] captures the values of all active counters and
/// timers at the moment it is created. It provides a [report] method to
/// generate a human-readable summary of the performance data.
final class GlushProfileSnapshot {
  /// Creates a [GlushProfileSnapshot] with the given [counters] and [timingsMicros].
  const GlushProfileSnapshot({
    required this.counters,
    required this.timingsMicros,
  });

  /// A map of named event counts (e.g., "cache.hit").
  final Map<String, int> counters;

  /// A map of accumulated microseconds for named operations.
  final Map<String, int> timingsMicros;

  /// Generates a formatted string report summarizing the captured metrics.
  ///
  /// The report includes counts, total execution time in milliseconds, and
  /// average execution time in microseconds for each tracked operation.
  String report() {
    var lines = <String>[];
    var keys = <String>{...counters.keys, ...timingsMicros.keys}.toList()..sort();
    for (var key in keys) {
      var count = counters[key];
      var micros = timingsMicros[key];
      if (count != null && micros != null) {
        lines.add(
          "$key: count=$count total_ms=${(micros / 1000).toStringAsFixed(3)} "
          "avg_us=${count == 0 ? 0 : (micros / count).toStringAsFixed(1)}",
        );
      } else if (count != null) {
        lines.add("$key: count=$count");
      } else if (micros != null) {
        lines.add("$key: total_ms=${(micros / 1000).toStringAsFixed(3)}");
      }
    }
    return lines.join("\n");
  }
}

/// A global singleton for collecting performance metrics within Glush.
///
/// [GlushProfiler] allows various parts of the parser and compiler to log
/// event counts and measure execution time without introducing heavy
/// dependencies. Metrics are only collected when [enabled] is set to true.
final class GlushProfiler {
  GlushProfiler._();

  /// Whether the profiler is currently collecting data.
  ///
  /// Set this to true before running an operation you wish to benchmark.
  static bool enabled = false;

  static final Map<String, int> _counters = HashMap<String, int>();
  static final Map<String, int> _timingsMicros = HashMap<String, int>();

  /// Clears all accumulated counters and timings.
  static void reset() {
    _counters.clear();
    _timingsMicros.clear();
  }

  /// Increments a counter for the given [key] by [delta].
  ///
  /// This is used to track the frequency of specific events, such as rule
  /// body evaluations or cache lookups.
  static void increment(String key, [int delta = 1]) {
    if (!enabled) {
      return;
    }
    _counters[key] = (_counters[key] ?? 0) + delta;
  }

  /// Helper to record a cache hit.
  ///
  /// Increments "[key].hit" and "[key].total" counters.
  static void incrementHit(String key) {
    increment("$key.hit");
    increment("$key.total");
  }

  /// Helper to record a cache miss.
  ///
  /// Increments "[key].miss" and "[key].total" counters.
  static void incrementMiss(String key) {
    increment("$key.miss");
    increment("$key.total");
  }

  /// Adds a specific number of microseconds to the timing for [key].
  static void addMicros(String key, int micros) {
    if (!enabled) {
      return;
    }
    _timingsMicros[key] = (_timingsMicros[key] ?? 0) + micros;
  }

  /// Measures the execution time of [action] and logs it under [key].
  ///
  /// This wraps the provided thunk with a [Stopwatch] and records both the
  /// total time and the invocation count.
  static T measure<T>(String key, T Function() action) {
    if (!enabled) {
      return action();
    }
    var watch = Stopwatch()..start();
    try {
      return action();
    } finally {
      watch.stop();
      addMicros(key, watch.elapsedMicroseconds);
      increment("$key.count");
    }
  }

  /// Returns an immutable [GlushProfileSnapshot] of the current metrics.
  static GlushProfileSnapshot snapshot() {
    return GlushProfileSnapshot(
      counters: Map<String, int>.unmodifiable(Map<String, int>.from(_counters)),
      timingsMicros: Map<String, int>.unmodifiable(Map<String, int>.from(_timingsMicros)),
    );
  }
}
