import "package:glush/src/parser/key/caller_key.dart";

extension type const ParseNodeKey._((int, int, CallerKey) data) {
  const ParseNodeKey(int stateId, int position, CallerKey caller)
    : this._((stateId, position, caller));

  int get stateId => data.$1;
  int get position => data.$2;
  CallerKey get caller => data.$3;
}
