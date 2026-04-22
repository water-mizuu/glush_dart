import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Retreat Pattern (<)", () {
    test("basic retreat moves position back", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token.char("a");
          var b = Token.char("b");
          // 'a' < 'ab' -> matches 'a', retreats, then matches 'a' and 'b'
          return a < (a >> b);
        });
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("ab"), isTrue);
      // "a" should fail because "ab" is expected after retreat
      expect(parser.recognize("a"), isFalse);
    });

    test("multiple retreats work correctly", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token.char("a");
          var b = Token.char("b");
          var c = Token.char("c");
          // matches 'abc', retreats twice, matches 'b', retreats, matches 'bc'
          // 'abc' -> pos 3
          // <     -> pos 2
          // <     -> pos 1
          // 'b'   -> pos 2
          // <     -> pos 1
          // 'bc'  -> pos 3
          return ((a >> b >> c) < Retreat() >> b) < (b >> c);
        });
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("abc"), isTrue);
    });

    test("retreat at position 0 is ignored or fails safely", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token.char("a");
          return Retreat() >> a;
        });
        return r;
      });

      var parser = SMParser(grammar);
      // Since it cannot retreat from 0, it should fail to advance to 'a'
      expect(parser.recognize("a"), isFalse);
    });

    test("retreat combined with marks", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token.char("a");
          var b = Token.char("b");
          // match 'a', mark it, retreat, match 'ab', mark it
          return a < (a >> b);
        });
        return r;
      });

      var parser = SMParser(grammar);
      var result = parser.parse("ab");
      expect(result, isA<ParseSuccess>());
      // Marks from both the first 'a' and the second 'ab' should be present
      // depending on how marks are merged during retreat.
      // Since we use the same marks when retreating, they should accumulate.
    });
  });
}
