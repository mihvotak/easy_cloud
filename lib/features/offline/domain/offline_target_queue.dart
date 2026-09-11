import 'offline_target.dart';

/// Optional estimate supplied when a folder is pinned for offline use.
///
/// A missing value is intentionally different from zero: the UI can ask for
/// confirmation later when the remote tree cannot be estimated yet.
final class OfflineTargetEstimate {
  const OfflineTargetEstimate({
    this.files,
    this.bytes,
    this.hasUnknown = false,
  });

  final int? files;
  final int? bytes;
  final bool hasUnknown;

  bool get isComplete => files != null && bytes != null && !hasUnknown;
}

/// A read model used by the queue controller. It deliberately contains the
/// durable rows rather than a second mutable state machine.
final class OfflineTargetSummary {
  OfflineTargetSummary({
    required this.target,
    required Iterable<OfflineTargetFrontierRecord> frontier,
    required Iterable<OfflineTargetFileRecord> files,
  }) : frontier = List.unmodifiable(frontier),
       files = List.unmodifiable(files);

  final OfflineTargetRecord target;
  final List<OfflineTargetFrontierRecord> frontier;
  final List<OfflineTargetFileRecord> files;

  String get targetPath => target.targetPath;

  OfflineTargetState get state => target.state;

  int get totalFiles => files.length;

  int get readyFiles =>
      files.where((file) => file.readiness == OfflineReadiness.ready).length;

  int get queuedFiles => files
      .where(
        (file) =>
            file.readiness == OfflineReadiness.queued ||
            file.readiness == OfflineReadiness.idle,
      )
      .length;

  int get activeFiles => files
      .where(
        (file) =>
            file.readiness == OfflineReadiness.downloading ||
            file.readiness == OfflineReadiness.verifying,
      )
      .length;

  int get errorFiles =>
      files.where((file) => file.readiness == OfflineReadiness.error).length;

  int get completeFolders => frontier
      .where((folder) => folder.state == OfflineTargetFrontierState.complete)
      .length;

  int get errorFolders => frontier
      .where((folder) => folder.state == OfflineTargetFrontierState.error)
      .length;

  bool get isReady => target.state == OfflineTargetState.ready;

  bool get hasWork =>
      frontier.any(
        (folder) =>
            folder.state == OfflineTargetFrontierState.pending ||
            folder.state == OfflineTargetFrontierState.scanning,
      ) ||
      files.any(
        (file) =>
            file.readiness != OfflineReadiness.ready &&
            file.readiness != OfflineReadiness.error,
      );

  /// Actual file progress when the server supplied a count, otherwise null.
  double? get progress {
    final allFilesReady = files.every(
      (file) => file.readiness == OfflineReadiness.ready,
    );
    if (target.scanComplete && allFilesReady) return 1;
    if (!target.scanComplete) return null;

    final estimate = target.estimateFiles;
    if (target.estimateHasUnknown || estimate == null) {
      if (totalFiles == 0) return null;
      return (readyFiles / totalFiles).clamp(0, 0.999999).toDouble();
    }
    if (estimate > 0) {
      return (readyFiles / estimate).clamp(0, 0.999999).toDouble();
    }
    if (totalFiles == 0) return null;
    return (readyFiles / totalFiles).clamp(0, 0.999999).toDouble();
  }

  String? get errorCode {
    for (final folder in frontier) {
      if (folder.errorCode != null) return folder.errorCode;
    }
    for (final file in files) {
      if (file.errorCode != null) return file.errorCode;
    }
    return null;
  }
}
