import 'dart:async';
import 'dart:io';

import 'package:easy_cloud/features/browser/domain/cloud_node.dart';
import 'package:easy_cloud/features/download/application/download_repository.dart';
import 'package:easy_cloud/features/download/domain/download.dart';
import 'package:easy_cloud/features/download/presentation/download_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps ordered progress to a ready file', () async {
    final handle = _FakeDownloadHandle();
    final repository = _FakeDownloadRepository([handle]);
    final controller = DownloadController(repository);
    addTearDown(() async {
      controller.dispose();
      await repository.closeHandles();
    });
    const node = CloudNode(
      path: '/docs/report.pdf',
      name: 'report.pdf',
      type: CloudNodeType.file,
      size: 42,
    );
    final observedStatuses = <DownloadItemStatus>[];

    controller.start(node);
    controller.addListener(() {
      observedStatuses.add(controller.stateFor(node.path)!.status);
    });

    handle.emit(
      const DownloadProgress(
        phase: DownloadPhase.resolving,
        bytes: 0,
        total: 42,
        resumed: false,
      ),
    );
    expect(
      controller.stateFor(node.path)?.status,
      DownloadItemStatus.resolving,
    );

    handle.emit(
      const DownloadProgress(
        phase: DownloadPhase.receiving,
        bytes: 12,
        total: 42,
        resumed: true,
      ),
    );
    expect(
      controller.stateFor(node.path)?.status,
      DownloadItemStatus.receiving,
    );
    expect(controller.stateFor(node.path)?.bytes, 12);

    handle.emit(
      const DownloadProgress(
        phase: DownloadPhase.verifying,
        bytes: 42,
        total: 42,
        resumed: true,
      ),
    );
    expect(
      controller.stateFor(node.path)?.status,
      DownloadItemStatus.verifying,
    );

    handle.emit(
      const DownloadProgress(
        phase: DownloadPhase.committed,
        bytes: 42,
        total: 42,
        resumed: true,
        cacheHit: true,
      ),
    );
    expect(controller.stateFor(node.path)?.status, DownloadItemStatus.ready);
    expect(controller.stateFor(node.path)?.file, isNull);

    final file = File('report.pdf');
    handle.complete(file);
    await _settle();

    final state = controller.stateFor(node.path)!;
    expect(observedStatuses, [
      DownloadItemStatus.resolving,
      DownloadItemStatus.receiving,
      DownloadItemStatus.verifying,
      DownloadItemStatus.ready,
      DownloadItemStatus.ready,
    ]);
    expect(state.status, DownloadItemStatus.ready);
    expect(state.bytes, 42);
    expect(state.total, 42);
    expect(state.resumed, isTrue);
    expect(state.cacheHit, isTrue);
    expect(state.file, same(file));
    expect(state.fraction, 1.0);
  });

  test('does not start a duplicate download while one is active', () async {
    final handle = _FakeDownloadHandle();
    final repository = _FakeDownloadRepository([handle]);
    final controller = DownloadController(repository);
    addTearDown(() async {
      controller.dispose();
      await repository.closeHandles();
    });
    final node = _node('/docs/report.pdf', size: 10);

    controller.start(node);
    handle.emit(
      const DownloadProgress(
        phase: DownloadPhase.receiving,
        bytes: 4,
        total: 10,
        resumed: false,
      ),
    );
    controller.start(node);

    expect(repository.started, hasLength(1));
    expect(repository.started.single, same(handle));
    expect(
      controller.stateFor(node.path)?.status,
      DownloadItemStatus.receiving,
    );
    expect(controller.stateFor(node.path)?.bytes, 4);

    handle.complete(File('report.pdf'));
    await _settle();
  });

  test(
    'cancelling calls the handle and exposes a typed cancelled state',
    () async {
      final handle = _FakeDownloadHandle();
      final repository = _FakeDownloadRepository([handle]);
      final controller = DownloadController(repository);
      addTearDown(() async {
        controller.dispose();
        await repository.closeHandles();
      });
      final node = _node('/docs/report.pdf', size: 10);

      controller.start(node);
      handle.emit(
        const DownloadProgress(
          phase: DownloadPhase.receiving,
          bytes: 3,
          total: 10,
          resumed: false,
        ),
      );
      controller.cancel(node.path);

      expect(handle.cancelCalls, 1);
      expect(
        controller.stateFor(node.path)?.status,
        DownloadItemStatus.cancelled,
      );
      expect(controller.stateFor(node.path)?.message, 'Загрузка отменяется…');

      handle.fail(const DownloadCancelled());
      await _settle();

      final state = controller.stateFor(node.path)!;
      expect(state.status, DownloadItemStatus.cancelled);
      expect(state.message, 'Загрузка отменена.');
      expect(state.bytes, 3);
      expect(state.total, 10);
    },
  );

  test('a failed download can be retried with a new handle', () async {
    final first = _FakeDownloadHandle();
    final second = _FakeDownloadHandle();
    final repository = _FakeDownloadRepository([first, second]);
    final controller = DownloadController(repository);
    addTearDown(() async {
      controller.dispose();
      await repository.closeHandles();
    });
    final node = _node('/docs/report.pdf');

    controller.start(node);
    first.fail(const DownloadFailure(DownloadFailureType.network, 'offline'));
    await _settle();

    final failed = controller.stateFor(node.path)!;
    expect(failed.status, DownloadItemStatus.failed);
    expect(failed.message, 'offline');

    controller.retry(node);

    expect(repository.started, hasLength(2));
    expect(repository.started[0], same(first));
    expect(repository.started[1], same(second));
    expect(
      controller.stateFor(node.path)?.status,
      DownloadItemStatus.resolving,
    );

    final file = File('retried-report.pdf');
    second.complete(file);
    await _settle();

    final state = controller.stateFor(node.path)!;
    expect(state.status, DownloadItemStatus.ready);
    expect(state.file, same(file));
  });

  test('ignores stale completion progress from a previous attempt', () async {
    final first = _FakeDownloadHandle();
    final second = _FakeDownloadHandle();
    final repository = _FakeDownloadRepository([first, second]);
    final controller = DownloadController(repository);
    addTearDown(() async {
      controller.dispose();
      await repository.closeHandles();
    });
    final node = _node('/docs/report.pdf', size: 20);

    controller.start(node);
    first.fail(const DownloadFailure(DownloadFailureType.network, 'offline'));
    await _settle();
    controller.retry(node);

    second.emit(
      const DownloadProgress(
        phase: DownloadPhase.receiving,
        bytes: 2,
        total: 20,
        resumed: false,
      ),
    );
    first.emit(
      const DownloadProgress(
        phase: DownloadPhase.committed,
        bytes: 20,
        total: 20,
        resumed: false,
      ),
    );

    final state = controller.stateFor(node.path)!;
    expect(state.status, DownloadItemStatus.receiving);
    expect(state.bytes, 2);
    expect(state.total, 20);
    expect(state.file, isNull);

    final file = File('new-report.pdf');
    second.complete(file);
    await _settle();
    expect(controller.stateFor(node.path)?.file, same(file));
  });

  test('dispose cancels active downloads and closes the repository', () async {
    final handle = _FakeDownloadHandle();
    final repository = _FakeDownloadRepository([handle]);
    final controller = DownloadController(repository);
    addTearDown(() async {
      controller.dispose();
      await repository.closeHandles();
    });
    final node = _node('/docs/report.pdf');

    controller.start(node);
    controller.dispose();

    expect(handle.cancelCalls, 1);
    expect(repository.closeCalls, 1);

    handle.complete(File('disposed-report.pdf'));
    await _settle();
  });

  test('reset cancels active downloads and ignores stale completion', () async {
    final handle = _FakeDownloadHandle();
    final repository = _FakeDownloadRepository([handle]);
    final controller = DownloadController(repository);
    addTearDown(() async {
      controller.dispose();
      await repository.closeHandles();
    });
    final node = _node('/docs/report.pdf', size: 20);

    controller.start(node);
    handle.emit(
      const DownloadProgress(
        phase: DownloadPhase.receiving,
        bytes: 4,
        total: 20,
        resumed: false,
      ),
    );
    expect(controller.stateFor(node.path), isNotNull);

    controller.reset();

    expect(handle.cancelCalls, 1);
    expect(controller.stateFor(node.path), isNull);

    handle.emit(
      const DownloadProgress(
        phase: DownloadPhase.committed,
        bytes: 20,
        total: 20,
        resumed: false,
      ),
    );
    handle.complete(File('stale-report.pdf'));
    await _settle();

    expect(controller.stateFor(node.path), isNull);
  });
}

