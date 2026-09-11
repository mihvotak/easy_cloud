import 'package:flutter/foundation.dart';

import '../../../core/errors/cloud_failure.dart';
import '../application/browser_repository.dart';
import '../domain/cloud_folder_page.dart';
import '../domain/cloud_node.dart';
import '../domain/cloud_sort.dart';

final class BrowserController extends ChangeNotifier {
  BrowserController({required BrowserRepository repository, required this.path})
    : _repository = repository;

  static const pageSize = 100;

  final BrowserRepository _repository;
  final String path;

  List<CloudNode> items = const [];
  CloudNode? folder;
  CloudSort sort = CloudSort.nameAscending;
  int totalCount = 0;
  bool isInitialLoading = false;
  bool isRefreshing = false;
  bool isLoadingMore = false;
  CloudFailure? initialFailure;
  CloudFailure? loadMoreFailure;
  CloudFolderPageSource source = CloudFolderPageSource.remote;
  DateTime? cachedAt;
  bool snapshotComplete = true;
  CloudFailure? connectionFailure;
  int _generation = 0;
  int _nextOffset = 0;
  bool _disposed = false;

  bool get hasMore => snapshotComplete && _nextOffset < totalCount;

  Future<void> loadInitial() => _replace(initial: true);

  Future<void> refresh() => _replace(initial: false);

  Future<void> changeSort(CloudSort value) async {
    if (sort == value) return;
    sort = value;
    await _replace(initial: true);
  }

  Future<void> _replace({required bool initial}) async {
    final generation = ++_generation;
    isLoadingMore = false;
    if (initial) {
      isInitialLoading = true;
      items = const [];
      folder = null;
      _nextOffset = 0;
      totalCount = 0;
      source = CloudFolderPageSource.remote;
      cachedAt = null;
      snapshotComplete = true;
    } else {
      isRefreshing = true;
    }
    initialFailure = null;
    loadMoreFailure = null;
    connectionFailure = null;
    notifyListeners();
    try {
      final page = await _repository.listFolder(path, sort: sort);
      if (generation != _generation) return;
      _replacePage(page);
    } on CloudFailure catch (failure) {
      if (generation == _generation) initialFailure = failure;
    } catch (_) {
      if (generation == _generation) {
        initialFailure = const CloudFailure(
          CloudFailureType.service,
          'Не удалось открыть папку.',
        );
      }
    } finally {
      if (generation == _generation) {
        isInitialLoading = false;
        isRefreshing = false;
        _notifyListeners();
      }
    }
  }

  Future<void> loadMore() async {
    if (isInitialLoading || isRefreshing || isLoadingMore || !hasMore) return;
    final generation = _generation;
    final offset = _nextOffset;
    isLoadingMore = true;
    loadMoreFailure = null;
    _notifyListeners();
    try {
      final page = await _repository.listFolder(
        path,
        offset: offset,
        sort: sort,
      );
      if (generation != _generation) return;
      final knownPaths = items.map((item) => item.path).toSet();
      final additions = page.items
          .where((item) => knownPaths.add(item.path))
          .toList(growable: false);
      items = [...items, ...additions];
      _nextOffset = offset + page.items.length;
      folder = page.folder;
      totalCount = page.items.isEmpty ? _nextOffset : page.totalCount;
      sort = page.sort;
      _applyConnectionState(page);
    } on CloudFailure catch (failure) {
      if (generation == _generation) loadMoreFailure = failure;
    } catch (_) {
      if (generation == _generation) {
        loadMoreFailure = const CloudFailure(
          CloudFailureType.service,
          'Не удалось загрузить продолжение списка.',
        );
      }
    } finally {
      if (generation == _generation) {
        isLoadingMore = false;
        _notifyListeners();
      }
    }
  }

  Future<void> retryConnection() {
    if (isInitialLoading || isRefreshing) return Future<void>.value();
    return folder != null || items.isNotEmpty ? refresh() : loadInitial();
  }

  void _replacePage(CloudFolderPage page) {
    folder = page.folder;
    items = page.items;
    _nextOffset = page.items.length;
    totalCount = page.totalCount;
    sort = page.sort;
    _applyConnectionState(page);
  }

  void _applyConnectionState(CloudFolderPage page) {
    source = page.source;
    cachedAt = page.cachedAt;
    snapshotComplete = page.snapshotComplete;
    connectionFailure = page.source == CloudFolderPageSource.cache
        ? page.connectionFailure
        : null;
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
