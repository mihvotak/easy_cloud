import 'package:flutter/foundation.dart';

import '../../../core/errors/cloud_failure.dart';
import '../domain/cloud_folder_page.dart';

/// Session-scoped connectivity state shared by every cloud-facing route.
///
/// A cached page is useful content, but it is not evidence that the cloud is
/// reachable. Only a remote response can clear the offline state.
final class CloudConnectionController extends ChangeNotifier {
  CloudFailure? _failure;
  var _epoch = 0;
  var _disposed = false;

  CloudFailure? get failure => _failure;

  bool get isOffline => _failure != null;

  int get epoch => _epoch;

  void markOffline([CloudFailure? failure]) {
    if (_disposed) return;
    final next =
        failure ??
        const CloudFailure(
          CloudFailureType.network,
          'Нет соединения с облаком.',
        );
    if (_sameFailure(_failure, next)) return;
    _failure = next;
    _notifyListeners();
  }

  void markOnline({int? expectedEpoch}) {
    if (_disposed) return;
    if (expectedEpoch != null && expectedEpoch != _epoch) return;
    if (_failure == null) return;
    _failure = null;
    _notifyListeners();
  }

  void reset() {
    if (_disposed) return;
    _epoch++;
    markOnline();
  }

  void observeFolderPage(CloudFolderPage page, {int? expectedEpoch}) {
    if (_disposed || expectedEpoch != null && expectedEpoch != _epoch) {
      return;
    }
    if (page.source == CloudFolderPageSource.cache) {
      markOffline(page.connectionFailure);
    } else {
      markOnline(expectedEpoch: expectedEpoch);
    }
  }

  void observeListingFailure(Object error, {int? expectedEpoch}) {
    if (_disposed || expectedEpoch != null && expectedEpoch != _epoch) {
      return;
    }
    if (error is CloudFailure &&
        (error.type == CloudFailureType.network ||
            error.type == CloudFailureType.timeout)) {
      markOffline(error);
    }
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  bool _sameFailure(CloudFailure? left, CloudFailure right) =>
      left?.type == right.type &&
      left?.message == right.message &&
      left?.statusCode == right.statusCode;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
