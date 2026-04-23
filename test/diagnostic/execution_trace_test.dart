import "dart:io";

import "package:glush/glush.dart";
import "package:glush/src/parser/common/parse_state.dart";
import "package:glush/src/parser/common/tracer.dart";
import "package:test/test.dart";

void main() {
  group("Execution Trace Diagnostic", () {
    test("Generates a clear trace file for a simple grammar with predicates", () async {
      var grammar = Grammar(() {
        var b = Rule("b", () => Token(const ExactToken(98)));
        var start = Rule(
          "start",
          () =>
              (Token(const ExactToken(97)) >> b.call()).and() >>
              Token(const ExactToken(97)) >>
              b.call(),
        );
        return start;
      });

      var parser = SMParser(grammar);
      var tracePath = "test_trace.log";
      if (File(tracePath).existsSync()) {
        File(tracePath).deleteSync();
      }

      var tracer = FileTracer(tracePath);
      var pState = ParseState(
        parser,
        initialFrames: parser.initialFrames,
        isSupportingAmbiguity: false,
        captureTokensAsMarks: true,
        tracer: tracer,
      );

      // Input: "ab"
      pState.positionManager = FingerTree.leaf("ab");
      pState.processNextToken(); // 'a'
      pState.processNextToken(); // 'b'
      pState.finish();

      // Give FileTracer a moment to flush the IOSink
      await Future<void>.delayed(const Duration(milliseconds: 50));

      var traceFile = File(tracePath);
      expect(traceFile.existsSync(), isTrue);

      var content = traceFile.readAsStringSync();

      print(content);

      expect(content, contains("POSITION: 0"));
      expect(content, contains("POSITION: 1"));
      expect(content, contains("[* Process]"));
      expect(content, contains("[> Action]"));
      expect(content, contains("! Predicate matched"));
    });
  });
}
