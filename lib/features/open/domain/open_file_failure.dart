enum OpenFileFailureType {
  download,
  noHandler,
  invalidRequest,
  platform,
  saveAs,
  busy,
}

/// A safe, UI-facing failure for a foreground file open.
///
/// The message is deliberately generic. In particular, neither a cache path
/// nor a native platform error is allowed to reach the presentation layer.
final class OpenFileFailure implements Exception {
  const OpenFileFailure(this.type);

  static const safeMessage = 'Не удалось открыть файл.';
  static const safeSaveAsMessage = 'Не удалось сохранить файл.';

  final OpenFileFailureType type;

  String get message => switch (type) {
    OpenFileFailureType.saveAs || OpenFileFailureType.busy => safeSaveAsMessage,
    _ => safeMessage,
  };

  @override
  String toString() => message;
}
