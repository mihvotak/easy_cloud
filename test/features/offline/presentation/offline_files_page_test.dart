import 'dart:async';

import 'package:easy_cloud/features/offline/application/offline_file_index.dart';
import 'package:easy_cloud/features/offline/presentation/offline_files_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows loading and then the account records', (tester) async {
    final response = Completer<List<OfflineFileRecord>>();
    final index = _FakeOfflineFileIndex((email) {
      expect(email, 'reader@mail.ru');
      return response.future;
    });

    await tester.pumpWidget(_app(index));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Офлайн-файлы'), findsOneWidget);

    response.complete([
      OfflineFileRecord(
        path: '/docs/report.pdf',
        name: 'report.pdf',
        hash: '00112233445566778899AABBCCDDEEFF00112233',
        size: 2048,
        cachedAt: DateTime.utc(2025, 1, 2, 3, 4),
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('/docs/report.pdf'), findsOneWidget);
    expect(find.text('Размер: 2.0 КБ'), findsOneWidget);
    expect(find.textContaining('Кэширован: '), findsOneWidget);
    expect(find.byIcon(Icons.insert_drive_file_rounded), findsOneWidget);
  });

  testWidgets('shows a clear empty state', (tester) async {
    final index = _FakeOfflineFileIndex((email) async => const []);

    await tester.pumpWidget(_app(index));
    await tester.pumpAndSettle();

    expect(find.text('Нет офлайн-файлов'), findsOneWidget);
    expect(
      find.text('Здесь появятся файлы, скачанные для офлайн-доступа.'),
      findsOneWidget,
    );
    expect(find.text('Повторить'), findsNothing);
  });

  testWidgets('shows a generic error and retries', (tester) async {
    final firstResponse = Completer<List<OfflineFileRecord>>();
    final secondResponse = Completer<List<OfflineFileRecord>>();
    var calls = 0;
    final index = _FakeOfflineFileIndex((email) {
      calls++;
      return calls == 1 ? firstResponse.future : secondResponse.future;
    });

    await tester.pumpWidget(_app(index));
    firstResponse.completeError(StateError('private backend details'));
    await tester.pumpAndSettle();

    expect(find.text('Не удалось загрузить офлайн-файлы'), findsOneWidget);
    expect(
      find.text('Список офлайн-файлов временно недоступен.'),
      findsOneWidget,
    );
    expect(find.textContaining('private backend details'), findsNothing);

    await tester.tap(find.text('Повторить'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    secondResponse.complete(const []);
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('Нет офлайн-файлов'), findsOneWidget);
  });

  testWidgets('passes the supplied email to the index', (tester) async {
    final index = _FakeOfflineFileIndex((email) async {
      expect(email, 'another-user@example.com');
      return const [];
    });

    await tester.pumpWidget(_app(index, email: 'another-user@example.com'));
    await tester.pumpAndSettle();

    expect(index.emails, ['another-user@example.com']);
  });
}

Widget _app(_FakeOfflineFileIndex index, {String email = 'reader@mail.ru'}) =>
    MaterialApp(
      home: OfflineFilesPage(index: index, email: email),
    );

final class _FakeOfflineFileIndex implements OfflineFileIndex {
  _FakeOfflineFileIndex(this._list);

  final Future<List<OfflineFileRecord>> Function(String email) _list;
  final emails = <String>[];

  @override
  Future<List<OfflineFileRecord>> list(String email) {
    emails.add(email);
    return _list(email);
  }

  @override
  Future<Map<String, OfflineFileRecord>> lookup(
    String email,
    Iterable<String> paths,
  ) async => const {};

  @override
  Future<bool> hasHashReference(String email, String hash) async => false;

  @override
  Future<void> clearAccount(String email) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> remove(String email, String path) async {}

  @override
  Future<void> upsert(String email, OfflineFileRecord record) async {}
}
