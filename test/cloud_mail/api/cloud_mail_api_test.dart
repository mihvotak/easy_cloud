import 'dart:convert';

import 'package:easy_cloud/cloud_mail/api/cloud_mail_api.dart';
import 'package:easy_cloud/cloud_mail/transport/cloud_transport.dart';
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
}

final class _FakeTransport implements CloudTransport {
  _FakeTransport(this.body);

  final Object body;
  Map<String, String> query = const {};

  @override
  Future<CloudResponse> get(
    String endpoint, {
    Map<String, String> query = const {},
  }) async {
    this.query = query;
    return CloudResponse(statusCode: 200, bytes: utf8.encode(jsonEncode(body)));
  }

  @override
  void close() {}
}
