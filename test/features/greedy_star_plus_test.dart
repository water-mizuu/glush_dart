import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Greedy Star/Plus", () {
    test("star keeps the longest prefix before the following token", () {
      var parser = "S = head:('a'*) tail:('a')".toSMParser(captureTokensAsMarks: true);
      var outcome = parser.parse("aaa");

      expect(outcome, isA<ParseSuccess>());
      var tree = const StructuredEvaluator().evaluate((outcome as ParseSuccess).result.rawMarks);
      var head = tree.get("head").first.span;
      var tail = tree.get("tail").first.span;

      expect(head, equals("aa"));
      expect(tail, equals("a"));
    });

    test("plus keeps the longest prefix before the following token", () {
      var parser = "S = head:('a'+) tail:('a')".toSMParser(captureTokensAsMarks: true);
      var outcome = parser.parse("aaa");

      expect(outcome, isA<ParseSuccess>());
      var tree = const StructuredEvaluator().evaluate((outcome as ParseSuccess).result.rawMarks);
      var head = tree.get("head").first.span;
      var tail = tree.get("tail").first.span;

      expect(head, equals("aa"));
      expect(tail, equals("a"));
    });
  });
}
