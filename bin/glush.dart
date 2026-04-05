// ignore_for_file: strict_raw_type, unreachable_from_main

import "dart:io";

import "package:glush/glush.dart";
import "package:glush/src/parser/common/tracer.dart" show FileTracer;

// final grammar = Grammar(() {
//   late Rule s;
//   s = Rule("S", () {
//     return Label("1", Token.char("s")) | // s
//         Label("2", s() >> s()) |
//         Label("3", s() >> s() >> s()) |
//         Label("4", s() >> s() >> s() >> s());
//   });
//   return s;
// });
// final parser = SMParserMini(grammar);

const grammar = r"""
S = $2 &S S | 's'
""";

final parser = grammar.toSMParser();

/// Export a compiled state machine to JSON.
///
/// Usage: dart bin/glush.dart export <output_file>
void exportStateMachine(String outputFile) {
  var json = parser.stateMachine.exportToJson();
  File(outputFile).writeAsStringSync(json);
  print("Exported state machine to: $outputFile");
  print("File size: ${File(outputFile).lengthSync()} bytes");
}

/// Parse using a previously exported state machine.
///
/// Usage: dart bin/glush.dart parse-imported <state_machine_file> <input>
void parseWithImported(String stateMachineFile, String input) {
  var jsonContent = File(stateMachineFile).readAsStringSync();

  // Create a minimal grammar interface for the imported state machine
  // In production, you'd store the grammar definition as well
  var importedParser = SMParser.fromImported(jsonContent, parser.grammar);

  var tracer = FileTracer("imported-parse.log");
  var state = importedParser.createParseState(isSupportingAmbiguity: true, tracer: tracer);
  for (int code in input.codeUnits) {
    state.processToken(code);
  }
  state.finish();

  var paths = state.lastStep?.acceptedContexts.values.fold(
    const GlushList<Mark>.empty(),
    GlushList<Mark>.branched,
  );

  if (paths == null) {
    print("Parse failed");
    return;
  }

  print(paths.allPaths().map((v) => v.evaluateStructure()).join("\n"));
}

void main(List<String> args) async {
  // Command processing

  if (args.isNotEmpty) {
    switch (args[0]) {
      case "export":
        if (args.length < 2) {
          print("Usage: glush export <output_file>");
          exit(1);
        }
        exportStateMachine(args[1]);

      case "parse-imported":
        if (args.length < 3) {
          print("Usage: glush parse-imported <state_machine_file> <input>");
          exit(1);
        }
        parseWithImported(args[1], args[2]);

      default:
        print("Unknown command: ${args[0]}");
        print("Available commands:");
        print("  export <file>              - Export compiled state machine to JSON");
        print("  parse-imported <file> <input> - Parse using imported state machine");
        exit(1);
    }
  }

  // Default behavior: parse and output
  const input = "s";

  var tracer = FileTracer("another.log");
  var state = parser.createParseState(isSupportingAmbiguity: true, tracer: tracer);
  for (int code in input.codeUnits) {
    state.processToken(code);
  }
  state.finish();

  var paths = state.lastStep?.acceptedContexts.values.fold(
    const GlushList<Mark>.empty(),
    GlushList<Mark>.branched,
  );

  if (paths == null) {
    return;
  }

  print(paths.allPaths().map((v) => v.evaluateStructure()).join("\n"));

  File("another.dot")
    ..createSync(recursive: true)
    ..writeAsStringSync(paths.toDot());

  File("state-machine.dot")
    ..createSync(recursive: true)
    ..writeAsStringSync(parser.stateMachine.toDot());

  return;
}
