/// Simple test to validate state machine export/import
import "package:glush/glush.dart";

void main() {
  print("=== State Machine Export/Import Test ===\n");

  // Step 1: Create a simple grammar
  print("Step 1: Creating a simple grammar...");
  const grammarSource = r"""
S = 'a' | 'b'
""";

  try {
    var grammar = grammarSource.toGrammar();
    var parser = SMParser(grammar);

    print("✓ Grammar compiled successfully");
    print("  States: ${parser.stateMachine.states.length}");
    print("  Rules: ${parser.stateMachine.rules.length}");
    print("  Initial States: ${parser.stateMachine.initialStates.length}\n");

    // Step 2: Test basic parsing with original
    print("Step 2: Testing basic parsing with original...");
    var result1 = parser.recognize("a");
    print("  recognize('a'): $result1");
    var result2 = parser.recognize("b");
    print("  recognize('b'): $result2");
    var result3 = parser.recognize("c");
    print("  recognize('c'): $result3\n");

    // Step 3: Export to JSON
    print("Step 3: Exporting state machine to JSON...");
    var json = parser.stateMachine.exportToJson();
    print("✓ Export successful!");
    print("  JSON size: ${json.length} characters\n");

    // Step 4: Import from JSON
    print("Step 4: Importing state machine from JSON WITHOUT grammar...");
    var importedParser = SMParser.fromImported(json);
    print("✓ Import successful!");
    print("  States: ${importedParser.stateMachine.states.length}");
    print("  Rules: ${importedParser.stateMachine.rules.length}\n");

    // Step 5: Test imported parser
    print("Step 5: Testing imported parser...");
    var result4 = importedParser.recognize("a");
    print("  recognize('a'): $result4");
    var result5 = importedParser.recognize("b");
    print("  recognize('b'): $result5");
    var result6 = importedParser.recognize("c");
    print("  recognize('c'): $result6\n");

    // Step 6: Verify results match
    print("Step 6: Verifying results match...");
    if (result1 == result4 && result2 == result5 && result3 == result6) {
      print("✓ All results match! Export/Import works correctly.\n");
    } else {
      print("✗ Results differ! There's an issue with export/import.\n");
      print("  Original: [$result1, $result2, $result3]");
      print("  Imported: [$result4, $result5, $result6]");
    }

    print("=== Test Complete ===");
  } on Exception catch (e, st) {
    print("✗ Error: $e");
    print("Stack trace:\n$st");
  }
}
