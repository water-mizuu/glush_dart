/// Cache key for memoizing rule returns.
extension type const ReturnKey._(int value) {
  ReturnKey(int? precedenceLevel, int position, int callStart)
    : this._(Object.hash(position, precedenceLevel, callStart));
}
