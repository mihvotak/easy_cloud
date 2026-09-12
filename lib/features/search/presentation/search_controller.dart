import 'package:flutter/foundation.dart';

import '../../../core/errors/cloud_failure.dart';
import '../../browser/domain/cloud_node.dart';
import '../../browser/presentation/cloud_connection_controller.dart';
import '../application/search_repository.dart';

final class SearchController extends ChangeNotifier {
  SearchController({
    required SearchRepository repository,
    this.path = '/',
    this.connectionController,
  }) : _repository = repository;

  static const minimumQueryLength = 2;

  final SearchRepository _repository;
  final String path;
  final CloudConnectionController? connectionController;

  List<CloudNode> results = const [];
  String query = '';
  bool isLoading = false;
  bool hasSearched = false;
  bool isQueryTooShort = false;
  CloudFailure? error;

  int _generation = 0;
  bool _disposed = false;

  Future<void> search(String value) async {
    final generation = ++_generation;
    final connectionEpoch = connectionController?.epoch;
    query = value.trim();
    hasSearched = true;
    isQueryTooShort = query.length < minimumQueryLength;
    isLoading = !isQueryTooShort;
    error = null;
    results = const [];
    _notifyListeners();

    if (isQueryTooShort) return;

    try {
      final found = await _repository.search(query, path: path);
      if (!_isCurrent(generation)) return;
      results = found;
      connectionController?.markOnline(expectedEpoch: connectionEpoch);
    } on CloudFailure catch (failure) {
      if (_isCurrent(generation)) {
        error = failure;
        connectionController?.observeListingFailure(
          failure,
          expectedEpoch: connectionEpoch,
        );
      }
    } catch (_) {
      if (_isCurrent(generation)) {
        error = const CloudFailure(
          CloudFailureType.service,
          'Не удалось выполнить поиск.',
        );
      }
    } finally {
      if (_isCurrent(generation)) {
        isLoading = false;
        _notifyListeners();
      }
    }
  }

  void clear() {
    _generation++;
    query = '';
    results = const [];
    isLoading = false;
    hasSearched = false;
    isQueryTooShort = false;
    error = null;
    _notifyListeners();
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

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
