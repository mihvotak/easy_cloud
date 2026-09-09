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
import 'package:easy_cloud/features/browser/presentation/browser_page.dart';
import 'package:easy_cloud/features/download/application/download_repository.dart';
import 'package:easy_cloud/features/download/domain/download_handle.dart';
import 'package:easy_cloud/features/download/domain/download_progress.dart';
import 'package:easy_cloud/features/download/presentation/download_controller.dart';
import 'package:easy_cloud/features/offline/application/offline_file_index.dart';
import 'package:easy_cloud/features/search/application/search_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('opens a folder and returns to the parent', (tester) async {
    final repository = _TreeRepository();
    final auth = AuthController(
      AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
    );
    final downloads = DownloadController(_NoopDownloadRepository());
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserPage(
          repository: repository,
          searchRepository: _NoopSearchRepository(),
          downloadController: downloads,
          offlineFileIndex: _NoopOfflineFileIndex(),
          authController: auth,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Documents'), findsOneWidget);
    await tester.tap(find.text('Documents'));
    await tester.pumpAndSettle();

    expect(find.text('readme.md'), findsOneWidget);
    expect(find.text('Documents'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('photo.jpg'), findsOneWidget);
    auth.dispose();
    downloads.dispose();
  });

  testWidgets('downloads a file from metadata and shows progress', (
    tester,
  ) async {
    final repository = _TreeRepository();
    final auth = AuthController(
      AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
    );
    final downloadRepository = _ControllableDownloadRepository();
    final downloads = DownloadController(downloadRepository);
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserPage(
          repository: repository,
          searchRepository: _NoopSearchRepository(),
          downloadController: downloads,
          offlineFileIndex: _NoopOfflineFileIndex(),
          authController: auth,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('photo.jpg'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Скачать для офлайн-доступа'));
    await tester.pump();
    expect(downloadRepository.starts, 1);

    downloadRepository.progress.add(
      const DownloadProgress(
        phase: DownloadPhase.receiving,
        bytes: 512,
        total: 1024,
        resumed: false,
      ),
    );
    await tester.pump();
    expect(find.text('512 Б из 1.0 КБ'), findsOneWidget);

    downloadRepository.result.complete(File('cached-photo'));
    await tester.pumpAndSettle();
    expect(downloads.stateFor('/photo.jpg')?.status, DownloadItemStatus.ready);
    expect(
      find.text('Файл доступен офлайн', skipOffstage: false),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    auth.dispose();
  });

  testWidgets('opens the offline files for the signed-in account', (
    tester,
  ) async {
    final store = MemorySessionStore()
      ..session = CloudSession(
        email: 'reader@mail.ru',
        accessToken: 'access',
        refreshToken: 'refresh',
        csrfToken: 'csrf',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      );
    final auth = AuthController(
      AuthRepository(api: _NoopAuthApi(), store: store),
    );
    await auth.initialize();
    final downloads = DownloadController(_NoopDownloadRepository());
    final offline = _NoopOfflineFileIndex();
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserPage(
          repository: _TreeRepository(),
          searchRepository: _NoopSearchRepository(),
          downloadController: downloads,
          offlineFileIndex: offline,
          authController: auth,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Офлайн-файлы'));
    await tester.pumpAndSettle();

    expect(find.text('Офлайн-файлы'), findsOneWidget);
    expect(find.text('Нет офлайн-файлов'), findsOneWidget);
    expect(offline.listedEmails, ['reader@mail.ru']);

    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    auth.dispose();
  });
}

final class _NoopDownloadRepository implements DownloadRepository {
  @override
  DownloadHandle start(CloudNode node) => throw UnimplementedError();

  @override
  void close() {}
}

final class _NoopOfflineFileIndex implements OfflineFileIndex {
  final listedEmails = <String>[];

  @override
  Future<void> upsert(String email, OfflineFileRecord record) async {}

  @override
  Future<List<OfflineFileRecord>> list(String email) async {
    listedEmails.add(email);
    return const [];
  }

  @override
  Future<void> remove(String email, String path) async {}

  @override
  Future<void> clearAccount(String email) async {}

  @override
  Future<void> close() async {}
}

final class _ControllableDownloadRepository implements DownloadRepository {
  final progress = StreamController<DownloadProgress>.broadcast();
  final result = Completer<File>();
  int starts = 0;

  @override
  DownloadHandle start(CloudNode node) {
    starts++;
    return _ControllableDownloadHandle(progress.stream, result.future);
  }

  @override
  void close() {
    progress.close();
  }
}

final class _ControllableDownloadHandle implements DownloadHandle {
  const _ControllableDownloadHandle(this.progress, this.result);

  @override
  final Stream<DownloadProgress> progress;

  @override
  final Future<File> result;

  @override
  void cancel() {}
}

final class _NoopSearchRepository implements SearchRepository {
  @override
  Future<List<CloudNode>> search(
    String query, {
    String path = '/',
    int limit = 100,
  }) async => const [];
}

final class _TreeRepository implements BrowserRepository {
  @override
  Future<CloudFolderPage> listFolder(
    String path, {
    int offset = 0,
    int limit = 100,
    CloudSort sort = CloudSort.nameAscending,
  }) async {
    final isRoot = path == '/';
    return CloudFolderPage(
      folder: CloudNode(
        path: path,
        name: isRoot ? 'Облако' : 'Documents',
        type: CloudNodeType.folder,
      ),
      items: isRoot
          ? const [
              CloudNode(
                path: '/Documents',
                name: 'Documents',
                type: CloudNodeType.folder,
              ),
              CloudNode(
                path: '/photo.jpg',
                name: 'photo.jpg',
                type: CloudNodeType.file,
              ),
            ]
          : const [
              CloudNode(
                path: '/Documents/readme.md',
                name: 'readme.md',
                type: CloudNodeType.file,
              ),
            ],
      totalCount: isRoot ? 2 : 1,
      sort: sort,
    );
  }

  @override
  void close() {}
}

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