CloudNode _node(String path, {int? size}) => CloudNode(
  path: path,
  name: path.substring(path.lastIndexOf('/') + 1),
  type: CloudNodeType.file,
  size: size,
);

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final class _FakeDownloadRepository implements DownloadRepository {
  _FakeDownloadRepository([List<_FakeDownloadHandle>? handles])
    : _queued = handles == null ? <_FakeDownloadHandle>[] : [...handles];

  final List<_FakeDownloadHandle> _queued;
  final started = <_FakeDownloadHandle>[];
  int closeCalls = 0;

  @override
  DownloadHandle start(CloudNode node) {
    final handle = _queued.isEmpty
        ? _FakeDownloadHandle()
        : _queued.removeAt(0);
    started.add(handle);
    return handle;
  }

  @override
  void close() => closeCalls++;

  Future<void> closeHandles() async {
    for (final handle in started) {
      await handle.close();
    }
  }
}

final class _FakeDownloadHandle implements DownloadHandle {
  _FakeDownloadHandle()
    : _progress = StreamController<DownloadProgress>.broadcast(sync: true),
      _result = Completer<File>();

  final StreamController<DownloadProgress> _progress;
  final Completer<File> _result;
  int cancelCalls = 0;

  @override
  Stream<DownloadProgress> get progress => _progress.stream;

  @override
  Future<File> get result => _result.future;

  @override
  void cancel() => cancelCalls++;

  void emit(DownloadProgress progress) => _progress.add(progress);

  void complete(File file) => _result.complete(file);

  void fail(Object error) => _result.completeError(error, StackTrace.current);

  Future<void> close() => _progress.close();
}
