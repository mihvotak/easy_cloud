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
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('opens a folder and returns to the parent', (tester) async {
    final repository = _TreeRepository();
    final auth = AuthController(
      AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserPage(repository: repository, authController: auth),
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
  });
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
