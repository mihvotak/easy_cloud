import 'dart:async';
import 'dart:io';

import 'package:easy_cloud/features/auth/application/auth_repository.dart';
import 'package:easy_cloud/features/auth/data/cloud_auth_api.dart';
import 'package:easy_cloud/features/auth/data/session_store.dart';
import 'package:easy_cloud/features/auth/domain/cloud_session.dart';
import 'package:easy_cloud/features/auth/presentation/auth_controller.dart';
import 'package:easy_cloud/features/browser/application/browser_repository.dart';
import 'package:easy_cloud/features/browser/domain/cloud_folder_page.dart';
import 'package:easy_cloud/features/browser/domain/cloud_node.dart';
import 'package:easy_cloud/features/browser/domain/cloud_sort.dart';
import 'package:easy_cloud/features/download/application/download_repository.dart';
import 'package:easy_cloud/features/download/domain/download_handle.dart';
import 'package:easy_cloud/features/download/domain/download_progress.dart';
import 'package:easy_cloud/features/download/presentation/download_controller.dart';
import 'package:easy_cloud/features/offline/application/offline_file_index.dart';
import 'package:easy_cloud/features/open/application/file_opener.dart';
import 'package:easy_cloud/features/open/application/open_file_controller.dart';
import 'package:easy_cloud/features/search/application/search_repository.dart';
import 'package:easy_cloud/features/search/presentation/search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows hint, validates query, then renders results', (
    tester,
  ) async {
    final response = Completer<List<CloudNode>>();
    final searchRepository = _SearchRepository(response.future);
    final dependencies = _Dependencies();
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          repository: searchRepository,
          browserRepository: dependencies.browserRepository,
          authController: dependencies.authController,
          downloadController: dependencies.downloadController,
          openFileController: dependencies.openFileController,
          offlineFileIndex: dependencies.offlineFileIndex,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Поиск в облаке'), findsOneWidget);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );

    await tester.enterText(find.byType(TextField), 'a');
    await tester.tap(find.byTooltip('Найти'));
    await tester.pump();
    expect(find.text('Слишком короткий запрос'), findsOneWidget);
    expect(searchRepository.queries, isEmpty);

    await tester.enterText(find.byType(TextField), 'photo');
    await tester.tap(find.byTooltip('Найти'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    response.complete([
      const CloudNode(
        path: '/Pictures/photo.jpg',
        name: 'photo.jpg',
        type: CloudNodeType.file,
        size: 2048,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('photo.jpg'), findsOneWidget);
    dependencies.dispose();
  });

  testWidgets('opens a search result through the foreground controller', (
    tester,
  ) async {
    final auth = AuthController(
      AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
    );
    final repository = _OpenDownloadRepository();
    final opener = _RecordingFileOpener();
    final opens = OpenFileController(repository, opener);
    final downloads = DownloadController(repository);
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          repository: _SearchRepository(
            Future.value(const [
              CloudNode(
                path: '/Pictures/photo.jpg',
                name: 'photo.jpg',
                type: CloudNodeType.file,
                size: 1024,
              ),
            ]),
          ),
          browserRepository: _BrowserRepository(),
          authController: auth,
          downloadController: downloads,
          openFileController: opens,
          offlineFileIndex: _NoopOfflineFileIndex(),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'photo');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    await tester.tap(find.text('photo.jpg'));
    await tester.pump();
    expect(repository.openStarts, 1);
    expect(repository.persistentStarts, 0);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    repository.handle.emit(
      const DownloadProgress(
        phase: DownloadPhase.receiving,
        bytes: 256,
        total: 1024,
        resumed: false,
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      .25,
    );

    repository.handle.complete(File('/cache/photo'));
    await tester.pumpAndSettle();
    expect(opener.paths, [File('/cache/photo').absolute.path]);

    await tester.pumpWidget(const SizedBox());
    opens.dispose();
    downloads.dispose();
    auth.dispose();
  });

  testWidgets('saves a search result from its context menu', (tester) async {
    final auth = AuthController(
      AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
    );
    final repository = _OpenDownloadRepository();
    final exporter = _RecordingFileExporter();
    final opens = OpenFileController(repository, _NoopFileOpener(), exporter);
    final downloads = DownloadController(repository);
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          repository: _SearchRepository(
            Future.value(const [
              CloudNode(
                path: '/Pictures/photo.jpg',
                name: 'photo.jpg',
                type: CloudNodeType.file,
                size: 1024,
              ),
            ]),
          ),
          browserRepository: _BrowserRepository(),
          authController: auth,
          downloadController: downloads,
          openFileController: opens,
          offlineFileIndex: _NoopOfflineFileIndex(),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'photo');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Действия для photo.jpg'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить как'));
    await tester.pump();
    expect(repository.openStarts, 1);
    expect(repository.persistentStarts, 0);

    repository.handle.complete(File('/cache/photo.jpg'));
    await tester.pumpAndSettle();
    expect(exporter.paths, [File('/cache/photo.jpg').absolute.path]);

    await tester.pumpWidget(const SizedBox());
    opens.dispose();
    downloads.dispose();
    auth.dispose();
  });

  testWidgets('opens a result folder and the parent folder of a file', (
    tester,
  ) async {
    final searchRepository = _SearchRepository(
      Future.value(const [
        CloudNode(
          path: '/Documents',
          name: 'Documents',
          type: CloudNodeType.folder,
        ),
        CloudNode(
          path: '/Pictures/photo.jpg',
          name: 'photo.jpg',
          type: CloudNodeType.file,
        ),
      ]),
    );
    final dependencies = _Dependencies();
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          repository: searchRepository,
          browserRepository: dependencies.browserRepository,
          authController: dependencies.authController,
          downloadController: dependencies.downloadController,
          openFileController: dependencies.openFileController,
          offlineFileIndex: dependencies.offlineFileIndex,
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'doc');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Documents'));
    await tester.pumpAndSettle();
    expect(dependencies.browserRepository.paths, ['/Documents']);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Действия для photo.jpg'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Инфо'));
    await tester.pumpAndSettle();
    expect(find.text('Открыть папку'), findsOneWidget);
    await tester.tap(find.text('Открыть папку'));
    await tester.pumpAndSettle();
    expect(dependencies.browserRepository.paths, ['/Documents', '/Pictures']);
    dependencies.dispose();
  });

  testWidgets('starts a file download from the search context menu', (
    tester,
  ) async {
    final dependencies = _Dependencies();
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          repository: _SearchRepository(
            Future.value(const [
              CloudNode(
                path: '/Pictures/photo.jpg',
                name: 'photo.jpg',
                type: CloudNodeType.file,
              ),
            ]),
          ),
          browserRepository: dependencies.browserRepository,
          authController: dependencies.authController,
          downloadController: dependencies.downloadController,
          openFileController: dependencies.openFileController,
          offlineFileIndex: dependencies.offlineFileIndex,
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'photo');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Действия для photo.jpg'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Работать оффлайн'));
    await tester.pump();

    expect(dependencies.downloadRepository.starts, 1);
    dependencies.dispose();
  });

  testWidgets('removes direct search availability and refreshes the index', (
    tester,
  ) async {
    final auth = _signedInAuth();
    final offline = _MutableOfflineFileIndex({
      '/Pictures/photo.jpg': _record('/Pictures/photo.jpg'),
    });
    final downloadRepository = _NoopDownloadRepository()
      ..onRemove = (node) async {
        offline.records.remove(node.path);
      };
    final downloads = DownloadController(downloadRepository);
    final searchRepository = _SearchRepository(
      Future.value(const [
        CloudNode(
          path: '/Pictures/photo.jpg',
          name: 'photo.jpg',
          type: CloudNodeType.file,
        ),
      ]),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          repository: searchRepository,
          browserRepository: _BrowserRepository(),
          authController: auth,
          downloadController: downloads,
          openFileController: _openFileController(),
          offlineFileIndex: offline,
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'photo');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.byTooltip('Доступен офлайн'), findsOneWidget);
    await tester.tap(find.byTooltip('Действия для photo.jpg'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Только онлайн'));
    await tester.pumpAndSettle();

    expect(downloadRepository.removeCalls, 1);
    expect(offline.lookupPaths, hasLength(2));
    expect(find.byTooltip('Доступен офлайн'), findsNothing);
    expect(find.byTooltip('Только онлайн'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    auth.dispose();
  });

  testWidgets(
    'shows a safe search error when removing offline availability fails',
    (tester) async {
      final auth = _signedInAuth();
      final offline = _MutableOfflineFileIndex({
        '/Pictures/photo.jpg': _record('/Pictures/photo.jpg'),
      });
      final downloadRepository = _NoopDownloadRepository()
        ..removeFailure = StateError('private filesystem path');
      final downloads = DownloadController(downloadRepository);
      await tester.pumpWidget(
        MaterialApp(
          home: SearchPage(
            repository: _SearchRepository(
              Future.value(const [
                CloudNode(
                  path: '/Pictures/photo.jpg',
                  name: 'photo.jpg',
                  type: CloudNodeType.file,
                ),
              ]),
            ),
            browserRepository: _BrowserRepository(),
            authController: auth,
            downloadController: downloads,
            openFileController: _openFileController(),
            offlineFileIndex: offline,
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'photo');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Действия для photo.jpg'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Только онлайн'));
      await tester.pumpAndSettle();

      expect(downloadRepository.removeCalls, 1);
      expect(find.text('Не удалось отключить офлайн-доступ.'), findsOneWidget);
      expect(find.text('private filesystem path'), findsNothing);
      expect(find.byTooltip('Доступен офлайн'), findsOneWidget);
      expect(offline.lookupPaths, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      auth.dispose();
    },
  );
}

OpenFileController _openFileController([
  DownloadRepository? repository,
  FileOpener? fileOpener,
  FileExporter? fileExporter,
]) => OpenFileController(
  repository ?? _NoopDownloadRepository(),
  fileOpener ?? _NoopFileOpener(),
  fileExporter,
);

final class _NoopFileOpener implements FileOpener {
  @override
  Future<void> openFile(String absolutePath, String displayName) async {}
}

final class _RecordingFileOpener implements FileOpener {
  final paths = <String>[];
  final displayNames = <String>[];

  @override
  Future<void> openFile(String absolutePath, String displayName) async {
    paths.add(absolutePath);
    displayNames.add(displayName);
  }
}

final class _RecordingFileExporter implements FileExporter {
  final paths = <String>[];
  final displayNames = <String>[];

  @override
  Future<bool> saveFileAs(String absolutePath, String displayName) async {
    paths.add(absolutePath);
    displayNames.add(displayName);
    return true;
  }
}

final class _SearchRepository implements SearchRepository {
  _SearchRepository(this.result);

  final Future<List<CloudNode>> result;
  final queries = <String>[];

  @override
  Future<List<CloudNode>> search(
    String query, {
    String path = '/',
    int limit = 100,
  }) {
    queries.add(query);
    return result;
  }
}

final class _BrowserRepository implements BrowserRepository {
  final paths = <String>[];

  @override
  Future<CloudFolderPage> listFolder(
    String path, {
    int offset = 0,
    int limit = 100,
    CloudSort sort = CloudSort.nameAscending,
  }) async {
    paths.add(path);
    return CloudFolderPage(
      folder: CloudNode(path: path, name: path, type: CloudNodeType.folder),
      items: const [],
      totalCount: 0,
      sort: sort,
    );
  }

  @override
  Future<void> close() async {}
}

final class _Dependencies {
  _Dependencies()
    : browserRepository = _BrowserRepository(),
      authController = AuthController(
        AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
      ),
      downloadRepository = _NoopDownloadRepository(),
      offlineFileIndex = _NoopOfflineFileIndex() {
    downloadController = DownloadController(downloadRepository);
    openFileController = OpenFileController(
      downloadRepository,
      _NoopFileOpener(),
    );
  }

  final _BrowserRepository browserRepository;
  final AuthController authController;
  final _NoopDownloadRepository downloadRepository;
  late final DownloadController downloadController;
  late final OpenFileController openFileController;
  final OfflineFileIndex offlineFileIndex;

  void dispose() {
    openFileController.dispose();
    downloadController.dispose();
    authController.dispose();
  }
}

final class _NoopOfflineFileIndex implements OfflineFileIndex {
  @override
  Future<void> upsert(String email, OfflineFileRecord record) async {}

  @override
  Future<List<OfflineFileRecord>> list(String email) async => const [];

  @override
  Future<Map<String, OfflineFileRecord>> lookup(
    String email,
    Iterable<String> paths,
  ) async => const {};

  @override
  Future<bool> hasHashReference(String email, String hash) async => false;

  @override
  Future<void> remove(String email, String path) async {}

  @override
  Future<void> clearAccount(String email) async {}

  @override
  Future<void> close() async {}
}

final class _MutableOfflineFileIndex implements OfflineFileIndex {
  _MutableOfflineFileIndex(this.records);

  final Map<String, OfflineFileRecord> records;
  final lookupPaths = <Set<String>>[];

  @override
  Future<void> upsert(String email, OfflineFileRecord record) async {
    records[record.path] = record;
  }

  @override
  Future<List<OfflineFileRecord>> list(String email) async =>
      records.values.toList(growable: false);

  @override
  Future<Map<String, OfflineFileRecord>> lookup(
    String email,
    Iterable<String> paths,
  ) async {
    final requested = paths.toSet();
    lookupPaths.add(requested);
    final found = <String, OfflineFileRecord>{};
    for (final path in requested) {
      final record = records[path];
      if (record != null) found[path] = record;
    }
    return found;
  }

  @override
  Future<bool> hasHashReference(String email, String hash) async =>
      records.values.any((record) => record.hash == hash.trim().toUpperCase());

  @override
  Future<void> remove(String email, String path) async {
    records.remove(path);
  }

  @override
  Future<void> clearAccount(String email) async => records.clear();

  @override
  Future<void> close() async {}
}

final class _NoopDownloadRepository implements DownloadRepository {
  @override
  DownloadHandle start(CloudNode node) {
    starts++;
    return _PendingDownloadHandle();
  }

  @override
  DownloadHandle startOpen(CloudNode node) => _PendingDownloadHandle();

  @override
  DownloadHandle startTarget(
    CloudNode node, {
    required String targetPath,
    required String expectedEmail,
    required String targetIncarnation,
  }) => _PendingDownloadHandle();

  int starts = 0;
  int removeCalls = 0;
  Object? removeFailure;
  Future<void> Function(CloudNode node)? onRemove;

  @override
  Future<void> removeOffline(CloudNode node) async {
    removeCalls++;
    if (removeFailure case final failure?) throw failure;
    final callback = onRemove;
    if (callback != null) await callback(node);
  }

  @override
  Future<void> removeTarget(
    String targetPath, {
    required String expectedEmail,
    required String targetIncarnation,
  }) async {}

  @override
  Future<void> reconcileAccountCache({required String expectedEmail}) async {}

  @override
  Future<void> close() async {}
}

final class _OpenDownloadRepository implements DownloadRepository {
  final handle = _ControllableDownloadHandle();
  int openStarts = 0;
  int persistentStarts = 0;

  @override
  DownloadHandle start(CloudNode node) {
    persistentStarts++;
    return handle;
  }

  @override
  DownloadHandle startOpen(CloudNode node) {
    openStarts++;
    return handle;
  }

  @override
  DownloadHandle startTarget(
    CloudNode node, {
    required String targetPath,
    required String expectedEmail,
    required String targetIncarnation,
  }) {
    return handle;
  }

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
  Future<void> close() async {}
}

final class _ControllableDownloadHandle implements DownloadHandle {
  _ControllableDownloadHandle()
    : _progress = StreamController<DownloadProgress>.broadcast(sync: true),
      _result = Completer<File>();

  final StreamController<DownloadProgress> _progress;
  final Completer<File> _result;

  @override
  Stream<DownloadProgress> get progress => _progress.stream;

  @override
  Future<File> get result => _result.future;

  @override
  void cancel() {}

  void emit(DownloadProgress progress) => _progress.add(progress);

  void complete(File file) => _result.complete(file);
}

final class _PendingDownloadHandle implements DownloadHandle {
  _PendingDownloadHandle() : result = Completer<File>().future;

  @override
  Stream<DownloadProgress> get progress =>
      const Stream<DownloadProgress>.empty();

  @override
  final Future<File> result;

  @override
  void cancel() {}
}

AuthController _signedInAuth() {
  final auth = AuthController(
    AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
  );
  auth.session = CloudSession(
    email: 'reader@mail.ru',
    accessToken: 'access',
    refreshToken: 'refresh',
    csrfToken: 'csrf',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
  );
  auth.status = AuthStatus.signedIn;
  return auth;
}

OfflineFileRecord _record(String path) => OfflineFileRecord(
  path: path,
  name: path.substring(path.lastIndexOf('/') + 1),
  hash: '00112233445566778899AABBCCDDEEFF00112233',
  size: 1,
  cachedAt: DateTime.utc(2025, 1, 1),
);

final class _NoopAuthApi implements AuthApi {
  @override
  Future<CloudSession> login({
    required String email,
    required String password,
  }) => throw UnimplementedError();

  @override
  Future<CloudSession> refresh(CloudSession session) =>
      throw UnimplementedError();

  @override
  void close() {}
}
