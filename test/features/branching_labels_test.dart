import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Branching Labels and Backreferences", () {
    test("Ambiguous labeling", () {
      // (a: "x" | b: "x") a
      // Input "xx"
      // Branch 1: "x" labeled as 'a'. Then matches 'a' (backreference) which matches "x". Total "xx". SUCCESS.
      // Branch 2: "x" labeled as 'b'. Then matches 'a' (backreference) but 'a' is not captured in this branch. FAIL.
      var parser =
          '''
        start = (a:"x" | b:"x") a;
      '''
              .toSMParser();

      var outcome = parser.recognize("xx");
      expect(outcome, isTrue);

      // "xy" should fail
      expect(parser.recognize("xy"), isFalse);
    });

    test("Backreference fails if branch doesn't match capture", () {
      var parser =
          '''
        start = (a:"x" | b:"y") a;
      '''
              .toSMParser();

      // "yx" matches b:"y" then tries to match a. Fails because a was not captured.
      var outcome = parser.recognize("yx");
      expect(outcome, isFalse);
    });

    test("Nested labels with backreferences", () {
      var parser =
          '''
        start = outer:(inner:"x") inner outer;
      '''
              .toSMParser();

      // outer:(inner:"x") matches "x", captures inner="x", outer="x".
      // Then inner matches "x".
      // Then outer matches "x".
      // Input "xxx" should succeed.
      var outcome = parser.recognize("xxx");
      expect(outcome, isTrue);

      expect(parser.recognize("xx"), isFalse);
      expect(parser.recognize("xxxx"), isFalse);
    });

    test("Overlapping labels in different branches", () {
      var parser =
          '''
        start = (x:"a" | x:"b") x;
      '''
              .toSMParser();

      expect(parser.recognize("aa"), isTrue);
      expect(parser.recognize("bb"), isTrue);
      expect(parser.recognize("ab"), isFalse);
      expect(parser.recognize("ba"), isFalse);
    });

    test("Complex branching with shared prefixes", () {
      // This tests that labels are correctly isolated even when branches share prefixes
      var parser =
          '''
        start = "prefix" (a:"1" | b:"1") a;
      '''
              .toSMParser();

      expect(parser.recognize("prefix11"), isTrue);
      expect(parser.recognize("prefix12"), isFalse);
    });

    test("Double capture (most recent wins)", () {
      var parser =
          '''
         start = a:"x" a:"y" a;
       '''
              .toSMParser();

      expect(parser.recognize("xyy"), isTrue);
      expect(parser.recognize("xyx"), isFalse);
    });
  });
}
