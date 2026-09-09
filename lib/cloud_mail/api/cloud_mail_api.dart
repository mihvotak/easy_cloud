import 'dart:convert';

import '../../core/errors/cloud_failure.dart';
import '../../features/browser/domain/cloud_folder_page.dart';
import '../../features/browser/domain/cloud_node.dart';
import '../../features/browser/domain/cloud_sort.dart';
import '../transport/cloud_transport.dart';

final class CloudMailApi {
  const CloudMailApi(this._transport);

  final CloudTransport _transport;

  Future<CloudFolderPage> listFolder(
    String path, {
    required int offset,
    required int limit,
    required CloudSort sort,
  }) async {
    final response = await _transport.get(
      'folder',
      query: {
        'home': _normalizePath(path),
        'offset': '$offset',
        'limit': '$limit',
        'sort': jsonEncode({'type': sort.apiField, 'order': sort.apiOrder}),
      },
    );
    try {
      final envelope = response.json;
      if (envelope is! Map) throw const FormatException();
      final status = _asInt(envelope['status']);
      if (status != null && status >= 400) {
        throw CloudFailure(
          status == 404 ? CloudFailureType.notFound : CloudFailureType.service,
          status == 404
              ? 'Папка не найдена.'
              : 'Mail.ru вернул ошибку $status.',
          statusCode: status,
        );
      }
      final body = envelope['body'];
      if (body is! Map) throw const FormatException();
      final rawItems = body['list'];
      if (rawItems is! List) throw const FormatException();
      final count = body['count'];
      final files = count is Map ? _asInt(count['files']) : null;
      final folders = count is Map ? _asInt(count['folders']) : null;
      final items = rawItems
          .map((item) {
            if (item is! Map) throw const FormatException();
            return _mapNode(item);
          })
          .toList(growable: false);
      return CloudFolderPage(
        folder: _mapNode(body, fallbackName: path == '/' ? 'Облако' : null),
        items: items,
        totalCount: files != null && folders != null
            ? files + folders
            : offset + items.length + (items.length == limit ? 1 : 0),
        sort: _mapSort(body['sort']) ?? sort,
      );
    } on CloudFailure {
      rethrow;
    } on FormatException {
      throw const CloudFailure(
        CloudFailureType.invalidResponse,
        'Mail.ru вернул неизвестный формат папки.',
      );
    } catch (_) {
      throw const CloudFailure(
        CloudFailureType.invalidResponse,
        'Mail.ru вернул неизвестный формат папки.',
      );
    }
  }

  CloudNode _mapNode(Map<dynamic, dynamic> json, {String? fallbackName}) {
    final path = json['home'];
    final name = json['name'] ?? fallbackName;
    final type = json['type'];
    if (path is! String || path.isEmpty || name is! String || name.isEmpty) {
      throw const FormatException();
    }
    final count = json['count'];
    final mtime = _asInt(json['mtime']);
    return CloudNode(
      path: path,
      name: name,
      type: switch (type) {
        'file' => CloudNodeType.file,
        'folder' => CloudNodeType.folder,
        _ => CloudNodeType.unknown,
      },
      kind: json['kind'] as String?,
      size: _asInt(json['size']),
      modifiedAt: mtime == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(mtime * 1000, isUtc: true),
      hash: json['hash'] as String?,
      revision: _opaque(json['rev']),
      globalRevision: _opaque(json['grev']),
      tree: json['tree'] as String?,
      webLink: json['weblink'] as String?,
      virusScan: json['virus_scan'] as String?,
      fileCount: count is Map ? _asInt(count['files']) : null,
      folderCount: count is Map ? _asInt(count['folders']) : null,
    );
  }

  CloudSort? _mapSort(Object? value) {
    if (value is! Map) return null;
    final field = switch (value['type']) {
      'name' => CloudSortField.name,
      'size' => CloudSortField.size,
      'mtime' => CloudSortField.modifiedAt,
      _ => null,
    };
    final order = switch (value['order']) {
      'asc' => CloudSortOrder.ascending,
      'desc' => CloudSortOrder.descending,
      _ => null,
    };
    return field == null || order == null ? null : CloudSort(field, order);
  }

  void close() => _transport.close();
}

String _normalizePath(String path) {
  if (path.isEmpty || path == '/') return '/';
  return path.startsWith('/') ? path : '/$path';
}

int? _asInt(Object? value) => switch (value) {
  int number => number,
  String text => int.tryParse(text),
  _ => null,
};

String? _opaque(Object? value) => value?.toString();
