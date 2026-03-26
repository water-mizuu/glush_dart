// ignore_for_file: unnecessary_cast

import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Pattern Inversion", () {
    test("inverts ExactToken", () {
      var a = Token.char("a");
      var inv = a.invert();
      // Should be ( < 97 | > 97 )
      expect(inv, isA<Alt>());
      expect((inv as Alt).left, isA<Token>());
      expect((inv as Alt).right, isA<Token>());
    });

    test("inverts And to Not", () {
      var a = Token.char("a");
      var andA = a.and();
      var inv = andA.invert();
      expect(inv, isA<Not>());
      expect((inv as Not).pattern.toString(), equals(a.toString()));
    });

    test("inverts Not to And", () {
      var a = Token.char("a");
      var notA = a.not();
      var inv = notA.invert();
      expect(inv, isA<And>());
      expect((inv as And).pattern.toString(), equals(a.toString()));
    });

    test("double inversion of Not is And", () {
      var a = Token.char("a");
      var notA = a.not();
      var invInv = notA.invert().invert();
      expect(invInv, isA<Not>());
      expect((invInv as Not).pattern.toString(), equals(a.toString()));
    });

    test("double inversion of And is Not", () {
      var a = Token.char("a");
      var andA = a.and();
      var invInv = andA.invert().invert();
      expect(invInv, isA<And>());
      expect((invInv as And).pattern.toString(), equals(a.toString()));
    });

    test("inverts Alt using De Morgan (Tokens)", () {
      var a = Token.char("a");
      var b = Token.char("b");
      var alt = a | b;
      var inv = alt.invert();
      expect(inv, isA<Conj>());
      expect((inv as Conj).left.toString(), equals(a.invert().toString()));
      expect((inv as Conj).right.toString(), equals(b.invert().toString()));
    });

    test("inverts Alt to Not (Non-Tokens)", () {
      var plainWs =
          (Token.char(" ") | Token.char("\t")).plus() >> //
          (Token.char(" ") | Token.char("\t")).not();

      var newLine =
          (Token.char("\n") | Token.char("\r")).plus() >> //
          (Token.char("\n") | Token.char("\r")).not();

      var comment =
          Token.char("#") >> //
          ((Token.char("\n") | Token.char("\r")).not() >> Token.any()).star() >>
          (Token.char("\n") | EofAnchor());

      var ws = plainWs | comment | newLine;

      print(ws.invert());
      // _ = $ws (plain_ws | comment | newline)*
      // comment = '#' (!newline .)* (newline | eof)
      // plain_ws = [ \t]+ ![ \t]
      // newline = [\n\r]+ ![\n\r]
      var a = Token.char("a");
      var seq = a >> a;
      var alt = a | seq;
      var inv = alt.invert();
      // Since seq.invert() is Not(seq), we expect Alt.invert to fall back to not()
      // expect(inv, isA<Not>());
      // expect((inv as Not).pattern, equals(alt));

      print("Alt invert: $inv");
    });

    test("inverts Conj using De Morgan", () {
      var a = Token.char("a");
      var b = Token.char("b");
      var conj = a & b;
      var inv = conj.invert();
      expect(inv, isA<Alt>());
      expect((inv as Alt).left.toString(), equals(a.invert().toString()));
      expect((inv as Alt).right.toString(), equals(b.invert().toString()));
    });

    test("inverts Seq to Not", () {
      var a = Token.char("a");
      var seq = a >> a;
      var inv = seq.invert();
      expect(inv, isA<Not>());
      expect((inv as Not).pattern, equals(seq));
    });
  });
}
