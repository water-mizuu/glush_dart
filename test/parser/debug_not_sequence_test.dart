import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  test("NOT with sequence lookahead debug", () {
    var grammar = Grammar(() {
      var a = Token(const ExactToken(97)); // 'a'
      var b = Token(const ExactToken(98)); // 'b'
      var c = Token(const ExactToken(99)); // 'c'
      var pattern = (b >> c).not() >> a >> b.maybe();
      return Rule("test", () => pattern);
    });

    var parser = SMParser(grammar);

    var res1 = parser.recognize("a");
    var res2 = parser.recognize("ab");
    var res3 = parser.recognize("abc");
    var res4 = parser.recognize("");

    expect(res1, isTrue);
    expect(res2, isTrue);
    expect(res3, isFalse);
    expect(res4, isFalse);
  });
}
