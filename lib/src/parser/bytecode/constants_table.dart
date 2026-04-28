import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/bytecode/bytecode_machine.dart" show BytecodeOp;

/// Table for storing non-integer operands used in the bytecode state machine.
///
/// Since the bytecode is a flat array of integers, complex objects like
/// [String] label names must be stored in a separate table and referenced
/// by their index.
///
/// Note: [TokenChoice] patterns were previously stored here but have been
/// removed — token matching is now fully inlined into specialised opcodes
/// ([BytecodeOp.tokenExact], [BytecodeOp.tokenRange], etc.), so no
/// runtime lookup into a constants table is needed for token dispatch.
class ConstantsTable {
  final List<String> _strings = [];
  final Map<String, int> _stringToId = {};

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

  /// Returns the total number of strings in the table.
  int get stringCount => _strings.length;

  /// Returns all stored strings.
  List<String> get strings => List.unmodifiable(_strings);
}
