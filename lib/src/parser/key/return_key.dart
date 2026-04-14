extension type const ReturnKey._(int value) {
  ReturnKey(int? precedenceLevel, int? position, int? callStart)
    : this._((position ?? 0) << 32 | (precedenceLevel ?? 0xFFFF) << 16 | (callStart ?? 0xFFFF));
}
