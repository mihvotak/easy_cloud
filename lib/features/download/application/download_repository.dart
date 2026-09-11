import '../../browser/domain/cloud_node.dart';
import '../domain/download_handle.dart';

abstract interface class DownloadRepository {
  DownloadHandle start(CloudNode node);

  DownloadHandle startOpen(CloudNode node);

  /// Starts a target download only for the expected account and target
  /// incarnation. The implementation must bind the operation to the session
  /// epoch observed at this call and cancel it if that epoch changes.
  DownloadHandle startTarget(
    CloudNode node, {
    required String targetPath,
    required String expectedEmail,
    required String targetIncarnation,
  });

  Future<void> removeOffline(CloudNode node);

  /// Removes one target's durable ownership and unreferenced objects. A stale
  /// account or incarnation is a safe no-op/cancellation, never a mutation of
  /// a newer target at the same path.
  Future<void> removeTarget(
    String targetPath, {
    required String expectedEmail,
    required String targetIncarnation,
  });

  /// Reconciles unowned final CAS objects for the authenticated account.
  ///
  /// The implementation binds the operation to the normalized account and
  /// current session epoch at call time. A stale call must cancel before it
  /// can delete anything.
  Future<void> reconcileAccountCache({required String expectedEmail});

  Future<void> close();
}
