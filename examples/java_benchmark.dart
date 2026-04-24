import "dart:io";

import "package:glush/glush.dart";

void main() async {
  print("=== JAVA INCREMENTAL BENCHMARK ===");
  GlushProfiler.enabled = true;

  // 1. Load Grammar
  var grammarFile = File("examples/java.glush").readAsStringSync();
  var grammar = grammarFile.toGrammar();
  var parser = SMParser(grammar);
  var evaluator = const StructuredEvaluator();

  // 2. Prepare Large Java Source
  const baseClass = r'''
package com.example;
import java.util.*;

public class LargeClass {
  private int counter = 0;
  
  public void method0() {
    System.out.println("Hello from method 0");
    if (true) {
      counter++;
    }
  }
}
''';

  // Duplicate members to make it large
  var buffer = StringBuffer();
  buffer.write(baseClass.substring(0, baseClass.lastIndexOf("}")));
  for (var i = 1; i <= 5; i++) {
    buffer.write('''
  public void method$i() {
    int x = $i * 2;
    if (x > 100) {
      System.out.println("Large value: " + x);
    } else {
      System.out.println("Small value");
    }
  }
''');
  }
  buffer.write("}");
  var largeSource = buffer.toString();

  print("Source length: ${largeSource.length} characters");

  var results = <Map<String, dynamic>>[];

  // 3. Initial Parse
  print("Initial parse...");
  var sw = Stopwatch()..start();
  var parseState = parser.createParseState();
  parseState.positionManager = FingerTree.leaf(largeSource);

  while (parseState.position < parseState.positionManager.charLength) {
    parseState.processNextToken();
  }
  var finalStep = parseState.finish();

  var initialResult = parseState.forest;
  var accepted = finalStep.acceptedContexts.isNotEmpty;
  print("Initial parse accepted: $accepted");
  if (!accepted) {
    print("WARNING: Initial parse failed! Check grammar.");
  }
  evaluator.evaluate(initialResult!, input: largeSource);

  sw.stop();
  var initialTime = sw.elapsedMicroseconds;
  results.add({
    "name": "Initial Parse",
    "time": initialTime,
    "status": accepted ? "Accepted" : "Failed"
  });

  // 4. Edits Benchmark
  var editConfigs = [
    (
      "Insert header",
      largeSource.indexOf("public class"),
      largeSource.indexOf("public class"),
      "/* Added header */\n",
    ),
    (
      "Rename method",
      largeSource.indexOf("method250"),
      largeSource.indexOf("method250") + 9,
      "methodChanged",
    ),
    (
      "Delete last method",
      largeSource.lastIndexOf("public void"),
      largeSource.lastIndexOf("}") + 1,
      "",
    ),
    ("Append comment", largeSource.length, largeSource.length, "\n// End of file comment"),
    ("Change operator", largeSource.indexOf("x > 100"), largeSource.indexOf("x > 100") + 1, "<"),
    (
      "Unclosed Quote",
      largeSource.indexOf('"Hello from method 0"') + 20,
      largeSource.indexOf('"Hello from method 0"') + 21,
      "",
    ),
    (
      "Top-Level Wrap",
      0,
      0,
      "{",
    ),
    (
      "Paste-Bomb",
      largeSource.length ~/ 2,
      largeSource.length ~/ 2,
      " " * 10000,
    ),
  ];

  for (var i = 0; i < editConfigs.length; i++) {
    var config = editConfigs[i];

    // 1. Initial Parse (Baseline for this edit)
    var state = parser.createParseState();
    state.positionManager = FingerTree.leaf(largeSource);
    while (state.position < state.positionManager.charLength) {
      state.processNextToken();
    }
    state.finish();

    var editSw = Stopwatch()..start();

    // 2. Apply edit to the baseline
    state.applyEdit(config.$2, config.$3, config.$4);

    // 3. Incremental re-parse
    while (state.position < state.positionManager.charLength) {
      var step = state.processNextToken();
      if (step == null) break;
    }
    state.finish();

    // 4. Evaluate
    var forest = state.forest;
    var parseStatus = "Failed";
    if (forest != null && !forest.isEmpty) {
      try {
        evaluator.evaluate(forest, input: state.positionManager.toString());
        parseStatus = "Accepted";
      } catch (e) {
        parseStatus = "Evaluation Error: $e";
      }
    }

    editSw.stop();
    results.add({
      "name": config.$1,
      "time": editSw.elapsedMicroseconds,
      "status": parseStatus,
    });
  }

  // 5. Report
  print("\n=== RESULTS ===");
  print('${'Task'.padRight(25)} | ${'Time (µs)'.padLeft(12)} | ${'Speedup'.padLeft(10)} | ${'Status'}');
  print("-" * 65);
  for (var res in results) {
    var speedup = initialTime / (res["time"] as num);
    var status = res["status"] ?? "Unknown";
    print(
      '${res['name'].toString().padRight(25)} | ${res['time'].toString().padLeft(12)} | ${speedup.toStringAsFixed(2).padLeft(10)}x | $status',
    );
  }

  print("\n=== PROFILER REPORT ===");
  print(GlushProfiler.snapshot().report());
}
