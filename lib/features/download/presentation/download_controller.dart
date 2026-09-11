import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/errors/cloud_failure.dart';
import '../../browser/domain/cloud_node.dart';
import '../application/download_repository.dart';
import '../domain/download.dart';

enum DownloadItemStatus {
  resolving,
  receiving,
  verifying,
  ready,
  failed,
  cancelled,
}

@immutable
final class DownloadItemState {
  const DownloadItemState({
    required this.status,
    this.bytes = 0,
    this.total,
    this.resumed = false,
    this.cacheHit = false,
    this.file,
    this.message,
  });

  final DownloadItemStatus status;
  final int bytes;
  final int? total;
  final bool resumed;
  final bool cacheHit;
  final File? file;
  final String? message;

  double? get fraction {
    final value = total;
    if (value == null || value <= 0) return null;
    return (bytes / value).clamp(0, 1);
  }
}

final class DownloadController extends ChangeNotifier {
  DownloadController(this._repository);

  final DownloadRepository _repository;
  final _states = <String, DownloadItemState>{};
  final _handles = <String, DownloadHandle>{};
  final _attempts = <String, int>{};
  final _subscriptions = <String, StreamSubscription<DownloadProgress>>{};
  final _offlineRemovals = <String, int>{};
  var _nextOfflineRemoval = 0;
  bool _disposed = false;

  DownloadItemState? stateFor(String path) => _states[path];

  void start(CloudNode node) {
    if (_disposed ||
        node.isFolder ||
        _handles.containsKey(node.path) ||
        _offlineRemovals.containsKey(node.path)) {
      return;
    }
    final attempt = (_attempts[node.path] ?? 0) + 1;
    _attempts[node.path] = attempt;
    final handle = _repository.start(node);
    _handles[node.path] = handle;
    _states[node.path] = const DownloadItemState(
      status: DownloadItemStatus.resolving,
    );
    notifyListeners();
    _subscriptions[node.path] = handle.progress.listen((progress) {
      if (!_isCurrent(node.path, attempt)) return;
      _states[node.path] = DownloadItemState(
        status: switch (progress.phase) {
          DownloadPhase.resolving => DownloadItemStatus.resolving,
          DownloadPhase.receiving => DownloadItemStatus.receiving,
          DownloadPhase.verifying => DownloadItemStatus.verifying,
          DownloadPhase.committed => DownloadItemStatus.ready,
        },
        bytes: progress.bytes,
        total: progress.total,
        resumed: progress.resumed,
        cacheHit: progress.cacheHit,
      );
      notifyListeners();
    });
    unawaited(_watch(node, handle, attempt));
  }

  /// Removes the direct offline binding after cancelling an active download
  /// for the same path. State is changed only after the repository confirms
  /// that the unpin completed successfully.
  Future<void> removeOffline(CloudNode node) async {
    if (_disposed || node.isFolder) return;
    final path = node.path;
    if (_offlineRemovals.containsKey(path)) return;
    final removal = ++_nextOfflineRemoval;
    _offlineRemovals[path] = removal;

    // Invalidate the watcher before cancelling so a late download completion
    // cannot publish a state change while the unpin is still in flight.
    _attempts[path] = (_attempts[path] ?? 0) + 1;
    final handle = _handles.remove(path);
    final subscription = _subscriptions.remove(path);
    handle?.cancel();
    unawaited(subscription?.cancel());

    try {
      await _repository.removeOffline(node);
    } catch (_) {
      if (_offlineRemovals[path] == removal) _offlineRemovals.remove(path);
      if (_disposed) return;
      rethrow;
    }

    if (_offlineRemovals[path] != removal) return;
    _offlineRemovals.remove(path);
    if (_disposed) return;
    if (_states.remove(path) != null) notifyListeners();
  }

  void retry(CloudNode node) {
    final status = _states[node.path]?.status;
    if (status == DownloadItemStatus.failed ||
        status == DownloadItemStatus.cancelled) {
      start(node);
    }
  }

  void cancel(String path) {
    final handle = _handles[path];
    if (handle == null) return;
    handle.cancel();
    final previous = _states[path];
    _states[path] = DownloadItemState(
      status: DownloadItemStatus.cancelled,
      bytes: previous?.bytes ?? 0,
      total: previous?.total,
      resumed: previous?.resumed ?? false,
      message: 'Загрузка отменяется…',
    );
    if (!_disposed) notifyListeners();
  }

  void cancelAll() {
    for (final handle in _handles.values.toList(growable: false)) {
      handle.cancel();
    }
  }

  void reset() {
    if (_disposed) return;
    _offlineRemovals.clear();
    for (final path in _handles.keys.toList(growable: false)) {
      _attempts[path] = (_attempts[path] ?? 0) + 1;
      _handles.remove(path)?.cancel();
      unawaited(_subscriptions.remove(path)?.cancel());
    }
    _states.clear();
    notifyListeners();
  }

  Future<void> _watch(
    CloudNode node,
    DownloadHandle handle,
    int attempt,
  ) async {
    try {
      final file = await handle.result;
      if (!_isCurrent(node.path, attempt)) return;
      final previous = _states[node.path];
      _states[node.path] = DownloadItemState(
        status: DownloadItemStatus.ready,
        bytes: previous?.bytes ?? node.size ?? 0,
        total: previous?.total ?? node.size,
        resumed: previous?.resumed ?? false,
        cacheHit: previous?.cacheHit ?? false,
        file: file,
      );
    } catch (error) {
      if (!_isCurrent(node.path, attempt)) return;
      final previous = _states[node.path];
      final cancelled = error is DownloadCancelled;
      _states[node.path] = DownloadItemState(
        status: cancelled
            ? DownloadItemStatus.cancelled
            : DownloadItemStatus.failed,
        bytes: previous?.bytes ?? 0,
        total: previous?.total,
        resumed: previous?.resumed ?? false,
        message: cancelled ? 'Загрузка отменена.' : _safeMessage(error),
      );
    } finally {
      if (_attempts[node.path] == attempt) {
        _handles.remove(node.path);
        final subscription = _subscriptions.remove(node.path);
        if (!_disposed) notifyListeners();
        await subscription?.cancel();
      }
    }
  }

  bool _isCurrent(String path, int attempt) =>
      !_disposed && _attempts[path] == attempt;

  String _safeMessage(Object error) => switch (error) {
    DownloadFailure failure => failure.message,
    CloudFailure failure => failure.message,
    _ => 'Не удалось скачать файл.',
  };

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _offlineRemovals.clear();
    cancelAll();
    for (final subscription in _subscriptions.values) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    // The repository is shared with OpenFileController and the recursive
    // offline queue. Its composition owner closes it only after those
    // controllers have stopped and the queue has settled.
    super.dispose();
  }
}
