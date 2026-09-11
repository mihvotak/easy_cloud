import '../domain/editor_save.dart';

export '../domain/editor_save.dart';
export '../domain/editor_file.dart';

/// Application-facing contract for a conflict-safe editor save.
///
/// The concrete implementation lives in the data layer.  Keeping this
/// contract free of auth tokens, widgets, and transport response objects lets
/// a future editor call it from any presentation boundary.
abstract interface class EditorSaveService {
  Future<EditorConflictCheckResult> checkConflict(
    EditorSaveBaseline baseline, {
    EditorSaveCancellation? cancellation,
  });

  Future<EditorSaveResult> save(
    EditorSaveBaseline baseline,
    List<int> bytes, {
    EditorSaveChoice choice = EditorSaveChoice.unchanged,
    EditorSaveCancellation? cancellation,
    void Function(EditorSaveProgress progress)? onProgress,
  });

  Future<EditorSaveResult> saveRequest(
    EditorSaveRequest request, {
    EditorSaveCancellation? cancellation,
    void Function(EditorSaveProgress progress)? onProgress,
  });

  Future<void> close();
}
