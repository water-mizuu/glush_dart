import "package:benchmark_harness/benchmark_harness.dart";
import "package:glush/glush.dart";

/// Stress test using the highly ambiguous Catalan grammar: S -> S S | 'a'
/// The number of parses follows Catalan numbers C_n = (2n)! / ((n+1)!n!)
/// For n=10, there are 4862 distinct parse trees.
class CatalanBenchmark extends BenchmarkBase {
  CatalanBenchmark(super.name, this.mode, this.inputLength);

  final String mode;
  final int inputLength;

  late Grammar grammar;
  late SMParser parser;
  late String input;

  @override
  void setup() {
    grammar = Grammar(() {
      late Rule s;
      s = Rule("S", () => (s() >> s()) | Token.char("a"));
      return s;
    });
    parser = SMParser(grammar);
    input = "a" * inputLength;

    // Warm up the state machine compilation
    parser.recognize("a");
  }

  @override
  void run() {
    switch (mode) {
      case "recognize":
        parser.recognize(input);
      case "parse":
        parser.parse(input);
      case "parseAmbiguous":
        parser.parseAmbiguous(input, captureTokensAsMarks: true);
      default:
        throw ArgumentError("Unknown mode: $mode");
    }
  }

  @override
  void teardown() {
    if (GlushProfiler.enabled) {
      print("\n--- Profile Report: $name ---");
      print(GlushProfiler.snapshot().report());
      GlushProfiler.reset();
    }
  }
}

/// Baseline benchmark using a simple repetition grammar: S -> 'a'+
class RepetitionBenchmark extends BenchmarkBase {
  RepetitionBenchmark(super.name, this.mode, this.inputLength);

  final String mode;
  final int inputLength;

  late Grammar grammar;
  late SMParser parser;
  late String input;

  @override
  void setup() {
    grammar = Grammar(() {
      return Rule("start", () => Token.char("a").plus());
    });
    parser = SMParser(grammar);
    input = "a" * inputLength;
    parser.recognize("a");
  }

  @override
  void run() {
    switch (mode) {
      case "recognize":
        parser.recognize(input);
      case "parse":
        parser.parse(input);
      case "parseAmbiguous":
        parser.parseAmbiguous(input, captureTokensAsMarks: true);
    }
  }
}

void main() {
  const inputSize = 15; // Small size for catalysts as it's O(n^3)
  const repSize = 1000; // Larger size for simple repetition

  print("Starting Glush Parser Benchmarks...\n");

  // 1. Ambiguity Stress (Catalan)
  CatalanBenchmark("Catalan[$inputSize].recognize", "recognize", inputSize).report();
  CatalanBenchmark("Catalan[$inputSize].parse", "parse", inputSize).report();
  CatalanBenchmark("Catalan[$inputSize].parseAmbiguous", "parseAmbiguous", inputSize).report();

  print("\n------------------------------------------------\n");

  // 2. Simple Linear Stress (Repetition)
  RepetitionBenchmark("Repetition[$repSize].recognize", "recognize", repSize).report();
  RepetitionBenchmark("Repetition[$repSize].parse", "parse", repSize).report();
  RepetitionBenchmark("Repetition[$repSize].parseAmbiguous", "parseAmbiguous", repSize).report();

  // Enable profiler for one more run to see stats
  print("\n--- Running with Profiler Enabled ---");
  GlushProfiler.enabled = true;
  var bench = CatalanBenchmark("Catalan[$inputSize].profile", "parseAmbiguous", inputSize);
  bench.setup();
  bench.run();
  bench.teardown();
  GlushProfiler.enabled = false;
}
