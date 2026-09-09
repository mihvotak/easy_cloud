import 'dart:convert';

import 'package:easy_cloud/cloud_mail/api/cloud_mail_api.dart';
import 'package:easy_cloud/cloud_mail/transport/cloud_transport.dart';
import 'package:easy_cloud/core/errors/cloud_failure.dart';
import 'package:easy_cloud/features/browser/domain/cloud_node.dart';
import 'package:easy_cloud/features/browser/domain/cloud_sort.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps folder metadata, children, revisions, and server sort', () async {
    final transport = _FakeTransport({
      'status': 200,
      'body': {
        'home': '/',
        'name': 'Root',
        'type': 'folder',
        'count': {'folders': 1, 'files': 1},
        'sort': {'type': 'mtime', 'order': 'desc'},
        'list': [
          {
            'home': '/Docs',
            'name': 'Docs',
            'type': 'folder',
            'rev': 14,
            'count': {'folders': 0, 'files': 3},
          },
          {
            'home': '/note.txt',
            'name': 'note.txt',
            'type': 'file',
            'size': 42,
            'mtime': 1700000000,
            'hash': 'HASH',
            'grev': '15',
          },
        ],
      },
    });

    final page = await CloudMailApi(transport).listFolder(
      '/',
      offset: 0,
      limit: 100,
      sort: const CloudSort(
        CloudSortField.modifiedAt,
        CloudSortOrder.descending,
      ),
    );

    expect(page.totalCount, 2);
    expect(page.sort.apiField, 'mtime');
    expect(page.sort.apiOrder, 'desc');
    expect(page.items.first.type, CloudNodeType.folder);
    expect(page.items.first.revision, '14');
    expect(page.items.first.fileCount, 3);
    expect(page.items.last.size, 42);
    expect(
      page.items.last.modifiedAt,
      DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
    );
    expect(transport.query['home'], '/');
    expect(transport.query['offset'], '0');
    expect(jsonDecode(transport.query['sort']!), {
      'type': 'mtime',
      'order': 'desc',
    });
  });

  test('rejects a malformed folder response', () async {
    final api = CloudMailApi(_FakeTransport({'status': 200, 'body': []}));

    await expectLater(
      api.listFolder('/', offset: 0, limit: 100, sort: CloudSort.nameAscending),
      throwsA(isA<Exception>()),
    );
  });

  test('stat sends normalized query and maps complete file metadata', () async {
    final transport = _FakeTransport({
      'status': 200,
      'body': {
        'home': '/Docs/report.pdf',
        'name': 'report.pdf',
        'type': 'file',
        'kind': 'text',
        'size': 42,
        'mtime': 1700000000,
        'hash': 'HASH',
        'rev': 7,
        'grev': '8',
        'tree': 'tree-id',
        'weblink': 'https://cloud.mail.ru/public/link',
        'virus_scan': 'clean',
        'count': {'files': 1, 'folders': 2},
      },
    });

    final node = await CloudMailApi(transport).stat('Docs/report.pdf');

    expect(transport.endpoint, 'file');
    expect(transport.query, {'home': '/Docs/report.pdf'});
    expect(transport.includeCsrfQuery, isFalse);
    expect(node.path, '/Docs/report.pdf');
    expect(node.name, 'report.pdf');
    expect(node.type, CloudNodeType.file);
    expect(node.kind, 'text');
    expect(node.size, 42);
    expect(
      node.modifiedAt,
      DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
    );
    expect(node.hash, 'HASH');
    expect(node.revision, '7');
    expect(node.globalRevision, '8');
    expect(node.tree, 'tree-id');
    expect(node.webLink, 'https://cloud.mail.ru/public/link');
    expect(node.virusScan, 'clean');
    expect(node.fileCount, 1);
    expect(node.folderCount, 2);
  });

  test('stat maps API envelope errors to CloudFailure', () async {
    final api = CloudMailApi(
      _FakeTransport({'status': 404, 'body': 'not found'}),
    );

    await expectLater(
      api.stat('missing.txt'),
      throwsA(
        isA<CloudFailure>()
            .having(
              (failure) => failure.type,
              'type',
              CloudFailureType.notFound,
            )
            .having((failure) => failure.statusCode, 'statusCode', 404)
            .having((failure) => failure.message, 'message', 'Файл не найден.'),
      ),
    );
  });

  test('stat rejects a non-object metadata body with CloudFailure', () async {
    final api = CloudMailApi(_FakeTransport({'status': 200, 'body': []}));

    await expectLater(
      api.stat('report.pdf'),
      throwsA(
        isA<CloudFailure>()
            .having(
              (failure) => failure.type,
              'type',
              CloudFailureType.invalidResponse,
            )
            .having(
              (failure) => failure.message,
              'message',
              'Mail.ru вернул неизвестный формат метаданных файла.',
            ),
      ),
    );
  });

  test('search sends legacy query and maps nodes', () async {
    final transport = _FakeTransport({
      'status': 200,
      'body': {
        'list': [
          {
            'home': '/Docs/report.pdf',
            'name': 'report.pdf',
            'type': 'file',
            'size': 42,
            'rev': 7,
          },
        ],
      },
    });

    final results = await CloudMailApi(
      transport,
    ).search('  report  ', path: 'Docs', limit: 25);

    expect(transport.endpoint, 'folder/find');
    expect(transport.query, {'q': 'report', 'path': '/Docs', 'limit': '25'});
    expect(transport.includeCsrfQuery, isTrue);
    expect(results, hasLength(1));
    expect(results.single.name, 'report.pdf');
    expect(results.single.type, CloudNodeType.file);
    expect(results.single.size, 42);
    expect(results.single.revision, '7');
  });

  test('empty search does not call transport', () async {
    final transport = _FakeTransport({'status': 500});

    final results = await CloudMailApi(transport).search('  \n ');

    expect(results, isEmpty);
    expect(transport.calls, 0);
  });

  test('search maps API envelope errors to CloudFailure', () async {
    final api = CloudMailApi(
      _FakeTransport({'status': 404, 'body': 'not found'}),
    );

    await expectLater(
      api.search('report'),
      throwsA(
        isA<CloudFailure>()
            .having(
              (failure) => failure.type,
              'type',
              CloudFailureType.notFound,
            )
            .having((failure) => failure.statusCode, 'statusCode', 404),
      ),
    );
  });
}

final class _FakeTransport implements CloudTransport {
  _FakeTransport(this.body);

  final Object body;
  int calls = 0;
  String? endpoint;
  Map<String, String> query = const {};
  bool includeCsrfQuery = false;

  @override
  Future<CloudResponse> get(
    String endpoint, {
    Map<String, String> query = const {},
    bool includeCsrfQuery = false,
  }) async {
    calls++;
    this.endpoint = endpoint;
    this.query = query;
    this.includeCsrfQuery = includeCsrfQuery;
    return CloudResponse(statusCode: 200, bytes: utf8.encode(jsonEncode(body)));
  }

  @override
  void close() {}
}
