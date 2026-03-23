import 'package:test/test.dart';
import 'package:glush/glush.dart';

// Helper: create a stream from chunks using an async generator
Stream<String> createChunkedStream(List<String> chunks) async* {
  for (final chunk in chunks) {
    yield chunk;
  }
}

void main() {
  group('Async Parsing - parseWithForestAsync', () {
    test('parses simple input from stream', () async {
      final grammar = Grammar(() {
        return Rule('expr', () => Token(ExactToken(49))); // '1'
      });

      final parser = SMParser(grammar);

      // Stream '1' as a single chunk
      final result = await parser.parseWithForestAsync(createChunkedStream(['1']));

      expect(result, isA<ParseForestSuccess>());
      if (result is ParseForestSuccess) {
        expect(result.forest.extract().toList(), isNotEmpty);
      }
    });

    test('parses input from multiple chunks', () async {
      final grammar = Grammar(() {
        return Rule('expr', () {
          return Token(ExactToken(49)) >> Token(ExactToken(50)); // '12'
        });
      });

      final parser = SMParser(grammar);

      // Stream '12' as two separate chunks
      final result = await parser.parseWithForestAsync(createChunkedStream(['1', '2']));

      expect(result, isA<ParseForestSuccess>());
    });

    test('parses longer input from many small chunks', () async {
      final grammar = Grammar(() {
        late Rule expr;
        expr = Rule('expr', () {
          return Token(ExactToken(49)) |
              (expr() >> Token(ExactToken(43)) >> Token(ExactToken(49))); // 1 | expr+1
        });
        return expr;
      });

      final parser = SMParser(grammar);

      // Stream '1+1+1' one character at a time
      final result = await parser.parseWithForestAsync(
        createChunkedStream(['1', '+', '1', '+', '1']),
      );

      expect(result, isA<ParseForestSuccess>());
    });

    test('handles empty stream gracefully', () async {
      final grammar = Grammar(() {
        return Rule('expr', () => Eps());
      });

      final parser = SMParser(grammar);

      final result = await parser.parseWithForestAsync(createChunkedStream([]));

      expect(result, isA<ParseForestSuccess>());
    });

    test('returns ParseError for non-matching input', () async {
      final grammar = Grammar(() {
        return Rule('expr', () => Token(ExactToken(49))); // '1'
      });

      final parser = SMParser(grammar);

      // Stream '2' which doesn't match
      final result = await parser.parseWithForestAsync(createChunkedStream(['2']));

      expect(result, isA<ParseError>());
    });

    test('parses complex expression with stream', () async {
      final grammar = Grammar(() {
        late Rule num, term, expr;

        num = Rule('num', () => Token(ExactToken(49))); // '1'

        term = Rule('term', () {
          return num() | (term() >> Token(ExactToken(42)) >> num()); // term*num
        });

        expr = Rule('expr', () {
          return term() | (expr() >> Token(ExactToken(43)) >> term()); // expr+term
        });

        return expr;
      });

      final parser = SMParser(grammar);

      // Stream '1+1*1' as chunks
      final result = await parser.parseWithForestAsync(
        createChunkedStream(['1', '+', '1', '*', '1']),
      );

      expect(result, isA<ParseForestSuccess>());
      if (result is ParseForestSuccess) {
        final trees = result.forest.extract().toList();
        expect(trees, isNotEmpty);
      }
    });

    test('stream chunks of various sizes', () async {
      final grammar = Grammar(() {
        late Rule expr;
        expr = Rule('expr', () {
          return Token(ExactToken(49)) | (expr() >> Token(ExactToken(43)) >> expr());
        });
        return expr;
      });

      final parser = SMParser(grammar);

      // Stream '1+1+1' with varied chunk sizes
      final result = await parser.parseWithForestAsync(createChunkedStream(['1+', '1+', '1']));

      expect(result, isA<ParseForestSuccess>());
    });

    test('stream single large chunk', () async {
      final grammar = Grammar(() {
        late Rule expr;
        expr = Rule('expr', () {
          return Token(ExactToken(49)) | (expr() >> Token(ExactToken(43)) >> expr());
        });
        return expr;
      });

      final parser = SMParser(grammar);

      // Stream entire input as one chunk
      final result = await parser.parseWithForestAsync(createChunkedStream(['1+1+1']));

      expect(result, isA<ParseForestSuccess>());
    });

    test('parses stream with markers', () async {
      final grammar = Grammar(() {
        late Rule expr;
        expr = Rule('expr', () {
          return Token(ExactToken(49)) |
              (Marker('add') >> expr() >> Token(ExactToken(43)) >> expr());
        });
        return expr;
      });

      final parser = SMParser(grammar);

      final result = await parser.parseWithForestAsync(createChunkedStream(['1', '+', '1']));

      expect(result, isA<ParseForestSuccess>());
      if (result is ParseForestSuccess) {
        final trees = result.forest.extract().toList();
        expect(trees, isNotEmpty);
      }
    });

    test('async stream reuses buffer state correctly', () async {
      final grammar = Grammar(() {
        return Rule('expr', () => Token.char('1')); // '1'
      });

      final parser = SMParser(grammar);

      // First parse
      final result1 = await parser.parseWithForestAsync(createChunkedStream(['1']));
      expect(result1, isA<ParseForestSuccess>());

      // Second parse with same parser should work (buffer is cleared)
      final result2 = await parser.parseWithForestAsync(createChunkedStream(['1']));
      expect(result2, isA<ParseForestSuccess>());
    });

    test('stream with whitespace-like characters', () async {
      final grammar = Grammar(() {
        return Rule('expr', () {
          return Token(ExactToken(32)) >> Token(ExactToken(32)); // two spaces
        });
      });

      final parser = SMParser(grammar);

      final result = await parser.parseWithForestAsync(createChunkedStream([' ', ' ']));

      expect(result, isA<ParseForestSuccess>());
    });

    test('stream input matches synchronous parse result', () async {
      final grammar = Grammar(() {
        late Rule expr;
        expr = Rule('expr', () {
          return Token(ExactToken(49)) | (expr() >> Token(ExactToken(43)) >> expr());
        });
        return expr;
      });

      final parser = SMParser(grammar);
      const input = '1+1+1';

      // Synchronous parse
      final syncResult = parser.parseWithForest(input);

      // Asynchronous parse from stream
      final asyncResult = await parser.parseWithForestAsync(createChunkedStream([input]));

      // Both should succeed
      expect(syncResult, isA<ParseForestSuccess>());
      expect(asyncResult, isA<ParseForestSuccess>());

      if (syncResult is ParseForestSuccess && asyncResult is ParseForestSuccess) {
        // Both should produce trees
        final syncTrees = syncResult.forest.extract().toList();
        final asyncTrees = asyncResult.forest.extract().toList();
        expect(syncTrees.length, equals(asyncTrees.length));
      }
    });

    test('stream with predicates', () async {
      final grammar = Grammar(() {
        late Rule expr;
        expr = Rule('expr', () {
          return And(Token(ExactToken(49))) >> Token(ExactToken(49)) | Token(ExactToken(50));
        });
        return expr;
      });

      final parser = SMParser(grammar);

      final result = await parser.parseWithForestAsync(createChunkedStream(['1']));

      expect(result, isA<ParseForestSuccess>());
    });
  });
}
