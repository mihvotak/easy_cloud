import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../cloud_mail/probe/cloud_hash.dart';
import '../../browser/domain/cloud_node.dart';
import '../../download/application/download_repository.dart';
import '../../download/domain/download.dart';
import '../../editor/domain/editor_file.dart';
import '../../editor/domain/editor_save.dart';
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
  Future<void> open(CloudNode node) async {
    await _runForeground(node, action: _ForegroundAction.open);
  }

  /// Downloads through the same foreground [DownloadRepository.startOpen]
  /// path as an external open, then strictly decodes the verified CAS object
  /// inside the application. It never invokes a platform opener/exporter and
  /// never creates a durable offline marker.
  Future<PreparedEditorFile?> prepareForEditor(CloudNode node) async =>
      await _runForeground(node, action: _ForegroundAction.prepareForEditor)
          as PreparedEditorFile?;

  /// Prepares a verified transient CAS object and exports it through the
  /// platform picker. This intentionally uses [DownloadRepository.startOpen]
  /// rather than the persistent offline-download operation.
  ///
  /// A picker that the user cancels returns quietly. If a newer foreground
  /// action starts while Android owns the picker, the native result may still
  /// arrive because Android cannot cancel an already launched picker; the
  /// attempt check below discards that stale result and its UI effects.
  Future<void> saveAs(CloudNode node) async {
    await _runForeground(node, action: _ForegroundAction.saveAs);
  }

  Future<Object?> _runForeground(
    CloudNode node, {
    required _ForegroundAction action,
  }) async {
    if (_disposed || node.isFolder) return null;

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
        return null;
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
      if (!_isCurrent(attempt)) return null;

      switch (action) {
        case _ForegroundAction.open:
          // The repository contract returns a verified CAS object. Keep the
          // path opaque to Flutter UI; Android validates the exact object
          // shape again.
          await _fileOpener.openFile(file.absolute.path, node.name);
          if (!_isCurrent(attempt)) return null;
        case _ForegroundAction.saveAs:
          final selected = await _fileExporter.saveFileAs(
            file.absolute.path,
            node.name,
          );
          if (!_isCurrent(attempt) || !selected) return null;
        case _ForegroundAction.prepareForEditor:
          return await _prepareEditorFile(node, file, startedHandle, attempt);
      }
      return null;
    } catch (error, stackTrace) {
      if (!_isCurrent(attempt) || _isCancellation(error)) return null;

      if (action == _ForegroundAction.prepareForEditor) {
        final failure = _preparationFailure(error);
        _clearCurrent(attempt);
        if (!_isCurrent(attempt)) return null;
        Error.throwWithStackTrace(failure, stackTrace);
      }

      final saveAs = action == _ForegroundAction.saveAs;
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
      if (!_isCurrent(attempt)) return null;
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

  Future<PreparedEditorFile> _prepareEditorFile(
    CloudNode requestedNode,
    File file,
    DownloadHandle handle,
    int attempt,
  ) async {
    _throwIfStale(attempt);
    late final int actualLength;
    try {
      // Check the filesystem before allocating a byte buffer. The bounded
      // stream below also protects against a file growing after this check.
      actualLength = await file.length();
    } on FileSystemException {
      throw const EditorPreparationFailure(
        EditorPreparationFailureType.disk,
        'Не удалось прочитать подготовленный файл.',
      );
    }
    _throwIfStale(attempt);
    if (actualLength > editorMaxBytes) {
      throw const EditorPreparationFailure(
        EditorPreparationFailureType.oversize,
        'Текстовый файл превышает лимит 10 МиБ.',
      );
    }

    final bytes = await _readBounded(file, attempt);
    _throwIfStale(attempt);
    if (bytes.length > editorMaxBytes) {
      throw const EditorPreparationFailure(
        EditorPreparationFailureType.oversize,
        'Текстовый файл превышает лимит 10 МиБ.',
      );
    }
    final finalLength = await file.length();
    _throwIfStale(attempt);
    if (finalLength > editorMaxBytes || finalLength != bytes.length) {
      throw const EditorPreparationFailure(
        EditorPreparationFailureType.integrity,
        'Проверка содержимого файла не пройдена.',
      );
    }

    final content = decodeEditorUtf8(bytes);
    final verifiedNode = handle is VerifiedDownloadHandle
        ? handle.verifiedNode
        : null;
    final remoteNode = verifiedNode ?? requestedNode;
    _verifyRemoteNode(requestedNode, remoteNode, bytes);
    final actualHash = calculateCloudHash(bytes);
    final expectedHash = remoteNode.hash!.trim().toUpperCase();
    if (actualHash != expectedHash) {
      throw const EditorPreparationFailure(
        EditorPreparationFailureType.integrity,
        'Проверка содержимого файла не пройдена.',
      );
    }

    final baseline = EditorSaveBaseline(
      path: remoteNode.path,
      hash: actualHash,
      size: bytes.length,
      modifiedAt: remoteNode.modifiedAt,
      revision: remoteNode.revision,
      globalRevision: remoteNode.globalRevision,
    );
    return PreparedEditorFile(
      file: file,
      remoteNode: remoteNode,
      text: content.text,
      hasUtf8Bom: content.hasUtf8Bom,
      baseline: baseline,
      bytes: bytes,
    );
  }

  Future<List<int>> _readBounded(File file, int attempt) async {
    final bytes = <int>[];
    try {
      await for (final chunk in file.openRead(0, editorMaxBytes + 1)) {
        _throwIfStale(attempt);
        final remaining = editorMaxBytes + 1 - bytes.length;
        if (remaining <= 0) break;
        if (chunk.length <= remaining) {
          bytes.addAll(chunk);
        } else {
          bytes.addAll(chunk.take(remaining));
          break;
        }
      }
    } on FileSystemException {
      throw const EditorPreparationFailure(
        EditorPreparationFailureType.disk,
        'Не удалось прочитать подготовленный файл.',
      );
    }
    return List<int>.unmodifiable(bytes);
  }

  void _verifyRemoteNode(
    CloudNode requestedNode,
    CloudNode remoteNode,
    List<int> bytes,
  ) {
    if (remoteNode.type != CloudNodeType.file || remoteNode.hash == null) {
      throw const EditorPreparationFailure(
        EditorPreparationFailureType.invalidResponse,
        'Mail.ru вернул неполные метаданные файла.',
      );
    }
    try {
      final requestedPath = normalizeEditorPath(requestedNode.path);
      final remotePath = normalizeEditorPath(remoteNode.path);
      if (requestedPath != remotePath ||
          !RegExp(r'^[0-9A-Fa-f]{40}$').hasMatch(remoteNode.hash!) ||
          (remoteNode.size != null && remoteNode.size != bytes.length)) {
        throw const EditorPreparationFailure(
          EditorPreparationFailureType.integrity,
          'Проверка содержимого файла не пройдена.',
        );
      }
    } on EditorPreparationFailure {
      rethrow;
    } on ArgumentError {
      throw const EditorPreparationFailure(
        EditorPreparationFailureType.invalidResponse,
        'Путь удалённого файла недействителен.',
      );
    }
  }

  void _throwIfStale(int attempt) {
    if (!_isCurrent(attempt)) {
      throw const EditorPreparationFailure(
        EditorPreparationFailureType.cancelled,
        'Операция подготовки отменена.',
      );
    }
  }

  EditorPreparationFailure _preparationFailure(Object error) {
    if (error is EditorPreparationFailure) return error;
    if (error is DownloadFailure) {
      return EditorPreparationFailure(
        switch (error.type) {
          DownloadFailureType.cancelled =>
            EditorPreparationFailureType.cancelled,
          DownloadFailureType.notFound => EditorPreparationFailureType.notFound,
          DownloadFailureType.integrity =>
            EditorPreparationFailureType.integrity,
          DownloadFailureType.invalidResponse =>
            EditorPreparationFailureType.invalidResponse,
          DownloadFailureType.disk => EditorPreparationFailureType.disk,
          _ => EditorPreparationFailureType.service,
        },
        switch (error.type) {
          DownloadFailureType.notFound => 'Удалённый файл недоступен.',
          DownloadFailureType.integrity =>
            'Проверка содержимого файла не пройдена.',
          DownloadFailureType.invalidResponse =>
            'Mail.ru вернул неполные метаданные файла.',
          DownloadFailureType.disk => 'Не удалось прочитать файл.',
          _ => 'Не удалось подготовить файл для встроенного редактора.',
        },
      );
    }
    return const EditorPreparationFailure(
      EditorPreparationFailureType.service,
      'Не удалось подготовить файл для встроенного редактора.',
    );
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
      error is DownloadFailure && error.isCancelled ||
      error is EditorPreparationFailure && error.isCancelled;

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

enum _ForegroundAction { open, saveAs, prepareForEditor }

/// Keeps the two-argument controller construction useful for open-only test
/// compositions. Production and save-as compositions always inject the real
/// exporter; attempting to save without one is still a safe typed failure.
final class _UnavailableFileExporter implements FileExporter {
  const _UnavailableFileExporter();

  @override
  Future<bool> saveFileAs(String absolutePath, String displayName) =>
      Future<bool>.error(const OpenFileFailure(OpenFileFailureType.saveAs));
}
