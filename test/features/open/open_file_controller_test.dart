import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_cloud/cloud_mail/probe/cloud_hash.dart';
import 'package:easy_cloud/features/browser/domain/cloud_node.dart';
import 'package:easy_cloud/features/download/application/download_repository.dart';
import 'package:easy_cloud/features/download/domain/download.dart';
import 'package:easy_cloud/features/editor/domain/editor_file.dart';
import 'package:easy_cloud/features/editor/domain/editor_save.dart';
import 'package:easy_cloud/features/open/application/file_opener.dart';
import 'package:easy_cloud/features/open/application/open_file_controller.dart';
import 'package:easy_cloud/features/open/domain/open_file_failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'a second tap cancels the old open and ignores its stale result',
    () async {
      final first = _FakeDownloadHandle();
      final second = _FakeDownloadHandle();
      final repository = _FakeDownloadRepository([first, second]);
      final opener = _RecordingFileOpener();
      final controller = OpenFileController(repository, opener);
      addTearDown(controller.dispose);

      final firstOpen = controller.open(_node('/first.txt', 100));
      first.emit(_progress(10, 100));
      await _settle();

      final secondOpen = controller.open(_node('/second.txt', 200));
      expect(first.cancelCalls, 1);
      expect(controller.activePath, '/second.txt');
      expect(controller.progressFor('/first.txt'), isNull);

      first.emit(_progress(99, 100));
      second.emit(_progress(50, 200));
      await _settle();
      expect(controller.progressFor('/second.txt')?.bytes, 50);
      expect(controller.progressFor('/first.txt'), isNull);

      first.complete(File('/first.txt'));
      await _settle();
      expect(opener.paths, isEmpty);

      second.complete(File('/second.txt'));
      await secondOpen;
      await firstOpen;
      expect(opener.paths, [File('/second.txt').absolute.path]);
      expect(opener.displayNames, ['second.txt']);
      expect(controller.activePath, isNull);
    },
  );

  test(
    'cancellation completes quietly and does not invoke the opener',
    () async {
      final handle = _FakeDownloadHandle();
      final repository = _FakeDownloadRepository([handle]);
      final opener = _RecordingFileOpener();
      final controller = OpenFileController(repository, opener);
      addTearDown(controller.dispose);

      final open = controller.open(_node('/report.pdf', 10));
      controller.cancel();
      handle.fail(const DownloadCancelled());

      await open;
      expect(opener.paths, isEmpty);
      expect(controller.activePath, isNull);
    },
  );

  test('real download failures are typed and safe', () async {
    final handle = _FakeDownloadHandle();
    final repository = _FakeDownloadRepository([handle]);
    final controller = OpenFileController(repository, _RecordingFileOpener());
    addTearDown(controller.dispose);

    final open = controller.open(_node('/report.pdf', 10));
    handle.fail(StateError('private cache path'));

    await expectLater(open, throwsA(isA<OpenFileFailure>()));
    try {
      await open;
    } on OpenFileFailure catch (failure) {
      expect(failure.type, OpenFileFailureType.download);
      expect(failure.message, OpenFileFailure.safeMessage);
      expect(failure.toString(), isNot(contains('private cache path')));
    }
  });

  test('save-as prepares through startOpen and reports progress', () async {
    final handle = _FakeDownloadHandle();
    final repository = _FakeDownloadRepository([handle]);
    final exporter = _RecordingFileExporter();
    final controller = OpenFileController(
      repository,
      _RecordingFileOpener(),
      exporter,
    );
    addTearDown(controller.dispose);

    final save = controller.saveAs(_node('/report.pdf', 100));
    handle.emit(_progress(50, 100));
    await _settle();
    expect(controller.progressFor('/report.pdf')?.bytes, 50);

    handle.complete(File('/cache/report.pdf'));
    await save;

    expect(repository.openStarts, 1);
    expect(repository.persistentStarts, 0);
    expect(exporter.paths, [File('/cache/report.pdf').absolute.path]);
    expect(exporter.displayNames, ['report.pdf']);
    expect(controller.activePath, isNull);
  });

  test('picker cancellation is quiet and clears foreground progress', () async {
    final handle = _FakeDownloadHandle();
    final exporter = _RecordingFileExporter(result: false);
    final controller = OpenFileController(
      _FakeDownloadRepository([handle]),
      _RecordingFileOpener(),
      exporter,
    );
    addTearDown(controller.dispose);

    final save = controller.saveAs(_node('/report.pdf', 1));
    handle.complete(File('/cache/report.pdf'));
    await save;

    expect(exporter.paths, hasLength(1));
    expect(controller.activePath, isNull);
    expect(controller.progress, isNull);
  });

  test('failed or stale save preparation never reaches exporter', () async {
    final failed = _FakeDownloadHandle();
    final stale = _FakeDownloadHandle();
    final replacement = _FakeDownloadHandle();
    final exporter = _RecordingFileExporter();
    final repository = _FakeDownloadRepository([failed, stale, replacement]);
    final controller = OpenFileController(
      repository,
      _RecordingFileOpener(),
      exporter,
    );
    addTearDown(controller.dispose);

    final failedSave = controller.saveAs(_node('/failed.txt', 1));
    failed.fail(StateError('private cache path'));
    await expectLater(failedSave, throwsA(isA<OpenFileFailure>()));
    expect(exporter.paths, isEmpty);

    final staleSave = controller.saveAs(_node('/stale.txt', 1));
    final newerOpen = controller.open(_node('/newer.txt', 1));
    expect(stale.cancelCalls, 1);
    stale.complete(File('/cache/stale.txt'));
    await _settle();
    expect(exporter.paths, isEmpty);

    // Settle the replacement operation without invoking an external opener.
    replacement.complete(File('/cache/newer.txt'));
    await newerOpen;
    await staleSave;
  });

  test(
    'reset invalidates a pending native open and dispose cancels the handle',
    () async {
      final first = _FakeDownloadHandle();
      final second = _FakeDownloadHandle();
      final repository = _FakeDownloadRepository([first, second]);
      final opener = _RecordingFileOpener(pending: true);
      final controller = OpenFileController(repository, opener);

      final firstOpen = controller.open(_node('/first.txt', 1));
      first.complete(File('/first.txt'));
      await _settle();
      expect(opener.paths, [File('/first.txt').absolute.path]);

      controller.reset();
      expect(controller.activePath, isNull);

      final secondOpen = controller.open(_node('/second.txt', 1));
      controller.dispose();
      expect(second.cancelCalls, 1);
      expect(repository.closeCalls, 0);

      second.fail(const DownloadCancelled());
      opener.completePending();
      await firstOpen;
      await secondOpen;
    },
  );

  test('prepares strict UTF-8 internally through startOpen only', () async {
    final root = await Directory.systemTemp.createTemp(
      'easy-cloud-editor-open',
    );
    addTearDown(() => root.delete(recursive: true));
    final bytes = <int>[0xef, 0xbb, 0xbf, ...utf8.encode('line\r\n🙂')];
    final file = File('${root.path}/object');
    await file.writeAsBytes(bytes);
    final node = CloudNode(
      path: '/docs/note.txt',
      name: 'note.txt',
      type: CloudNodeType.file,
      size: bytes.length,
      hash: calculateCloudHash(bytes),
      modifiedAt: DateTime.utc(2026, 1, 2),
      revision: 'rev-1',
      globalRevision: 'grev-1',
    );
    final handle = _FakeDownloadHandle();
    final repository = _FakeDownloadRepository([handle]);
    final opener = _RecordingFileOpener();
    final controller = OpenFileController(repository, opener);
    addTearDown(controller.dispose);

    final preparation = controller.prepareForEditor(node);
    handle.complete(file);
    final prepared = await preparation;

    expect(prepared, isNotNull);
    expect(prepared!.text, 'line\r\n🙂');
    expect(prepared.hasUtf8Bom, isTrue);
    expect(prepared.baseline.path, node.path);
    expect(prepared.baseline.hash, node.hash);
    expect(prepared.baseline.size, bytes.length);
    expect(prepared.baseline.revision, 'rev-1');
    expect(repository.openStarts, 1);
    expect(repository.persistentStarts, 0);
    expect(opener.paths, isEmpty);
  });

  test(
    'rejects malformed UTF-8 and oversized bytes before editor push',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'easy-cloud-editor-open',
      );
      addTearDown(() => root.delete(recursive: true));

      Future<EditorPreparationFailure> prepareFailure(List<int> bytes) async {
        final file = File('${root.path}/${bytes.length}');
        await file.writeAsBytes(bytes);
        final node = CloudNode(
          path: '/docs/note.txt',
          name: 'note.txt',
          type: CloudNodeType.file,
          size: bytes.length,
          hash: calculateCloudHash(bytes),
        );
        final handle = _FakeDownloadHandle();
        final controller = OpenFileController(
          _FakeDownloadRepository([handle]),
          _RecordingFileOpener(),
        );
        addTearDown(controller.dispose);
        final result = controller.prepareForEditor(node);
        handle.complete(file);
        try {
          await result;
        } on EditorPreparationFailure catch (failure) {
          return failure;
        }
        fail('expected preparation failure');
      }

      final malformed = await prepareFailure(const [0x98]);
      expect(malformed.type, EditorPreparationFailureType.malformedUtf8);

      final oversized = await prepareFailure(
        List<int>.filled(editorMaxBytes + 1, 0x61, growable: false),
      );
      expect(oversized.type, EditorPreparationFailureType.oversize);
    },
  );

  test('prepares malformed UTF-8 as Windows-1251 when possible', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-cp1251');
    addTearDown(() => root.delete(recursive: true));
    final bytes = <int>[0xcf, 0xf0, 0xe8, 0xe2, 0xe5, 0xf2];
    final file = File('${root.path}/note.txt');
    await file.writeAsBytes(bytes);
    final node = CloudNode(
      path: '/docs/note.txt',
      name: 'note.txt',
      type: CloudNodeType.file,
      size: bytes.length,
      hash: calculateCloudHash(bytes),
    );
    final handle = _FakeDownloadHandle();
    final controller = OpenFileController(
      _FakeDownloadRepository([handle]),
      _RecordingFileOpener(),
    );
    addTearDown(controller.dispose);

    final result = controller.prepareForEditor(node);
    handle.complete(file);
    final prepared = await result;

    expect(prepared?.text, 'Привет');
    expect(prepared?.encoding, EditorTextEncoding.windows1251);
  });
}

