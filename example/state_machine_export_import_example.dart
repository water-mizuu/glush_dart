/// Example demonstrating state machine export and import.
///
/// This example shows how to:
/// 1. Compile a grammar to a state machine
/// 2. Export the fully compiled state machine to JSON
/// 3. Load the exported state machine from JSON
/// 4. Use the imported state machine for parsing without recompilation
///
/// This is useful for:
/// - Production environments where startup performance matters
/// - Distributing pre-compiled grammars without grammar source
/// - Caching compiled state machines for repeated use
library glush.example.state_machine_export_import;

import "dart:convert" show json;

import "package:glush/glush.dart";

void main() async {
  print("=== State Machine Export/Import Example ===\n");

  // Step 1: Define a simple grammar
  print("Step 1: Creating a grammar...");
  const grammarDef = r"""
  Expression = Number ('+' Number)*
  Number = [0-9]
  """;

  var grammar = grammarDef.toGrammar();
  var parser1 = SMParser(grammar);

  print("Grammar compiled successfully.");
  print("Number of rules: ${parser1.stateMachine.rules.length}");
  print("Number of states: ${parser1.stateMachine.states.length}\n");

  // Step 2: Export the state machine to JSON
  print("Step 2: Exporting state machine to JSON...");
  var exportedJson = parser1.stateMachine.exportToJson();

  // Pretty print some of the JSON for inspection
  var jsonMap = json.decode(exportedJson) as Map<String, dynamic>;
  print("JSON Structure:");
  print("  - Version: ${jsonMap["version"]}");
  print("  - Number of states: ${(jsonMap["states"] as List).length}");
  print("  - Initial states: ${jsonMap["initialStates"]}");
  print("  - Rules: ${jsonMap["rules"]}");
  print("  - JSON size: ${exportedJson.length} characters\n");

  // Step 3: Import the state machine from JSON
  print("Step 3: Importing state machine from JSON WITHOUT grammar...");
  var parser2 = SMParser.fromImported(exportedJson);

  print("State machine imported successfully.");
  print("Number of states: ${parser2.stateMachine.states.length}\n");

  // Step 4: Verify the imported state machine works the same
  print("Step 4: Testing imported state machine...");

  const testInput1 = "1+2+3";
  print("Test input: '$testInput1'");

  // Parse with original
  print("  Parsing with original state machine...");
  var state1 = parser1.createParseState();
  state1.positionManager = FingerTree.leaf(testInput1);
  while (state1.hasPendingWork && state1.position < state1.positionManager.charLength) {
    state1.processNextToken();
  }
  state1.finish();
  var result1 = state1.accept;
  print("    Result: $result1");

  // Parse with imported
  print("  Parsing with imported state machine...");
  var state2 = parser2.createParseState();
  state2.positionManager = FingerTree.leaf(testInput1);
  while (state2.hasPendingWork && state2.position < state2.positionManager.charLength) {
    state2.processNextToken();
  }
  state2.finish();
  var result2 = state2.accept;
  print("    Result: $result2");

  if (result1 == result2) {
    print("\n✓ Both state machines produce the same result!\n");
  } else {
    print("\n✗ Results differ! This indicates an error in export/import.\n");
  }

  // Step 5: Demonstrate size savings
  print("Step 5: Performance comparison...");
  print("Original grammar definition length: ${grammarDef.length} chars");
  print("Exported JSON length: ${exportedJson.length} chars");
  print(
    "Compression ratio: "
    "${((exportedJson.length / grammarDef.length) * 100).toStringAsFixed(1)}%",
  );

  print("\n=== Example Complete ===");
  print("\nUsage in your application:");
  print("1. At build time:");
  print("   final json = myParser.stateMachine.exportToJson();");
  print("   File('my-grammar.json').writeAsStringSync(json);");
  print("");
  print("2. At runtime:");
  print("   final json = File('my-grammar.json').readAsStringSync();");
  print("   final parser = SMParser.fromImported(json);");
  print("   parser.recognize(input);");
}
