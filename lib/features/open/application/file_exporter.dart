/// Saves an already verified content-addressed cache object through the
/// platform's file picker.
abstract interface class FileExporter {
  /// Returns `true` after the destination was selected and the object was
  /// copied successfully. A user-cancelled picker returns `false`.
  ///
  /// [absolutePath] is the absolute path of a verified CAS object. The native
  /// implementation validates it again before reading the file.
  /// [displayName] is the original cloud display name used as the picker's
  /// initial filename.
  Future<bool> saveFileAs(String absolutePath, String displayName);
}
