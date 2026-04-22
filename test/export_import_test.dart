import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("StateMachine Export/Import", () {
    test("Round-trip preserves character ranges and complex structures", () {
      const grammarDef = r"""
        Result = Expr
        Expr = Term (('+' | '-') Term)*
        Term = Factor (('*' | '/') Factor)*
        Factor = Number | '(' Expr ')'
        Number = [0-9]+
      """;

      var grammar = grammarDef.toGrammar();
      var originalParser = SMParser(grammar);

      var exportedJson = originalParser.stateMachine.exportToJson();
      var importedParser = SMParser.fromImported(exportedJson, grammar);

      const testInputs = ["1+2*3", "(1+2)*3", "10+20-5", "100/10+5"];

      for (var input in testInputs) {
        var state1 = originalParser.createParseState();
        for (var code in input.codeUnits) {
          state1.processToken(code);
        }
        state1.finish();

        var state2 = importedParser.createParseState();
        for (var code in input.codeUnits) {
          state2.processToken(code);
        }
        state2.finish();

        expect(state2.accept, equals(state1.accept), reason: 'Input "$input" failure');
      }
    });

    test("Preserves anchors and predicates", () {
      const grammarDef = r"""
        S = ^ 'a' $ | & 'b' 'b'
      """;

      var grammar = grammarDef.toGrammar();
      var originalParser = SMParser(grammar);

      var exportedJson = originalParser.stateMachine.exportToJson();
      var importedParser = SMParser.fromImported(exportedJson, grammar);

      var inputs = {
        "a": true,
        "b": true, // & 'b' is lookahead, then 'b' matches
        "bb": false, // 'b' matches the first char, then EOF expected but found 'b'
        "aa": false,
      };

      for (var entry in inputs.entries) {
        var input = entry.key;
        var expected = entry.value;

        var state = importedParser.createParseState();
        for (var code in input.codeUnits) {
          state.processToken(code);
        }
        state.finish();

        expect(
          state.accept,
          equals(expected),
          reason: 'Input "$input" failure (Expected $expected, got ${state.accept})',
        );
      }
    });

    test("Preserves rule calls with precedence", () {
      const grammarDef = r"""
        E = 11| [0-9]
          | 7| E '*' E
          | 6| E '+' E
      """;

      var grammar = grammarDef.toGrammar();
      var originalParser = SMParser(grammar);

      var exportedJson = originalParser.stateMachine.exportToJson();
      var importedParser = SMParser.fromImported(exportedJson, grammar);

      const input = "1+2*3";

      var state1 = originalParser.createParseState();
      for (var code in input.codeUnits) {
        state1.processToken(code);
      }
      state1.finish();

      var state2 = importedParser.createParseState();
      for (var code in input.codeUnits) {
        state2.processToken(code);
      }
      state2.finish();

      expect(state2.accept, isTrue);
    });
  });
}
