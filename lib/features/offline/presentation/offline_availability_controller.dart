import 'package:flutter/foundation.dart';

import '../application/offline_file_index.dart';

/// Loads effective offline availability for a set of visible remote paths.
///
/// A target-aware index supplies direct, direct-target, inherited, and
/// online-only states. Older/direct-only indexes are still useful: they are
/// queried directly and the missing paths are represented as online-only.
/// While a load is in progress, the last successful result remains available.
final class OfflineAvailabilityController extends ChangeNotifier {
  OfflineAvailabilityController({
    required OfflineFileIndex index,
    required String email,
    OfflineTargetIndex? targetIndex,
  }) : _index = index,
       _email = email,
       _targetIndex =
           targetIndex ??
           (index is OfflineTargetIndex ? index as OfflineTargetIndex : null);

  static const _loadErrorMessage =
      'Не удалось проверить доступность офлайн-файлов.';

  final OfflineFileIndex _index;
  final String _email;
  final OfflineTargetIndex? _targetIndex;
  Map<String, OfflineFileRecord> _records = const {};
  Map<String, OfflineAvailabilityState> _states = const {};
  int _generation = 0;
  bool _disposed = false;

  bool isLoading = false;
  String? error;

  Map<String, OfflineFileRecord> get records => _records;

  /// Effective state keyed by canonical visible path.
  Map<String, OfflineAvailabilityState> get states => _states;

  /// Alias expressing the same state map in domain terms.
  Map<String, OfflineAvailabilityState> get availability => _states;

  /// Loads availability for [paths], ignoring stale responses from older
  /// loads. The supplied paths are canonicalized before the index is called.
  Future<void> load(Iterable<String> paths) async {
    final generation = ++_generation;
    if (_disposed) return;

    isLoading = true;
    error = null;
    _notifyListeners();

    try {
      final requestedPaths = _canonicalize(paths);
      final targetIndex = _targetIndex;
      final found = targetIndex == null
          ? await _lookupDirect(requestedPaths)
          : await targetIndex.lookupEffectiveAvailability(
              _email,
              requestedPaths,
            );
      if (!_isCurrent(generation)) return;
      _states = _filterRequested(found, requestedPaths);
      _records = _directRecords(_states);
    } catch (_) {
      if (_isCurrent(generation)) error = _loadErrorMessage;
    } finally {
      if (_isCurrent(generation)) {
        isLoading = false;
        _notifyListeners();
      }
    }
  }

  /// Returns whether the exact file path has a persisted direct record.
  bool isDirectReady(String path) {
    try {
      final normalizedPath = normalizeOfflineRemotePath(path);
      return _records.containsKey(normalizedPath);
    } on ArgumentError {
      return false;
    }
  }

  /// Returns the effective readiness for a loaded path, or null when it has
  /// not been requested yet.
  OfflineAvailabilityState? stateFor(String path) {
    try {
      return _states[normalizeOfflineRemotePath(path)];
    } on ArgumentError {
      return null;
    }
  }

  bool isReady(String path) => stateFor(path)?.isReady ?? false;

  Set<String> _canonicalize(Iterable<String> paths) {
    final canonicalPaths = <String>{};
    for (final path in paths) {
      canonicalPaths.add(normalizeOfflineRemotePath(path));
    }
    return canonicalPaths;
  }

  Future<Map<String, OfflineAvailabilityState>> _lookupDirect(
    Set<String> requestedPaths,
  ) async {
    final found = await _index.lookup(_email, requestedPaths);
    final states = <String, OfflineAvailabilityState>{};
    for (final path in requestedPaths) {
      final record = found[path];
      states[path] = record == null
          ? OfflineAvailabilityState(
              path: path,
              source: OfflineAvailabilitySource.onlineOnly,
              readiness: OfflineReadiness.idle,
            )
          : OfflineAvailabilityState(
              path: path,
              source: OfflineAvailabilitySource.direct,
              readiness: OfflineReadiness.ready,
              directRecord: record,
            );
    }
    return states;
  }

  Map<String, OfflineAvailabilityState> _filterRequested(
    Map<String, OfflineAvailabilityState> found,
    Set<String> requestedPaths,
  ) {
    final filtered = <String, OfflineAvailabilityState>{};
    for (final path in requestedPaths) {
      final state = _stateAt(found, path);
      filtered[path] =
          state ??
          OfflineAvailabilityState(
            path: path,
            source: OfflineAvailabilitySource.onlineOnly,
            readiness: OfflineReadiness.idle,
          );
    }
    return Map.unmodifiable(filtered);
  }

  OfflineAvailabilityState? _stateAt(
    Map<String, OfflineAvailabilityState> found,
    String requestedPath,
  ) {
    for (final entry in found.entries) {
      try {
        final path = normalizeOfflineRemotePath(entry.key);
        if (path != requestedPath) continue;
        final state = entry.value;
        if (state.path != requestedPath) {
          return OfflineAvailabilityState(
            path: requestedPath,
            source: state.source,
            readiness: state.readiness,
            targetPath: state.targetPath,
            directRecord: state.directRecord,
            targetFile: state.targetFile,
          );
        }
        return state;
      } on ArgumentError {
        // A malformed result from an implementation must not enter UI state.
      }
    }
    return null;
  }

  Map<String, OfflineFileRecord> _directRecords(
    Map<String, OfflineAvailabilityState> states,
  ) {
    final records = <String, OfflineFileRecord>{};
    for (final entry in states.entries) {
      if (entry.value.source != OfflineAvailabilitySource.direct) continue;
      final record = entry.value.directRecord;
      if (record != null) records[entry.key] = record;
    }
    return Map.unmodifiable(records);
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
