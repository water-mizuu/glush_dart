import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("XML-like mark bridge", () {
    // The opening tag is captured from the mark forest and reused to validate
    // the closing tag, which is the core data-driven XML-style use case.
    test("captures the opening tag and validates the closing tag against it", () {
      const grammarText = r"""
        start = element

        element =
              openTag body closeTag(tag)

        openTag =
              '<' tag:name '>'

        closeTag(tag) =
              '</' close:name '>' verify(tag, close)

        verify(open, close) = if (open == close) ''

        body =
              text

        text =
              [A-Za-z ]+

        name = [A-Za-z_] [A-Za-z0-9_]*
      """;

      var parser = grammarText.toSMParser();

      expect(parser.recognize("<book>Hello</book>"), isTrue);
      expect(parser.recognize("<book>Hello</author></book>"), isFalse);
    });

    // Ambiguous nested content should still finish because the mark bridge and
    // branch deduplication keep equivalent forest states from exploding.
    test("avoids ambiguity blowup on nested XML-like content", () {
      const grammarText = r"""
        start = document

        document = element+

        element =
              openTag content closeTag(tag)

        openTag =
              '<' tag:name '>'

        closeTag(tag) =
              '</' close:name '>' verify(tag, close)

        verify(open, close) = if (open == close) ''

        content =
              (element | text)*

        text =
              [A-Za-z ]+

        name = [A-Za-z_] [A-Za-z0-9_]*
      """;

      var parser = grammarText.toSMParser();
      var result = parser.parseAmbiguous("<book>Hello<author>Ada</author></book>");

      expect(result, isA<ParseAmbiguousForestSuccess>());
    });
  });
}
