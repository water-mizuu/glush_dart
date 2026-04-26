import "package:glush/src/core/patterns.dart";

/// A table for storing complex operands used in the bytecode state machine.
///
/// Since the bytecode is a flat array of integers, complex objects like
/// [TokenChoice] patterns and [String] label names must be stored in a separate
/// table and referenced by their index.
class ConstantsTable {
  final List<TokenChoice> _choices = [];
  final List<String> _strings = [];

  final Map<TokenChoice, int> _choiceToId = {};
  final Map<String, int> _stringToId = {};

  /// Adds a [choice] to the table and returns its unique index.
  int addChoice(TokenChoice choice) {
    return _choiceToId.putIfAbsent(choice, () {
      var id = _choices.length;
      _choices.add(choice);
      return id;
    });
  }

  /// Retrieves the [TokenChoice] associated with the given [id].
  TokenChoice getChoice(int id) => _choices[id];

  /// Adds a [string] to the table and returns its unique index.
  int addString(String string) {
    return _stringToId.putIfAbsent(string, () {
      var id = _strings.length;
      _strings.add(string);
      return id;
    });
  }

  /// Retrieves the [String] associated with the given [id].
  String getString(int id) => _strings[id];

  /// Returns the total number of token choices in the table.
  int get choiceCount => _choices.length;

  /// Returns the total number of strings in the table.
  int get stringCount => _strings.length;

  /// Returns all stored token choices.
  List<TokenChoice> get choices => List.unmodifiable(_choices);

  /// Returns all stored strings.
  List<String> get strings => List.unmodifiable(_strings);
}
