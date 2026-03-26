import "package:glush/glush.dart";
import "package:test/test.dart";

// Helper: create a stream from chunks using an async generator
Stream<String> createChunkedStream(List<String> chunks) async* {
  for (var chunk in chunks) {
    yield chunk;
  }
}

void main() {
  group("Async Parsing - parseWithForestAsync", () {
    test("parses simple input from stream", () async {
      var grammar = Grammar(() {
        return Rule("expr", () => Token(const ExactToken(49))); // '1'
      });

      var parser = SMParser(grammar);

      // Stream '1' as a single chunk
      var result = await parser.parseWithForestAsync(createChunkedStream(["1"]));

      expect(result, isA<ParseForestSuccess>());
      if (result is ParseForestSuccess) {
        expect(result.forest.extract().toList(), isNotEmpty);
      }
    });

    test("parses input from multiple chunks", () async {
      var grammar = Grammar(() {
        return Rule("expr", () {
          return Token(const ExactToken(49)) >> Token(const ExactToken(50)); // '12'
        });
      });

      var parser = SMParser(grammar);

      // Stream '12' as two separate chunks
      var result = await parser.parseWithForestAsync(createChunkedStream(["1", "2"]));

      expect(result, isA<ParseForestSuccess>());
    });

    test("parses longer input from many small chunks", () async {
      var grammar = Grammar(() {
        late Rule expr;
        expr = Rule("expr", () {
          return Token(const ExactToken(49)) |
              (expr() >> Token(const ExactToken(43)) >> Token(const ExactToken(49))); // 1 | expr+1
        });
        return expr;
      });

      var parser = SMParser(grammar);

      // Stream '1+1+1' one character at a time
      var result = await parser.parseWithForestAsync(
        createChunkedStream(["1", "+", "1", "+", "1"]),
      );

      expect(result, isA<ParseForestSuccess>());
    });

    test("handles empty stream gracefully", () async {
      var grammar = Grammar(() {
        return Rule("expr", () => Eps());
      });

      var parser = SMParser(grammar);

      var result = await parser.parseWithForestAsync(createChunkedStream([]));

      expect(result, isA<ParseForestSuccess>());
    });

    test("returns ParseError for non-matching input", () async {
      var grammar = Grammar(() {
        return Rule("expr", () => Token(const ExactToken(49))); // '1'
      });

      var parser = SMParser(grammar);

      // Stream '2' which doesn't match
      var result = await parser.parseWithForestAsync(createChunkedStream(["2"]));

      expect(result, isA<ParseError>());
    });

    test("parses complex expression with stream", () async {
      var grammar = Grammar(() {
        late Rule num;
        late Rule term;
        late Rule expr;

        num = Rule("num", () => Token(const ExactToken(49))); // '1'

        term = Rule("term", () {
          return num() | (term() >> Token(const ExactToken(42)) >> num()); // term*num
        });

        expr = Rule("expr", () {
          return term() | (expr() >> Token(const ExactToken(43)) >> term()); // expr+term
        });

        return expr;
      });

      var parser = SMParser(grammar);

      // Stream '1+1*1' as chunks
      var result = await parser.parseWithForestAsync(
        createChunkedStream(["1", "+", "1", "*", "1"]),
      );

      expect(result, isA<ParseForestSuccess>());
      if (result is ParseForestSuccess) {
        var trees = result.forest.extract().toList();
        expect(trees, isNotEmpty);
      }
    });

    test("stream chunks of various sizes", () async {
      var grammar = Grammar(() {
        late Rule expr;
        expr = Rule("expr", () {
          return Token(const ExactToken(49)) | (expr() >> Token(const ExactToken(43)) >> expr());
        });
        return expr;
      });

      var parser = SMParser(grammar);

      // Stream '1+1+1' with varied chunk sizes
      var result = await parser.parseWithForestAsync(createChunkedStream(["1+", "1+", "1"]));

      expect(result, isA<ParseForestSuccess>());
    });

    test("stream single large chunk", () async {
      var grammar = Grammar(() {
        late Rule expr;
        expr = Rule("expr", () {
          return Token(const ExactToken(49)) | (expr() >> Token(const ExactToken(43)) >> expr());
        });
        return expr;
      });

      var parser = SMParser(grammar);

      // Stream entire input as one chunk
      var result = await parser.parseWithForestAsync(createChunkedStream(["1+1+1"]));

      expect(result, isA<ParseForestSuccess>());
    });

    test("parses stream with markers", () async {
      var grammar = Grammar(() {
        late Rule expr;
        expr = Rule("expr", () {
          return Token(const ExactToken(49)) |
              (Marker("add") >> expr() >> Token(const ExactToken(43)) >> expr());
        });
        return expr;
      });

      var parser = SMParser(grammar);

      var result = await parser.parseWithForestAsync(createChunkedStream(["1", "+", "1"]));

      expect(result, isA<ParseForestSuccess>());
      if (result is ParseForestSuccess) {
        var trees = result.forest.extract().toList();
        expect(trees, isNotEmpty);
      }
    });

    test("async stream reuses buffer state correctly", () async {
      var grammar = Grammar(() {
        return Rule("expr", () => Token.char("1")); // '1'
      });

      var parser = SMParser(grammar);

      // First parse
      var result1 = await parser.parseWithForestAsync(createChunkedStream(["1"]));
      expect(result1, isA<ParseForestSuccess>());

      // Second parse with same parser should work (buffer is cleared)
      var result2 = await parser.parseWithForestAsync(createChunkedStream(["1"]));
      expect(result2, isA<ParseForestSuccess>());
    });

    test("stream with whitespace-like characters", () async {
      var grammar = Grammar(() {
        return Rule("expr", () {
          return Token(const ExactToken(32)) >> Token(const ExactToken(32)); // two spaces
        });
      });

      var parser = SMParser(grammar);

      var result = await parser.parseWithForestAsync(createChunkedStream([" ", " "]));

      expect(result, isA<ParseForestSuccess>());
    });

    test("stream input matches synchronous parse result", () async {
      var grammar = Grammar(() {
        late Rule expr;
        expr = Rule("expr", () {
          return Token(const ExactToken(49)) | (expr() >> Token(const ExactToken(43)) >> expr());
        });
        return expr;
      });

      var parser = SMParser(grammar);
      const input = "1+1+1";

      // Synchronous parse
      var syncResult = parser.parseWithForest(input);

      // Asynchronous parse from stream
      var asyncResult = await parser.parseWithForestAsync(createChunkedStream([input]));

      // Both should succeed
      expect(syncResult, isA<ParseForestSuccess>());
      expect(asyncResult, isA<ParseForestSuccess>());

      if (syncResult is ParseForestSuccess && asyncResult is ParseForestSuccess) {
        // Both should produce trees
        var syncTrees = syncResult.forest.extract().toList();
        var asyncTrees = asyncResult.forest.extract().toList();
        expect(syncTrees.length, equals(asyncTrees.length));
      }
    });

    test("stream with predicates", () async {
      var grammar = Grammar(() {
        late Rule expr;
        expr = Rule("expr", () {
          return And(Token(const ExactToken(49))) >> Token(const ExactToken(49)) |
              Token(const ExactToken(50));
        });
        return expr;
      });

      var parser = SMParser(grammar);

      var result = await parser.parseWithForestAsync(createChunkedStream(["1"]));

      expect(result, isA<ParseForestSuccess>());
    });
  });
}
