import 'dart:async';

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
import 'package:easy_cloud/features/download/presentation/download_controller.dart';
import 'package:easy_cloud/features/offline/application/offline_file_index.dart';
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

    await tester.tap(find.text('photo.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('Открыть папку'), findsOneWidget);
    await tester.tap(find.text('Открыть папку'));
    await tester.pumpAndSettle();
    expect(dependencies.browserRepository.paths, ['/Documents', '/Pictures']);
    dependencies.dispose();
  });
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
  void close() {}
}

final class _Dependencies {
  _Dependencies()
    : browserRepository = _BrowserRepository(),
      authController = AuthController(
        AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
      ),
      downloadController = DownloadController(_NoopDownloadRepository()),
      offlineFileIndex = _NoopOfflineFileIndex();

  final _BrowserRepository browserRepository;
  final AuthController authController;
  final DownloadController downloadController;
  final OfflineFileIndex offlineFileIndex;

  void dispose() {
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
  Future<void> remove(String email, String path) async {}

  @override
  Future<void> clearAccount(String email) async {}

  @override
  Future<void> close() async {}
}

final class _NoopDownloadRepository implements DownloadRepository {
  @override
  DownloadHandle start(CloudNode node) => throw UnimplementedError();

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
