import 'dart:async';

import 'package:easy_cloud/features/offline/application/offline_file_index.dart';
import 'package:easy_cloud/features/offline/presentation/offline_availability_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'loads canonical paths and keeps only requested returned records',
    () async {
      final response = Completer<Map<String, OfflineFileRecord>>();
      final index = _FakeOfflineFileIndex((email, paths) {
        expect(email, 'reader@mail.ru');
        expect(paths, containsAll(['/docs/report.pdf', '/docs/notes.txt']));
        expect(paths, hasLength(2));
        return response.future;
      });
      final controller = OfflineAvailabilityController(
        index: index,
        email: 'reader@mail.ru',
      );
      addTearDown(controller.dispose);

      final loading = controller.load([
        'docs/report.pdf/',
        '/docs/report.pdf',
        'docs/notes.txt',
      ]);
      expect(controller.isLoading, isTrue);

      response.complete({
        '/docs/report.pdf': _record('/docs/report.pdf'),
        '/not-requested.txt': _record('/not-requested.txt'),
      });
      await loading;

      expect(controller.isLoading, isFalse);
      expect(controller.error, isNull);
      expect(controller.records.keys, ['/docs/report.pdf']);
      expect(controller.isDirectReady('docs/report.pdf/'), isTrue);
      expect(controller.isDirectReady('/not-requested.txt'), isFalse);
    },
  );

  test('suppresses stale responses from an older generation', () async {
    final first = Completer<Map<String, OfflineFileRecord>>();
    final second = Completer<Map<String, OfflineFileRecord>>();
    var calls = 0;
    final index = _FakeOfflineFileIndex((email, paths) {
      return calls++ == 0 ? first.future : second.future;
    });
    final controller = OfflineAvailabilityController(
      index: index,
      email: 'reader@mail.ru',
    );
    addTearDown(controller.dispose);

    final firstLoad = controller.load(['/old.txt']);
    final secondLoad = controller.load(['/new.txt']);
    first.complete({'/old.txt': _record('/old.txt')});
    await Future<void>.delayed(Duration.zero);
    expect(controller.isLoading, isTrue);
    expect(controller.isDirectReady('/old.txt'), isFalse);

    second.complete({'/new.txt': _record('/new.txt')});
    await Future.wait([firstLoad, secondLoad]);

    expect(controller.records.keys, ['/new.txt']);
    expect(controller.isLoading, isFalse);
  });

  test('preserves the last successful state while reloading', () async {
    final firstResponse = Completer<Map<String, OfflineFileRecord>>();
    final reloadResponse = Completer<Map<String, OfflineFileRecord>>();
    var calls = 0;
    final index = _FakeOfflineFileIndex((email, paths) {
      calls++;
      return calls == 1 ? firstResponse.future : reloadResponse.future;
    });
    final controller = OfflineAvailabilityController(
      index: index,
      email: 'reader@mail.ru',
    );
    addTearDown(controller.dispose);

    final firstLoad = controller.load(['/old.txt']);
    firstResponse.complete({'/old.txt': _record('/old.txt')});
    await firstLoad;

    final reload = controller.load(['/new.txt']);
    expect(controller.isLoading, isTrue);
    expect(controller.isDirectReady('/old.txt'), isTrue);
    expect(controller.isDirectReady('/new.txt'), isFalse);

    reloadResponse.complete({'/new.txt': _record('/new.txt')});
    await reload;

    expect(controller.isDirectReady('/old.txt'), isFalse);
    expect(controller.isDirectReady('/new.txt'), isTrue);
  });

  test('hides lookup errors and recovers on a later load', () async {
    final failed = Completer<Map<String, OfflineFileRecord>>();
    final recovered = Completer<Map<String, OfflineFileRecord>>();
    var calls = 0;
    final index = _FakeOfflineFileIndex((email, paths) {
      calls++;
      return calls == 1 ? failed.future : recovered.future;
    });
    final controller = OfflineAvailabilityController(
      index: index,
      email: 'reader@mail.ru',
    );
    addTearDown(controller.dispose);

    final firstLoad = controller.load(['/file.txt']);
    failed.completeError(StateError('private backend details'));
    await firstLoad;
    expect(controller.error, isNotNull);
    expect(controller.error, isNot(contains('private backend details')));
    expect(controller.isLoading, isFalse);

    final recovery = controller.load(['/file.txt']);
    expect(controller.error, isNull);
    recovered.complete({'/file.txt': _record('/file.txt')});
    await recovery;

    expect(controller.error, isNull);
    expect(controller.isDirectReady('/file.txt'), isTrue);
  });

  test('dispose makes a pending load harmless', () async {
    final response = Completer<Map<String, OfflineFileRecord>>();
    final index = _FakeOfflineFileIndex((email, paths) => response.future);
    final controller = OfflineAvailabilityController(
      index: index,
      email: 'reader@mail.ru',
    );
    var notifications = 0;
    controller.addListener(() => notifications++);

    final loading = controller.load(['/file.txt']);
    controller.dispose();
    controller.dispose();
    response.complete({'/file.txt': _record('/file.txt')});

    await loading;
    expect(controller.isDirectReady('/file.txt'), isFalse);
    expect(notifications, 1);
  });
}

final class _FakeOfflineFileIndex implements OfflineFileIndex {
  _FakeOfflineFileIndex(this._lookup);

  final Future<Map<String, OfflineFileRecord>> Function(
    String email,
    Iterable<String> paths,
  )
  _lookup;

  @override
  Future<void> upsert(String email, OfflineFileRecord record) async {}

  @override
  Future<List<OfflineFileRecord>> list(String email) async => const [];

  @override
  Future<Map<String, OfflineFileRecord>> lookup(
    String email,
    Iterable<String> paths,
  ) => _lookup(email, paths);

  @override
  Future<bool> hasHashReference(String email, String hash) async => false;

  @override
  Future<void> remove(String email, String path) async {}

  @override
  Future<void> clearAccount(String email) async {}

  @override
  Future<void> close() async {}
}

OfflineFileRecord _record(String path) => OfflineFileRecord(
  path: path,
  name: path.substring(path.lastIndexOf('/') + 1),
  hash: '00112233445566778899AABBCCDDEEFF00112233',
  size: 1,
  cachedAt: DateTime.utc(2025, 1, 1),
);
