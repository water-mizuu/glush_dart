import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Function-style grammar rules", () {
    test("parse versioned packet layouts with data-driven guards", () {
      const grammarText = r"""
        start =
              message(version: 1, checksum: false)
            | message(version: 2, checksum: true)

        message(version, checksum) =
              if (version == 1 && !checksum)
                v1Header payload trailer
            | if (version == 2 && checksum)
                v2Header payload checksumByte(version, checksum) trailer

        v1Header = 'A'
        v2Header = 'B'
        payload = 'X' 'Y'
        checksumByte(version, checksum) = if (version == 2 && checksum) 'C'
        trailer = '!'
      """;

      var parser = grammarText.toSMParser();

      expect(parser.recognize("AXY!"), isTrue);
      expect(parser.recognize("BXYC!"), isTrue);
      expect(parser.recognize("BXY!"), isFalse);
    });
  });
}
