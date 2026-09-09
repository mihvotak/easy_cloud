import 'dart:async';

import 'download_failure.dart';

final class DownloadCancellationToken {
  final _cancellations = StreamController<void>.broadcast(sync: true);

  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  Stream<void> get cancellations => _cancellations.stream;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    if (!_cancellations.isClosed) _cancellations.add(null);
  }

  void throwIfCancelled() {
    if (_isCancelled) throw const DownloadCancelled();
  }

  Future<void> close() async {
    await _cancellations.close();
  }
}
