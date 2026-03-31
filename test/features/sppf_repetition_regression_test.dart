import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("SPPF repetition regression", () {
    test("sequence followed by star builds a non-empty forest", () {
      var parser = "S = 'a' 'b'*".toSMParser(startRuleName: "S");

      var result = parser.parseWithForest("abbb");
      expect(result, isA<ParseForestSuccess>());

      var forest = (result as ParseForestSuccess).forest;
      var root = forest.root;
      var trees = forest.extract().toList();

      expect(root.families, isNotEmpty);
      expect(trees, isNotEmpty);
      expect(trees.single.children, isNotEmpty);
    });

    test("sequence followed by plus builds a non-empty forest", () {
      var parser = "S = 'a' 'b'+".toSMParser(startRuleName: "S");

      var result = parser.parseWithForest("abbb");
      expect(result, isA<ParseForestSuccess>());

      print(
        result.forestSuccess()!.forest.extract().map((t) => t.toPrecedenceString("abbb")).toList(),
      );

      var forest = (result as ParseForestSuccess).forest;
      var root = forest.root;
      var trees = forest.extract().toList();

      expect(root.families, isNotEmpty);
      expect(trees, isNotEmpty);
      expect(trees.single.children, isNotEmpty);
    });

    test("meta-style grammar extracts nested structure instead of a single span", () {
      var parser =
          r'''
            full = full:(_ file:file _);
            file = rules:(left:file _ right:rule) | first:(rule:rule);
            rule = rule:(name:ident _ '=' _ body:choice ( _ ';' )?);
            choice = choice:(left:choice _ '|' _ right:seq) | seq;
            seq = seq:(left:seq _ (&isContinuation) right:prefix) | prefix;
            prefix = and:('&' atom:rep) | not:('!' atom:rep) | rep;
            rep = rep:(atom:primary kind:repKind) | primary;
            repKind = star:'*' | plus:'+' | question:'?';
            primary = group:('(' _ inner:choice _ ')')
                    | label:(name:ident ':' atom:primary)
                    | mark:('$' name:ident)
                    | ref:ident
                    | lit:literal
                    | range:charRange
                    | any:'.';
            isContinuation = &(ident !(_ [=]))
                          | &literal
                          | &charRange
                          | &'['
                          | &'('
                          | &'.'
                          | &'$'
                          | &'!'
                          | &'&';
            ident = [A-Za-z$_] [A-Za-z$_0-9]*;
            literal = ['] (!['] .)* ['] | ["] (!["] .)* ["];
            charRange = '[' (!']' .)* ']';
            _ = (plain_ws | comment | newline)*;
            comment = '#' (!newline .)*;
            plain_ws = [ \t]+;
            newline = [\n\r]+;
          '''
              .toSMParser(startRuleName: "full");

      var input =
          r"""
abc = c | &d !e*"""
              .trim();

      var result = parser.parseWithForest(input);
      expect(result, isA<ParseForestSuccess>());

      print(
        result.forestSuccess()!.forest.extract().map((t) => t.toPrecedenceString(input)).toList(),
      );

      var forest = result.forestSuccess()!.forest;
      var root = forest.root;
      var rootFamily = root.families.first;
      var rootChildren = rootFamily.children.toList();

      expect(root.families, isNotEmpty);
      expect(rootChildren, isNotEmpty);
      expect(
        rootChildren.any(
          (child) => switch (child) {
            SymbolicNode(:var families) => families.isNotEmpty,
            IntermediateNode(:var families) => families.isNotEmpty,
            _ => false,
          },
        ),
        isTrue,
      );
    });
  });
}
