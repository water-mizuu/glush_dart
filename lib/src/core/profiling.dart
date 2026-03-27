import "dart:collection";

final class GlushProfileSnapshot {
  const GlushProfileSnapshot({
    required this.counters,
    required this.timingsMicros,
  });

  final Map<String, int> counters;
  final Map<String, int> timingsMicros;

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

final class GlushProfiler {
  GlushProfiler._();

  static bool enabled = false;
  static final Map<String, int> _counters = HashMap<String, int>();
  static final Map<String, int> _timingsMicros = HashMap<String, int>();

  static void reset() {
    _counters.clear();
    _timingsMicros.clear();
  }

  static void increment(String key, [int delta = 1]) {
    if (!enabled) {
      return;
    }
    _counters[key] = (_counters[key] ?? 0) + delta;
  }

  static void addMicros(String key, int micros) {
    if (!enabled) {
      return;
    }
    _timingsMicros[key] = (_timingsMicros[key] ?? 0) + micros;
  }

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

  static GlushProfileSnapshot snapshot() {
    return GlushProfileSnapshot(
      counters: Map<String, int>.unmodifiable(Map<String, int>.from(_counters)),
      timingsMicros: Map<String, int>.unmodifiable(Map<String, int>.from(_timingsMicros)),
    );
  }
}
