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
    await tester.pumpWidget(
      EasyCloudApp(
        authRepository: AuthRepository(api: _WidgetAuthApi(), store: store),
        browserRepository: _EmptyBrowserRepository(),
        searchRepository: _EmptySearchRepository(),
        downloadRepository: _NoopDownloadRepository(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Папка пуста'), findsOneWidget);
    expect(find.text('Подключить облако'), findsNothing);
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
}

CloudSession _session(DateTime expiresAt) => CloudSession(
  email: 'test@mail.ru',
  accessToken: 'access',
  refreshToken: 'refresh',
  csrfToken: 'csrf',
  expiresAt: expiresAt,
);

final class _WidgetAuthApi implements AuthApi {
  @override
  Future<CloudSession> login({
    required String email,
    required String password,
  }) async => _session(DateTime.now().add(const Duration(hours: 1)));

  @override
  Future<CloudSession> refresh(CloudSession session) async => session;

  @override
  void close() {}
}

final class _EmptyBrowserRepository implements BrowserRepository {
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
  void close() {}
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
  @override
  DownloadHandle start(CloudNode node) => throw UnimplementedError();

  @override
  void close() {}
}
