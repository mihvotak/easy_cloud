export 'file_exporter.dart';

/// Opens an already verified content-addressed cache object outside Flutter.
abstract interface class FileOpener {
  /// [absolutePath] is the absolute path of a verified CAS object. The native
  /// implementation validates the path again before creating a content URI.
  /// [displayName] is the original cloud display name shown to the receiving
  /// application.
  Future<void> openFile(String absolutePath, String displayName);
}
