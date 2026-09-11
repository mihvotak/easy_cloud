import 'dart:async';

import 'package:easy_cloud/app/easy_cloud_app.dart';
import 'package:easy_cloud/features/auth/application/auth_repository.dart';
import 'package:easy_cloud/features/auth/data/cloud_auth_api.dart';
import 'package:easy_cloud/features/auth/data/session_store.dart';
import 'package:easy_cloud/features/auth/domain/cloud_session.dart';
import 'package:easy_cloud/features/browser/application/browser_repository.dart';
import 'package:easy_cloud/features/browser/domain/cloud_folder_page.dart';
import 'package:easy_cloud/features/browser/domain/cloud_node.dart';
import 'package:easy_cloud/features/browser/domain/cloud_sort.dart';
import 'package:easy_cloud/features/download/application/download_repository.dart';
import 'package:easy_cloud/features/download/domain/download_handle.dart';
import 'package:easy_cloud/features/offline/application/offline_file_index.dart';
import 'package:easy_cloud/features/search/application/search_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows login and connects an account', (tester) async {
    final repository = AuthRepository(
      api: _WidgetAuthApi(),
      store: MemorySessionStore(),
    );
    await tester.pumpWidget(
      EasyCloudApp(
        authRepository: repository,
        browserRepository: _EmptyBrowserRepository(),
        searchRepository: _EmptySearchRepository(),
        downloadRepository: _NoopDownloadRepository(),
        offlineFileIndex: _NoopOfflineFileIndex(),
        offlineTargetIndex: _NoopOfflineFileIndex(),
        offlineTargetQueueStore: _NoopOfflineFileIndex(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ваше облако.\nБез лишнего.'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email Mail.ru'),
      'test@mail.ru',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Пароль приложения'),
      'app-password',
    );
    await tester.tap(find.text('Подключить облако'));
    await tester.pumpAndSettle();

    expect(find.text('Папка пуста'), findsOneWidget);
  });

  testWidgets('restores an existing session without showing login', (
    tester,
  ) async {
    final store = MemorySessionStore()
      ..session = _session(DateTime.now().add(const Duration(hours: 1)));
    final download = _NoopDownloadRepository();
    await tester.pumpWidget(
      EasyCloudApp(
        authRepository: AuthRepository(api: _WidgetAuthApi(), store: store),
        browserRepository: _EmptyBrowserRepository(),
        searchRepository: _EmptySearchRepository(),
        downloadRepository: download,
        offlineFileIndex: _NoopOfflineFileIndex(),
        offlineTargetIndex: _NoopOfflineFileIndex(),
        offlineTargetQueueStore: _NoopOfflineFileIndex(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Папка пуста'), findsOneWidget);
    expect(find.text('Подключить облако'), findsNothing);
    expect(download.reconcileAccounts, contains('test@mail.ru'));
  });

  testWidgets('reconciles again when the app resumes', (tester) async {
    final store = MemorySessionStore()
      ..session = _session(DateTime.now().add(const Duration(hours: 1)));
    final download = _NoopDownloadRepository();
    await tester.pumpWidget(
      EasyCloudApp(
        authRepository: AuthRepository(api: _WidgetAuthApi(), store: store),
        browserRepository: _EmptyBrowserRepository(),
        searchRepository: _EmptySearchRepository(),
        downloadRepository: download,
        offlineFileIndex: _NoopOfflineFileIndex(),
        offlineTargetIndex: _NoopOfflineFileIndex(),
        offlineTargetQueueStore: _NoopOfflineFileIndex(),
      ),
    );
    await tester.pumpAndSettle();
    final initialCalls = download.reconcileCalls;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(download.reconcileCalls, greaterThan(initialCalls));
  });

  testWidgets('logout from a nested folder returns to login', (tester) async {
    final store = MemorySessionStore()
      ..session = _session(DateTime.now().add(const Duration(hours: 1)));
    await tester.pumpWidget(
      EasyCloudApp(
        authRepository: AuthRepository(api: _WidgetAuthApi(), store: store),
        browserRepository: _TreeBrowserRepository(),
        searchRepository: _EmptySearchRepository(),
        downloadRepository: _NoopDownloadRepository(),
        offlineFileIndex: _NoopOfflineFileIndex(),
        offlineTargetIndex: _NoopOfflineFileIndex(),
        offlineTargetQueueStore: _NoopOfflineFileIndex(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Documents'));
    await tester.pumpAndSettle();
    expect(find.text('private.txt'), findsOneWidget);

    await tester.tap(find.byTooltip('Аккаунт'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выйти'));
    await tester.pumpAndSettle();

    expect(find.text('Подключить облако'), findsOneWidget);
    expect(find.text('private.txt'), findsNothing);
  });

  testWidgets('awaits shared shutdown before closing dependent resources', (
    tester,
  ) async {
    final events = <String>[];
    final releaseDownloadClose = Completer<void>();
    final downloadCloseStarted = Completer<void>();
    final index = _NoopOfflineFileIndex(events);
    final auth = AuthRepository(
      api: _WidgetAuthApi(events),
      store: MemorySessionStore()
        ..session = _session(DateTime.now().add(const Duration(hours: 1))),
    );
    final download = _NoopDownloadRepository(
      closeEvents: events,
      closeGate: releaseDownloadClose,
      closeStarted: downloadCloseStarted,
    );

    await tester.pumpWidget(
      EasyCloudApp(
        authRepository: auth,
        browserRepository: _EmptyBrowserRepository(events),
        searchRepository: _EmptySearchRepository(),
        downloadRepository: download,
        offlineFileIndex: index,
        offlineTargetIndex: index,
        offlineTargetQueueStore: index,
      ),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await downloadCloseStarted.future;
    expect(events, ['download-start']);

    releaseDownloadClose.complete();
    for (var i = 0; i < 5 && !events.contains('offline'); i++) {
      await tester.pump();
    }

    expect(events.sublist(0, 4), [
      'download-start',
      'download-end',
      'browser',
      'offline',
    ]);
  });
}

CloudSession _session(DateTime expiresAt) => CloudSession(
  email: 'test@mail.ru',
  accessToken: 'access',
  refreshToken: 'refresh',
  csrfToken: 'csrf',
  expiresAt: expiresAt,
);

final class _WidgetAuthApi implements AuthApi {
  _WidgetAuthApi([this.closeEvents]);

  final List<String>? closeEvents;

  @override
  Future<CloudSession> login({
    required String email,
    required String password,
  }) async => _session(DateTime.now().add(const Duration(hours: 1)));

  @override
  Future<CloudSession> refresh(CloudSession session) async => session;

  @override
  Future<void> close() async {
    closeEvents?.add('auth');
  }
}

final class _EmptyBrowserRepository implements BrowserRepository {
  _EmptyBrowserRepository([this.closeEvents]);

  final List<String>? closeEvents;

  @override
  Future<CloudFolderPage> listFolder(
    String path, {
    int offset = 0,
    int limit = 100,
    CloudSort sort = CloudSort.nameAscending,
  }) async => CloudFolderPage(
    folder: const CloudNode(
      path: '/',
      name: 'Облако',
      type: CloudNodeType.folder,
    ),
    items: const [],
    totalCount: 0,
    sort: sort,
  );

  @override
  void close() {
    closeEvents?.add('browser');
  }
}

final class _TreeBrowserRepository implements BrowserRepository {
  @override
  Future<CloudFolderPage> listFolder(
    String path, {
    int offset = 0,
    int limit = 100,
    CloudSort sort = CloudSort.nameAscending,
  }) async => CloudFolderPage(
    folder: CloudNode(
      path: path,
      name: path == '/' ? 'Облако' : 'Documents',
      type: CloudNodeType.folder,
    ),
    items: path == '/'
        ? const [
            CloudNode(
              path: '/Documents',
              name: 'Documents',
              type: CloudNodeType.folder,
            ),
          ]
        : const [
            CloudNode(
              path: '/Documents/private.txt',
              name: 'private.txt',
              type: CloudNodeType.file,
            ),
          ],
    totalCount: 1,
    sort: sort,
  );

  @override
  void close() {}
}

final class _EmptySearchRepository implements SearchRepository {
  @override
  Future<List<CloudNode>> search(
    String query, {
    String path = '/',
    int limit = 100,
  }) async => const [];
}

final class _NoopDownloadRepository implements DownloadRepository {
  _NoopDownloadRepository({
    this.closeEvents,
    this.closeGate,
    this.closeStarted,
  });

  final List<String>? closeEvents;
  final Completer<void>? closeGate;
  final Completer<void>? closeStarted;
  final reconcileAccounts = <String>[];
  int reconcileCalls = 0;

  @override
  DownloadHandle start(CloudNode node) => throw UnimplementedError();

  @override
  DownloadHandle startOpen(CloudNode node) => throw UnimplementedError();

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
  Future<void> reconcileAccountCache({required String expectedEmail}) async {
    reconcileCalls++;
    reconcileAccounts.add(expectedEmail);
  }

  @override
  Future<void> close() async {
    closeEvents?.add('download-start');
    final started = closeStarted;
    if (started != null && !started.isCompleted) started.complete();
    final gate = closeGate;
    if (gate != null) await gate.future;
    closeEvents?.add('download-end');
  }
}

final class _NoopOfflineFileIndex
    implements OfflineTargetStorage, OfflineTargetQueueStore {
  _NoopOfflineFileIndex([this.closeEvents]);

  final List<String>? closeEvents;

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
  Future<void> close() async {
    closeEvents?.add('offline');
  }

  @override
  Future<void> upsertTarget(String email, OfflineTargetRecord target) async {}

  @override
  Future<OfflineTargetRecord?> getTarget(
    String email,
    String targetPath, {
    String? targetIncarnation,
  }) async => null;

  @override
  Future<List<OfflineTargetRecord>> listTargets(String email) async => const [];

  @override
  Future<void> upsertFrontier(
    String email,
    OfflineTargetFrontierRecord frontier,
  ) async {}

  @override
  Future<List<OfflineTargetFrontierRecord>> listFrontier(
    String email,
    String targetPath, {
    String? targetIncarnation,
  }) async => const [];

  @override
  Future<OfflineTargetFrontierRecord?> claimFrontier(
    String email,
    String targetPath, {
    required String targetIncarnation,
    String? folderPath,
  }) async => null;

  @override
  Future<void> updateFrontier(
    String email,
    OfflineTargetFrontierRecord frontier,
  ) async {}

  @override
  Future<void> recoverInProgress(
    String email, {
    String? targetPath,
    String? targetIncarnation,
  }) async {}

  @override
  Future<void> upsertTargetFile(
    String email,
    OfflineTargetFileRecord file,
  ) async {}

  @override
  Future<OfflineTargetFileRecord?> getTargetFile(
    String email,
    String targetPath,
    String filePath, {
    String? targetIncarnation,
  }) async => null;

  @override
  Future<OfflineTargetFileRecord?> lookupReadyTargetFile(
    String email,
    String filePath,
  ) async => null;

  @override
  Future<List<OfflineTargetFileRecord>> listTargetFiles(
    String email,
    String targetPath, {
    String? targetIncarnation,
  }) async => const [];

  @override
  Future<bool> markTargetFileReady(
    String email, {
    required String targetPath,
    required String filePath,
    required String targetIncarnation,
    required String hash,
    required int size,
    DateTime? modifiedAt,
    String? revision,
    String? globalRevision,
  }) async => false;

  @override
  Future<void> updateTargetFileReadiness(
    String email, {
    required String targetPath,
    required String filePath,
    required String targetIncarnation,
    required OfflineReadiness readiness,
    int? bytesDone,
    int? total,
    String? errorCode,
  }) async {}

  @override
  Future<OfflineTargetRemovalResult> removeTarget(
    String email,
    String targetPath, {
    required String targetIncarnation,
  }) async => OfflineTargetRemovalResult(
    target: null,
    removedFiles: const [],
    releasedHashes: const {},
    remainingReferences: const {},
  );

  @override
  Future<bool> hasHashReferenceOutsideTarget(
    String email,
    String hash, {
    required String targetPath,
    required String targetIncarnation,
  }) async => false;

  @override
  Future<Map<String, OfflineAvailabilityState>> lookupEffectiveAvailability(
    String email,
    Iterable<String> paths,
  ) async => const {};

  @override
  Future<void> createTargetWithRootIfNoOverlap(
    String email,
    OfflineTargetRecord target,
    OfflineTargetFrontierRecord root,
  ) async {}

  @override
  Future<void> updateTarget(String email, OfflineTargetRecord target) async {}

  @override
  Future<void> commitFrontierPage(
    String email, {
    required OfflineTargetFrontierRecord current,
    required OfflineTargetFrontierRecord updated,
    required Iterable<OfflineTargetFrontierRecord> discoveredFolders,
    required Iterable<OfflineTargetFileRecord> discoveredFiles,
  }) async {}
}
