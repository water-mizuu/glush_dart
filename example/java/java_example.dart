import "dart:io";

import "package:glush/glush.dart";

void main() {
  // Read the grammar from the file
  var grammarString = File("example/java/java.glush").readAsStringSync();

  var parser = grammarString.toSMParser();

  const input = """
package com.example;

import java.util.*;

public class HelloWorld extends Base {
    private String message = "Hello, Glush!";
    public static int count = 0;

    public void sayHello(String name) {
        if (name != null) {
            print(message + " " + name);
        } else {
            print("Hello, Anonymous!");
        }
        count++;
    }

    /*
     * Main method
     */
    public void complexFeatures() {
        try {
            List<String> list = new ArrayList<>(); // Diamond
            int[] arr = new int[] {1, 2, 3};      // Array init
            String s = list.get(0);
        } catch (IOException | SQLException e) {   // Multi-catch
            e.printStackTrace();
        }
    }

    public static void main(String[] args) {
        HelloWorld hw = new HelloWorld();
        hw.sayHello("User");

        for (int i = 0; i < 5; i++) {
            HelloWorld.count += i;
        }
    }
}
""";

  print("PARSING JAVA SOURCE:\n");
  var outcome = parser.parse(input, captureTokensAsMarks: true);

  if (outcome is ParseSuccess) {
    print("PARSE SUCCESSFUL!");
    var tree = outcome.rawMarks.evaluateStructure(input);

    print("\nSTRUCTURED TREE (Sample):");
    _printTree(tree, 0, maxDepth: 4);
  } else if (outcome is ParseError) {
    print("\nPARSE FAILED: Error at position ${outcome.position}");

    // Find line and column
    var lines = input.substring(0, outcome.position).split("\n");
    var line = lines.length;
    var column = lines.last.length + 1;

    print("Location: Line $line, Column $column");

    var start = (outcome.position - 20).clamp(0, input.length);
    var end = (outcome.position + 20).clamp(0, input.length);
    var context = input.substring(start, end).replaceAll("\n", " ");
    var pointer = " " * (outcome.position - start) + "^";

    print("Context: $context");
    print("         $pointer");
  }
}

void _printTree(ParseResult node, int depth, {int maxDepth = 100}) {
  if (depth > maxDepth) {
    return;
  }

  var indent = "  " * depth;
  for (var (label, node) in node.children) {
    var spanSnippet = node.span.trim().replaceAll("\n", r"\n");
    if (spanSnippet.isEmpty) {
      continue;
    }

    var displaySpan = spanSnippet.length > 60 ? "${spanSnippet.substring(0, 57)}..." : spanSnippet;

    print("${indent}LABEL: $label => '$displaySpan'");
    if (node is ParseResult) {
      _printTree(node, depth + 1, maxDepth: maxDepth);
    }
  }
}
