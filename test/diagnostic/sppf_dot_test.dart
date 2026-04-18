import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("SPPF DOT generator", () {
    test("renders a simple grammar to DOT", () {
      var parser =
          """
        start = "a" "b";
      """
              .toSMParser();

      var dot = parser.parseToDot("ab");

      expect(dot, contains("digraph BSPPF {"));
      expect(dot, contains(r'label="start\n'));
      expect(dot, contains('label="\'a\'\\n[0..1)"'));
      expect(dot, contains('label="\'b\'\\n[1..2)"'));
    });

    test("renders ambiguous grammar with packed nodes", () {
      var parser =
          """
        start = ("a" "b") | ("a" "b");
      """
              .toSMParser();

      var dot = parser.parseToDot("ab");

      // Should have multiple alts (Packed Nodes)
      expect(dot, contains("alt1"));
      expect(dot, contains("alt2"));
      // Packed nodes are circles
      expect(dot, contains("shape=circle, width=0.1"));
    });

    test("renders labels in SymbolNodes", () {
      var parser =
          """
        start = prefix:"a" suffix:"b";
      """
              .toSMParser();

      var dot = parser.parseToDot("ab");

      expect(dot, contains("prefix: [0..1)"));
      expect(dot, contains("suffix: [1..2)"));
    });
  });
}
