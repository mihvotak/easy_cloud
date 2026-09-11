import 'package:easy_cloud/features/offline/domain/offline_target.dart';
import 'package:easy_cloud/features/offline/domain/offline_target_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('does not show a lower-bound estimate as complete before scanning', () {
    final summary = _summary(
      scanComplete: false,
      estimateFiles: 1,
      estimateHasUnknown: false,
      files: [_file(OfflineReadiness.ready)],
    );

    expect(summary.progress, isNull);
  });

  test('shows complete progress after a non-empty target is fully ready', () {
    final summary = _summary(
      scanComplete: true,
      state: OfflineTargetState.ready,
      files: [_file(OfflineReadiness.ready)],
    );

    expect(summary.progress, 1.0);
  });

  test('shows complete progress for an empty completed target', () {
    final summary = _summary(
      scanComplete: true,
      state: OfflineTargetState.ready,
    );

    expect(summary.progress, 1.0);
  });

  test(
    'partial and error targets never show 100 percent with failed files',
    () {
      final partial = _summary(
        scanComplete: true,
        state: OfflineTargetState.partial,
        estimateFiles: 1,
        files: [
          _file(OfflineReadiness.ready),
          _file(OfflineReadiness.error, path: '/target/failed.txt'),
        ],
      );
      final waiting = _summary(
        scanComplete: true,
        state: OfflineTargetState.waitingNetworkOrError,
        estimateFiles: 1,
        files: [
          _file(OfflineReadiness.ready),
          _file(OfflineReadiness.error, path: '/target/offline.txt'),
        ],
      );

      expect(partial.progress, lessThan(1.0));
      expect(waiting.progress, lessThan(1.0));
    },
  );
}

OfflineTargetSummary _summary({
  required bool scanComplete,
  OfflineTargetState state = OfflineTargetState.queued,
  int? estimateFiles,
  bool estimateHasUnknown = true,
  Iterable<OfflineTargetFileRecord> files = const [],
}) {
  final now = DateTime.utc(2026);
  return OfflineTargetSummary(
    target: OfflineTargetRecord(
      targetPath: '/target',
      targetIncarnation: 'test-incarnation',
      targetName: 'target',
      state: state,
      scanComplete: scanComplete,
      estimateFiles: estimateFiles,
      estimateHasUnknown: estimateHasUnknown,
      createdAt: now,
      updatedAt: now,
    ),
    frontier: const [],
    files: files,
  );
}

OfflineTargetFileRecord _file(
  OfflineReadiness readiness, {
  String path = '/target/file.txt',
}) => OfflineTargetFileRecord(
  targetPath: '/target',
  targetIncarnation: 'test-incarnation',
  filePath: path,
  name: path.substring(path.lastIndexOf('/') + 1),
  hash: readiness == OfflineReadiness.ready
      ? '00112233445566778899AABBCCDDEEFF00112233'
      : null,
  size: readiness == OfflineReadiness.ready ? 1 : null,
  readiness: readiness,
  bytesDone: readiness == OfflineReadiness.ready ? 1 : 0,
  updatedAt: DateTime.utc(2026),
);
