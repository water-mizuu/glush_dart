import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  test("StructuredEvaluator handles relativized marks correctly", () {
    var grammarText = r"""
      S = $list block+;
      block = $block '{' expr+ '}';
      expr = $add left:expr '+' right:term | term;
      term = $mul left:term '*' right:atom | atom;
      atom = $num [0-9]+;
    """;
    var parser = grammarText.toSMParser();
    var input = "{1*2+3}{4*5}";
    
    var state = parser.createParseState(
      captureTokensAsMarks: true,
      isSupportingAmbiguity: true,
    );
    state.positionManager = FingerTree.leaf(input);
    while (state.hasPendingWork && state.position < state.positionManager.charLength) {
      state.processNextToken();
    }
    state.finish();
    
    var forest = state.forest!;
    var result = const StructuredEvaluator().evaluate(forest, input: input);
    print(result);
    
    // Check that we can extract the text correctly
    expect(result.span, equals(input));
    
    // Check structure
    var list = result.children.first.$2 as ParseResult;
    expect(list.children.length, equals(2)); // two blocks
    expect(list.children[0].$1, equals("block.block"));
    expect(list.children[1].$1, equals("block.block"));
  });
}
