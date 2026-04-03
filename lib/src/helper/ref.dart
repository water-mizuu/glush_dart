/// Annotation zero-cost type wrapper that indicates that [value]
///   is merely a reference and should probably not be modified.
extension type const Ref<T>(T value) {}
