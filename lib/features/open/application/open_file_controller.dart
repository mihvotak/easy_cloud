import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../browser/domain/cloud_node.dart';
import '../../download/application/download_repository.dart';
import '../../download/domain/download.dart';
import '../domain/open_file_failure.dart';
import 'file_opener.dart';

/// The transient state rendered by a file tile while a foreground open is in
/// progress. It intentionally has no committed/ready state: opening a file
/// must not change persistent offline availability.
@immutable
final class OpenFileProgress {
  const OpenFileProgress({
    required this.phase,
    required this.bytes,
    required this.total,
    this.resumed = false,
  });

  final DownloadPhase phase;
  final int bytes;
  final int? total;
  final bool resumed;

  double? get fraction {
    final value = total;
    if (value == null || value <= 0) return null;
    return (bytes / value).clamp(0, 1).toDouble();
  }
}

/// Owns the single transient foreground open operation shared by Browser and
/// Search. Persistent offline downloads remain owned by [DownloadController].
final class OpenFileController extends ChangeNotifier {
  OpenFileController(
    this._repository,
    this._fileOpener, [
    FileExporter? fileExporter,
  ]) : _fileExporter = fileExporter ?? const _UnavailableFileExporter();

  final DownloadRepository _repository;
  final FileOpener _fileOpener;
  final FileExporter _fileExporter;

  DownloadHandle? _handle;
  StreamSubscription<DownloadProgress>? _progressSubscription;
  String? _activePath;
  OpenFileProgress? _progress;
  var _attempt = 0;
  var _disposed = false;

  String? get activePath => _activePath;

  OpenFileProgress? get progress => _progress;

  bool get isOpening => _activePath != null;

  /// Returns progress only for the currently active path.
  OpenFileProgress? progressFor(String path) =>
      _activePath == path ? _progress : null;

  /// Starts a new foreground open, cancelling and invalidating any previous
  /// operation first. Stale and cancelled operations complete silently.
  Future<void> open(CloudNode node) => _runForeground(node, saveAs: false);

  /// Prepares a verified transient CAS object and exports it through the
  /// platform picker. This intentionally uses [DownloadRepository.startOpen]
  /// rather than the persistent offline-download operation.
  ///
  /// A picker that the user cancels returns quietly. If a newer foreground
  /// action starts while Android owns the picker, the native result may still
  /// arrive because Android cannot cancel an already launched picker; the
  /// attempt check below discards that stale result and its UI effects.
  Future<void> saveAs(CloudNode node) => _runForeground(node, saveAs: true);

  Future<void> _runForeground(CloudNode node, {required bool saveAs}) async {
    if (_disposed || node.isFolder) return;

    _invalidateCurrent(notify: true);
    final attempt = _attempt;
    _activePath = node.path;
    _progress = OpenFileProgress(
      phase: DownloadPhase.resolving,
      bytes: 0,
      total: node.size,
    );
    notifyListeners();

    DownloadHandle? handle;
    StreamSubscription<DownloadProgress>? subscription;
    try {
      final startedHandle = _repository.startOpen(node);
      handle = startedHandle;
      if (!_isCurrent(attempt)) {
        startedHandle.cancel();
        return;
      }
      _handle = startedHandle;
      subscription = startedHandle.progress.listen((value) {
        if (!_isCurrent(attempt)) return;
        final phase = switch (value.phase) {
          DownloadPhase.resolving => DownloadPhase.resolving,
          DownloadPhase.receiving => DownloadPhase.receiving,
          DownloadPhase.verifying => DownloadPhase.verifying,
          // The repository may publish committed immediately before its
          // result future. Keep the transient tile bar in verifying state.
          DownloadPhase.committed => DownloadPhase.verifying,
        };
        _progress = OpenFileProgress(
          phase: phase,
          bytes: value.bytes,
          total: value.total,
          resumed: value.resumed,
        );
        notifyListeners();
      });
      _progressSubscription = subscription;

      final file = await startedHandle.result;
      if (!_isCurrent(attempt)) return;

      // The repository contract returns a verified CAS object. Keep the path
      // opaque to Flutter UI; Android validates the exact object shape again.
      if (saveAs) {
        final selected = await _fileExporter.saveFileAs(
          file.absolute.path,
          node.name,
        );
        if (!_isCurrent(attempt) || !selected) return;
      } else {
        await _fileOpener.openFile(file.absolute.path, node.name);
      }
    } catch (error, stackTrace) {
      if (!_isCurrent(attempt) || _isCancellation(error)) return;

      final failure = error is OpenFileFailure
          ? error.type == OpenFileFailureType.download && saveAs
                ? const OpenFileFailure(OpenFileFailureType.saveAs)
                : error
          : OpenFileFailure(
              saveAs
                  ? OpenFileFailureType.saveAs
                  : OpenFileFailureType.download,
            );
      _clearCurrent(attempt);
      if (!_isCurrent(attempt)) return;
      Error.throwWithStackTrace(failure, stackTrace);
    } finally {
      // A stale operation must not clean up resources belonging to the newer
      // attempt. Identity checks alone are insufficient if a repository test
      // double (or an implementation) happens to reuse a handle instance.
      if (_isCurrent(attempt)) {
        if (identical(_progressSubscription, subscription)) {
          _progressSubscription = null;
        }
        if (identical(_handle, handle)) _handle = null;
        if (_activePath != null) _clearCurrent(attempt);
      }
      await subscription?.cancel();
    }
  }

  /// Cancels the foreground open without changing persistent download state.
  void cancel() {
    if (_disposed) return;
    _invalidateCurrent(notify: true);
  }

  /// Invalidates the current operation, normally on an account transition.
  void reset() {
    if (_disposed) return;
    _invalidateCurrent(notify: true);
  }

  bool _isCurrent(int attempt) => !_disposed && _attempt == attempt;

  bool _isCancellation(Object error) =>
      error is DownloadCancelled ||
      error is DownloadFailure && error.isCancelled;

  void _invalidateCurrent({required bool notify}) {
    _attempt++;
    final handle = _handle;
    _handle = null;
    final subscription = _progressSubscription;
    _progressSubscription = null;
    _activePath = null;
    _progress = null;
    handle?.cancel();
    unawaited(subscription?.cancel());
    if (notify && !_disposed) notifyListeners();
  }

  void _clearCurrent(int attempt) {
    if (!_isCurrent(attempt)) return;
    _activePath = null;
    _progress = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _invalidateCurrent(notify: false);
    super.dispose();
  }
}

/// Keeps the two-argument controller construction useful for open-only test
/// compositions. Production and save-as compositions always inject the real
/// exporter; attempting to save without one is still a safe typed failure.
final class _UnavailableFileExporter implements FileExporter {
  const _UnavailableFileExporter();

  @override
  Future<bool> saveFileAs(String absolutePath, String displayName) =>
      Future<bool>.error(const OpenFileFailure(OpenFileFailureType.saveAs));
}