CloudNode _node(String path, int size) => CloudNode(
  path: path,
  name: path.substring(path.lastIndexOf('/') + 1),
  type: CloudNodeType.file,
  size: size,
);

DownloadProgress _progress(int bytes, int total) => DownloadProgress(
  phase: DownloadPhase.receiving,
  bytes: bytes,
  total: total,
  resumed: false,
);

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final class _RecordingFileOpener implements FileOpener {
  _RecordingFileOpener({this.pending = false});

  final bool pending;
  final paths = <String>[];
  final displayNames = <String>[];
  final _pending = <Completer<void>>[];

  @override
  Future<void> openFile(String absolutePath, String displayName) {
    paths.add(absolutePath);
    displayNames.add(displayName);
    if (!pending) return Future.value();
    final result = Completer<void>();
    _pending.add(result);
    return result.future;
  }

  void completePending() {
    for (final result in _pending) {
      if (!result.isCompleted) result.complete();
    }
  }
}

final class _RecordingFileExporter implements FileExporter {
  _RecordingFileExporter({this.result = true});

  final bool result;
  final paths = <String>[];
  final displayNames = <String>[];

  @override
  Future<bool> saveFileAs(String absolutePath, String displayName) async {
    paths.add(absolutePath);
    displayNames.add(displayName);
    return result;
  }
}

final class _FakeDownloadRepository implements DownloadRepository {
  _FakeDownloadRepository(this._handles);

  final List<_FakeDownloadHandle> _handles;
  int closeCalls = 0;
  int openStarts = 0;
  int persistentStarts = 0;
  _FakeDownloadHandle? lastHandle;

  @override
  DownloadHandle start(CloudNode node) {
    persistentStarts++;
    throw UnimplementedError();
  }

  @override
  DownloadHandle startOpen(CloudNode node) {
    openStarts++;
    return lastHandle = _handles.removeAt(0);
  }

  @override
  DownloadHandle startTarget(
    CloudNode node, {
    required String targetPath,
    required String expectedEmail,
    required String targetIncarnation,
  }) => throw UnimplementedError();

  @override
  Future<void> removeOffline(CloudNode node) async {}

  @override
  Future<void> removeTarget(
    String targetPath, {
    required String expectedEmail,
    required String targetIncarnation,
  }) async {}

  @override
  Future<void> reconcileAccountCache({required String expectedEmail}) async {}

  @override
  Future<void> close() async => closeCalls++;
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
}
