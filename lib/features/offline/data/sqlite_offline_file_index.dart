import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;

import '../../../local/cache/application_cache_root.dart';
import '../../../local/cache/content_addressed_file_cache.dart';
import '../../browser/domain/cloud_folder_page.dart';
import '../../browser/domain/cloud_node.dart';
import '../../browser/domain/cloud_sort.dart';
import '../application/offline_file_index.dart';

/// SQLite-backed implementation of [OfflineFileIndex].
///
/// The database is opened on the first operation, not in the constructor.
/// Account identity is represented only by [accountCacheKey]; raw email
/// addresses and credentials are never written to SQLite.
final class SqliteOfflineFileIndex
    implements
        OfflineTargetStorage,
        OfflineTargetQueueStore,
        CloudMetadataCache,
        TransientObjectIndex,
        ConditionalOfflineFileOwnership,
        ConditionalOfflineTargetOwnership {
  SqliteOfflineFileIndex({
    CacheRootProvider? rootProvider,
    sqflite.DatabaseFactory? databaseFactory,
  }) : _rootProvider = rootProvider ?? const ApplicationCacheRoot(),
       _databaseFactory = databaseFactory ?? sqflite.databaseFactory;

  static const int schemaVersion = 6;
  static const String databaseFileName = 'offline_file_index.sqlite';
  static const String tableName = 'offline_files';
  static const String transientObjectsTableName = 'transient_objects';
  static const String targetsTableName = 'offline_targets';
  static const String targetFrontierTableName = 'offline_target_frontier';
  static const String targetFilesTableName = 'offline_target_files';
  static const String snapshotGenerationsTableName =
      'cloud_folder_snapshot_generations';
  static const String snapshotHeadsTableName = 'cloud_folder_snapshot_heads';
  static const String snapshotChildrenTableName =
      'cloud_folder_snapshot_children';

  static const _cacheDirectoryName = 'cloud_cache';
  static const _cachedAtIndexName = 'offline_files_account_cached_at_idx';
  static const _hashIndexName = 'offline_files_account_hash_idx';
  static const _transientLruIndexName = 'transient_objects_account_lru_idx';
  // Keep one account argument plus the path arguments well below SQLite's
  // usual 999-variable limit.
  static const _lookupChunkSize = 500;
  static const _snapshotGenerationsIndexName =
      'cloud_folder_snapshot_generations_account_path_idx';
  static const _snapshotHeadsIndexName =
      'cloud_folder_snapshot_heads_generation_idx';
  static const _snapshotChildrenIndexName =
      'cloud_folder_snapshot_children_account_path_generation_idx';
  static const _targetUpdatedAtIndexName =
      'offline_targets_account_updated_at_idx';
  static const _targetFrontierClaimIndexName =
      'offline_target_frontier_account_target_state_sequence_idx';
  static const _targetFilesPathIndexName =
      'offline_target_files_account_file_path_target_idx';
  static const _targetFilesHashIndexName =
      'offline_target_files_account_hash_readiness_idx';

  final CacheRootProvider _rootProvider;
  final sqflite.DatabaseFactory _databaseFactory;
  Future<sqflite.Database>? _databaseFuture;
  Future<void>? _closeFuture;
  bool _closed = false;

  @override
  Future<void> upsert(String email, OfflineFileRecord record) async {
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    await database.transaction((transaction) async {
      await transaction.insert(
        tableName,
        _toRow(accountKey, record),
        conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
      );
      // A persistent binding owns the object. It must not also count against
      // the transient LRU, and doing this in the same transaction prevents a
      // crash between the binding and transient-row updates.
      await transaction.delete(
        transientObjectsTableName,
        where:
            "account_key = ? AND length(hash) = 40 AND UPPER(hash) = ? "
            "AND UPPER(hash) NOT GLOB '*[^0-9A-F]*'",
        whereArgs: [accountKey, normalizeCloudHash(record.hash)],
      );
    });
  }

  @override
  Future<bool> updateDirectIfMatches(
    String email, {
    required String path,
    required String expectedHash,
    required OfflineFileRecord replacement,
  }) async {
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final normalizedPath = normalizeOfflineRemotePath(path);
    final normalizedExpectedHash = normalizeCloudHash(expectedHash);
    if (replacement.path != normalizedPath) {
      throw ArgumentError.value(
        replacement.path,
        'replacement.path',
        'Replacement path must match the conditional path.',
      );
    }
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    return database.transaction((transaction) async {
      final rows = await transaction.query(
        tableName,
        where: 'account_key = ? AND path = ?',
        whereArgs: [accountKey, normalizedPath],
        limit: 2,
      );
      if (rows.length > 1) {
        throw StateError('Offline file primary key is malformed.');
      }
      if (rows.isEmpty) return false;
      final current = _fromRow(rows.single);
      if (current.hash != normalizedExpectedHash) return false;

      final updated = await transaction.update(
        tableName,
        _toRow(accountKey, replacement),
        where:
            'account_key = ? AND path = ? AND length(hash) = 40 AND '
            'UPPER(hash) = ? AND UPPER(hash) NOT GLOB \'*[^0-9A-F]*\'',
        whereArgs: [accountKey, normalizedPath, normalizedExpectedHash],
      );
      return updated == 1;
    });
  }

  @override
  Future<List<OfflineFileRecord>> list(String email) async {
    _ensureOpen();
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    final rows = await database.query(
      tableName,
      where: 'account_key = ?',
      whereArgs: [accountCacheKey(email)],
      orderBy: 'cached_at DESC, path ASC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  @override
  Future<Map<String, OfflineFileRecord>> lookup(
    String email,
    Iterable<String> paths,
  ) async {
    _ensureOpen();
    final canonicalPaths = <String>{};
    for (final path in paths) {
      canonicalPaths.add(normalizeOfflineRemotePath(path));
    }
    if (canonicalPaths.isEmpty) {
      return const <String, OfflineFileRecord>{};
    }

    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final requestedPaths = canonicalPaths.toSet();
    final result = <String, OfflineFileRecord>{};
    final pathsToQuery = canonicalPaths.toList(growable: false);

    await database.transaction((transaction) async {
      for (
        var offset = 0;
        offset < pathsToQuery.length;
        offset += _lookupChunkSize
      ) {
        final proposedEnd = offset + _lookupChunkSize;
        final end = proposedEnd < pathsToQuery.length
            ? proposedEnd
            : pathsToQuery.length;
        final chunk = pathsToQuery.sublist(offset, end);
        final placeholders = List.filled(chunk.length, '?').join(', ');
        final rows = await transaction.query(
          tableName,
          where: 'account_key = ? AND path IN ($placeholders)',
          whereArgs: [accountKey, ...chunk],
        );
        for (final row in rows) {
          final record = _fromRow(row);
          if (requestedPaths.contains(record.path)) {
            result[record.path] = record;
          }
        }
      }
    });

    return Map.unmodifiable(result);
  }

  @override
  Future<bool> hasHashReference(String email, String hash) async {
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final normalizedHash = normalizeCloudHash(hash);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    final rows = await database.query(
      tableName,
      columns: const ['path'],
      where:
          "account_key = ? AND length(hash) = 40 AND UPPER(hash) = ? AND "
          "UPPER(hash) NOT GLOB '*[^0-9A-F]*'",
      whereArgs: [accountKey, normalizedHash],
      limit: 1,
    );
    if (rows.isNotEmpty) return true;

    // A target membership is an ownership reference only after the file has
    // been verified. In particular, queued metadata must not protect a stale
    // or not-yet-existing object from CAS cleanup.
    final targetRows = await database.rawQuery(
      '''
        SELECT hash
        FROM $targetFilesTableName
        WHERE account_key = ?
          AND readiness = ?
          AND hash IS NOT NULL
          AND UPPER(hash) = ?
          AND length(hash) = 40
          AND UPPER(hash) NOT GLOB '*[^0-9A-F]*'
        LIMIT 1
      ''',
      [accountKey, _readinessValue(OfflineReadiness.ready), normalizedHash],
    );
    return targetRows.isNotEmpty;
  }

  @override
  Future<bool> hasHashReferenceOutsideTarget(
    String email,
    String hash, {
    required String targetPath,
    required String targetIncarnation,
  }) async {
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final normalizedHash = normalizeCloudHash(hash);
    final normalizedTargetPath = normalizeOfflineRemotePath(targetPath);
    final normalizedIncarnation = normalizeOfflineTargetIncarnation(
      targetIncarnation,
    );
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    final directRows = await database.rawQuery(
      '''
        SELECT 1
        FROM $tableName
        WHERE account_key = ?
          AND length(hash) = 40
          AND UPPER(hash) = ?
          AND UPPER(hash) NOT GLOB '*[^0-9A-F]*'
        LIMIT 1
      ''',
      [accountKey, normalizedHash],
    );
    if (directRows.isNotEmpty) return true;
    final targetRows = await database.rawQuery(
      '''
        SELECT 1
        FROM $targetFilesTableName
        WHERE account_key = ?
          AND readiness = ?
          AND length(hash) = 40
          AND UPPER(hash) = ?
          AND UPPER(hash) NOT GLOB '*[^0-9A-F]*'
          AND NOT (
            target_path = ? AND target_incarnation = ?
          )
        LIMIT 1
      ''',
      [
        accountKey,
        _readinessValue(OfflineReadiness.ready),
        normalizedHash,
        normalizedTargetPath,
        normalizedIncarnation,
      ],
    );
    return targetRows.isNotEmpty;
  }

  @override
  Future<void> upsertTarget(String email, OfflineTargetRecord target) async {
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    await database.transaction((transaction) async {
      final existingRows = await transaction.query(
        targetsTableName,
        where: 'account_key = ? AND target_path = ?',
        whereArgs: [accountKey, target.targetPath],
        limit: 2,
      );
      if (existingRows.length > 1) {
        throw StateError('Offline target primary key is malformed.');
      }
      if (existingRows.isNotEmpty) {
        final existing = _targetFromRow(
          existingRows.single,
          expectedAccountKey: accountKey,
        );
        if (existing.targetIncarnation != target.targetIncarnation) {
          throw StateError('Offline target incarnation does not match.');
        }
        if (existing.state == OfflineTargetState.removing &&
            target.state != OfflineTargetState.removing) {
          throw StateError('Offline target is being removed.');
        }
        final updated = await transaction.update(
          targetsTableName,
          _targetToRow(accountKey, target),
          where:
              'account_key = ? AND target_path = ? AND target_incarnation = ?',
          whereArgs: [accountKey, target.targetPath, target.targetIncarnation],
        );
        if (updated != 1) {
          throw StateError('Offline target disappeared during update.');
        }
        return;
      }
      await transaction.insert(
        targetsTableName,
        _targetToRow(accountKey, target),
      );
    });
  }

  @override
  Future<void> createTargetWithRootIfNoOverlap(
    String email,
    OfflineTargetRecord target,
    OfflineTargetFrontierRecord root,
  ) async {
    _ensureOpen();
    if (normalizeOfflineRemotePath(target.targetPath) != root.targetPath ||
        target.targetIncarnation != root.targetIncarnation ||
        root.folderPath != root.targetPath ||
        root.sequence != 0 ||
        root.nextOffset != 0 ||
        root.state != OfflineTargetFrontierState.pending) {
      throw ArgumentError('The root frontier does not match the target.');
    }
    final accountKey = accountCacheKey(email);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    await database.transaction((transaction) async {
      final existingRows = await transaction.query(
        targetsTableName,
        columns: const ['target_path'],
        where: 'account_key = ?',
        whereArgs: [accountKey],
      );
      for (final row in existingRows) {
        final existingPath = _canonicalPath(
          _requiredText(row, 'target_path'),
          'target_path',
        );
        if (_pathsOverlap(existingPath, target.targetPath)) {
          throw OfflineTargetOverlapException(existingPath: existingPath);
        }
      }
      await transaction.insert(
        targetsTableName,
        _targetToRow(accountKey, target),
      );
      await transaction.insert(
        targetFrontierTableName,
        _frontierToRow(accountKey, root),
      );
    });
  }

  @override
  Future<void> updateTarget(String email, OfflineTargetRecord target) async {
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final normalizedPath = normalizeOfflineRemotePath(target.targetPath);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    await database.transaction((transaction) async {
      final existingRows = await transaction.query(
        targetsTableName,
        where: 'account_key = ? AND target_path = ?',
        whereArgs: [accountKey, normalizedPath],
        limit: 2,
      );
      if (existingRows.length != 1) {
        throw StateError('Offline target does not exist.');
      }
      final existing = _targetFromRow(
        existingRows.single,
        expectedAccountKey: accountKey,
      );
      if (existing.targetIncarnation != target.targetIncarnation) {
        throw StateError('Offline target incarnation does not match.');
      }
      if (existing.state == OfflineTargetState.removing &&
          target.state != OfflineTargetState.removing) {
        throw StateError('Offline target is being removed.');
      }
      final updated = await transaction.update(
        targetsTableName,
        _targetToRow(accountKey, target),
        where: 'account_key = ? AND target_path = ? AND target_incarnation = ?',
        whereArgs: [accountKey, normalizedPath, target.targetIncarnation],
      );
      if (updated != 1) {
        throw StateError('Offline target does not exist.');
      }
    });
  }

  @override
  Future<void> commitFrontierPage(
    String email, {
    required OfflineTargetFrontierRecord current,
    required OfflineTargetFrontierRecord updated,
    required Iterable<OfflineTargetFrontierRecord> discoveredFolders,
    required Iterable<OfflineTargetFileRecord> discoveredFiles,
  }) async {
    _ensureOpen();
    if (current.targetPath != updated.targetPath ||
        current.targetIncarnation != updated.targetIncarnation ||
        current.folderPath != updated.folderPath ||
        current.sequence != updated.sequence ||
        current.state != OfflineTargetFrontierState.scanning) {
      throw ArgumentError('The frontier page transition is invalid.');
    }
    final accountKey = accountCacheKey(email);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    await database.transaction((transaction) async {
      await _requireMutableTarget(
        transaction,
        accountKey,
        current.targetPath,
        targetIncarnation: current.targetIncarnation,
      );
      final currentRows = await transaction.query(
        targetFrontierTableName,
        where:
            'account_key = ? AND target_path = ? AND folder_path = ? AND '
            'target_incarnation = ? AND sequence = ? AND state = ?',
        whereArgs: [
          accountKey,
          current.targetPath,
          current.folderPath,
          current.targetIncarnation,
          current.sequence,
          _frontierStateValue(OfflineTargetFrontierState.scanning),
        ],
        limit: 2,
      );
      if (currentRows.length != 1) {
        throw StateError('Offline target frontier is no longer claimable.');
      }

      final discoveredPaths = <String>{};
      for (final file in discoveredFiles) {
        _validateTargetFilePathRelationship(file);
        if (file.targetPath != current.targetPath ||
            file.targetIncarnation != current.targetIncarnation ||
            _parentPath(file.filePath) != current.folderPath) {
          throw ArgumentError('A discovered file belongs to another target.');
        }
        if (!discoveredPaths.add(file.filePath)) {
          throw StateError('Offline target page contains a duplicate path.');
        }
        final duplicate = await transaction.query(
          targetFilesTableName,
          columns: const ['file_path'],
          where:
              'account_key = ? AND target_path = ? AND '
              'target_incarnation = ? AND file_path = ?',
          whereArgs: [
            accountKey,
            current.targetPath,
            current.targetIncarnation,
            file.filePath,
          ],
          limit: 1,
        );
        final duplicateFolder = await transaction.query(
          targetFrontierTableName,
          columns: const ['folder_path'],
          where:
              'account_key = ? AND target_path = ? AND '
              'target_incarnation = ? AND folder_path = ?',
          whereArgs: [
            accountKey,
            current.targetPath,
            current.targetIncarnation,
            file.filePath,
          ],
          limit: 1,
        );
        if (duplicate.isNotEmpty || duplicateFolder.isNotEmpty) {
          throw StateError('Offline target page contains a duplicate path.');
        }
        await transaction.insert(
          targetFilesTableName,
          _targetFileToRow(accountKey, file),
        );
      }
      for (final folder in discoveredFolders) {
        _validateFrontierPathRelationship(folder);
        if (folder.targetPath != current.targetPath ||
            folder.targetIncarnation != current.targetIncarnation ||
            _parentPath(folder.folderPath) != current.folderPath) {
          throw ArgumentError('A discovered folder belongs to another target.');
        }
        if (!discoveredPaths.add(folder.folderPath)) {
          throw StateError('Offline target page contains a duplicate path.');
        }
        final duplicate = await transaction.query(
          targetFrontierTableName,
          columns: const ['folder_path'],
          where:
              'account_key = ? AND target_path = ? AND '
              'target_incarnation = ? AND folder_path = ?',
          whereArgs: [
            accountKey,
            current.targetPath,
            current.targetIncarnation,
            folder.folderPath,
          ],
          limit: 1,
        );
        final duplicateFile = await transaction.query(
          targetFilesTableName,
          columns: const ['file_path'],
          where:
              'account_key = ? AND target_path = ? AND '
              'target_incarnation = ? AND file_path = ?',
          whereArgs: [
            accountKey,
            current.targetPath,
            current.targetIncarnation,
            folder.folderPath,
          ],
          limit: 1,
        );
        if (duplicate.isNotEmpty || duplicateFile.isNotEmpty) {
          throw StateError('Offline target page contains a duplicate path.');
        }
        await transaction.insert(
          targetFrontierTableName,
          _frontierToRow(accountKey, folder),
        );
      }

      final changed = await transaction.update(
        targetFrontierTableName,
        {
          'next_offset': updated.nextOffset,
          'state': _frontierStateValue(updated.state),
          'error_code': updated.errorCode,
        },
        where:
            'account_key = ? AND target_path = ? AND folder_path = ? AND '
            'target_incarnation = ? AND sequence = ? AND state = ?',
        whereArgs: [
          accountKey,
          current.targetPath,
          current.folderPath,
          current.targetIncarnation,
          current.sequence,
          _frontierStateValue(OfflineTargetFrontierState.scanning),
        ],
      );
      if (changed != 1) {
        throw StateError('Offline target frontier disappeared during commit.');
      }
    });
  }

  @override
  Future<OfflineTargetRecord?> getTarget(
    String email,
    String targetPath, {
    String? targetIncarnation,
  }) async {
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final normalizedTargetPath = normalizeOfflineRemotePath(targetPath);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    final where = StringBuffer('account_key = ? AND target_path = ?');
    final whereArgs = <Object?>[accountKey, normalizedTargetPath];
    if (targetIncarnation != null) {
      where.write(' AND target_incarnation = ?');
      whereArgs.add(normalizeOfflineTargetIncarnation(targetIncarnation));
    }
    final rows = await database.query(
      targetsTableName,
      where: where.toString(),
      whereArgs: whereArgs,
      limit: 2,
    );
    if (rows.length > 1) {
      throw StateError('Offline target primary key is malformed.');
    }
    return rows.isEmpty
        ? null
        : _targetFromRow(rows.single, expectedAccountKey: accountKey);
  }

  @override
  Future<List<OfflineTargetRecord>> listTargets(String email) async {
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    final rows = await database.query(
      targetsTableName,
      where: 'account_key = ?',
      whereArgs: [accountKey],
      orderBy: 'updated_at DESC, target_path ASC',
    );
    return rows
        .map((row) => _targetFromRow(row, expectedAccountKey: accountKey))
        .toList(growable: false);
  }

  @override
  Future<void> upsertFrontier(
    String email,
    OfflineTargetFrontierRecord frontier,
  ) async {
    _ensureOpen();
    _validateFrontierPathRelationship(frontier);
    final accountKey = accountCacheKey(email);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    await database.transaction((transaction) async {
      await _requireMutableTarget(
        transaction,
        accountKey,
        frontier.targetPath,
        targetIncarnation: frontier.targetIncarnation,
      );
      await transaction.insert(
        targetFrontierTableName,
        _frontierToRow(accountKey, frontier),
        conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
      );
    });
  }

  @override
  Future<List<OfflineTargetFrontierRecord>> listFrontier(
    String email,
    String targetPath, {
    String? targetIncarnation,
  }) async {
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final normalizedTargetPath = normalizeOfflineRemotePath(targetPath);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    final where = StringBuffer('account_key = ? AND target_path = ?');
    final whereArgs = <Object?>[accountKey, normalizedTargetPath];
    if (targetIncarnation != null) {
      where.write(' AND target_incarnation = ?');
      whereArgs.add(normalizeOfflineTargetIncarnation(targetIncarnation));
    }
    final rows = await database.query(
      targetFrontierTableName,
      where: where.toString(),
      whereArgs: whereArgs,
      orderBy: 'sequence ASC, folder_path ASC',
    );
    return rows
        .map(
          (row) => _frontierFromRow(
            row,
            expectedAccountKey: accountKey,
            expectedTargetPath: normalizedTargetPath,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<OfflineTargetFrontierRecord?> claimFrontier(
    String email,
    String targetPath, {
    required String targetIncarnation,
    String? folderPath,
  }) async {
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final normalizedTargetPath = normalizeOfflineRemotePath(targetPath);
    final normalizedIncarnation = normalizeOfflineTargetIncarnation(
      targetIncarnation,
    );
    final normalizedFolderPath = folderPath == null
        ? null
        : normalizeOfflineRemotePath(folderPath);
    if (normalizedFolderPath != null &&
        !_pathCovers(normalizedTargetPath, normalizedFolderPath)) {
      throw ArgumentError.value(
        folderPath,
        'folderPath',
        'A frontier folder must belong to its target.',
      );
    }
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();

    return database.transaction((transaction) async {
      await _requireMutableTarget(
        transaction,
        accountKey,
        normalizedTargetPath,
        targetIncarnation: normalizedIncarnation,
      );
      final where = StringBuffer(
        'account_key = ? AND target_path = ? AND target_incarnation = ? '
        'AND state = ?',
      );
      final whereArgs = <Object?>[
        accountKey,
        normalizedTargetPath,
        normalizedIncarnation,
        _frontierStateValue(OfflineTargetFrontierState.pending),
      ];
      if (normalizedFolderPath != null) {
        where.write(' AND folder_path = ?');
        whereArgs.add(normalizedFolderPath);
      }
      final rows = await transaction.query(
        targetFrontierTableName,
        where: where.toString(),
        whereArgs: whereArgs,
        orderBy: 'sequence ASC, folder_path ASC',
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final current = _frontierFromRow(
        rows.single,
        expectedAccountKey: accountKey,
        expectedTargetPath: normalizedTargetPath,
      );
      final updated = await transaction.update(
        targetFrontierTableName,
        {
          'state': _frontierStateValue(OfflineTargetFrontierState.scanning),
          'error_code': null,
        },
        // The incarnation is part of the conditional claim. A stale worker
        // can therefore never claim a re-enqueued path.
        where:
            'account_key = ? AND target_path = ? AND folder_path = ? AND '
            'target_incarnation = ? AND state = ?',
        whereArgs: [
          accountKey,
          normalizedTargetPath,
          current.folderPath,
          normalizedIncarnation,
          _frontierStateValue(OfflineTargetFrontierState.pending),
        ],
      );
      if (updated != 1) return null;
      return OfflineTargetFrontierRecord(
        targetPath: current.targetPath,
        targetIncarnation: current.targetIncarnation,
        folderPath: current.folderPath,
        nextOffset: current.nextOffset,
        state: OfflineTargetFrontierState.scanning,
        sequence: current.sequence,
      );
    });
  }

  @override
  Future<void> updateFrontier(
    String email,
    OfflineTargetFrontierRecord frontier,
  ) async {
    _ensureOpen();
    _validateFrontierPathRelationship(frontier);
    final accountKey = accountCacheKey(email);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    await database.transaction((transaction) async {
      await _requireMutableTarget(
        transaction,
        accountKey,
        frontier.targetPath,
        targetIncarnation: frontier.targetIncarnation,
      );
      final existingRows = await transaction.query(
        targetFrontierTableName,
        where:
            'account_key = ? AND target_path = ? AND target_incarnation = ? '
            'AND folder_path = ?',
        whereArgs: [
          accountKey,
          frontier.targetPath,
          frontier.targetIncarnation,
          frontier.folderPath,
        ],
        limit: 2,
      );
      if (existingRows.length != 1) {
        throw StateError('Offline target frontier row does not exist.');
      }
      final existing = _frontierFromRow(
        existingRows.single,
        expectedAccountKey: accountKey,
        expectedTargetPath: frontier.targetPath,
      );
      if (existing.sequence != frontier.sequence) {
        throw StateError('Offline target frontier sequence is immutable.');
      }
      final updated = await transaction.update(
        targetFrontierTableName,
        {
          'next_offset': frontier.nextOffset,
          'state': _frontierStateValue(frontier.state),
          'error_code': frontier.errorCode,
        },
        where:
            'account_key = ? AND target_path = ? AND target_incarnation = ? '
            'AND folder_path = ?',
        whereArgs: [
          accountKey,
          frontier.targetPath,
          frontier.targetIncarnation,
          frontier.folderPath,
        ],
      );
      if (updated != 1) {
        throw StateError('Offline target frontier row does not exist.');
      }
    });
  }

  @override
  Future<void> recoverInProgress(
    String email, {
    String? targetPath,
    String? targetIncarnation,
  }) async {
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final normalizedTargetPath = targetPath == null
        ? null
        : normalizeOfflineRemotePath(targetPath);
    final normalizedIncarnation = targetIncarnation == null
        ? null
        : normalizeOfflineTargetIncarnation(targetIncarnation);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    final updatedAt = DateTime.now().toUtc().microsecondsSinceEpoch;
    await database.transaction((transaction) async {
      final targetWhere = StringBuffer(
        'account_key = ? AND state IN (?, ?, ?, ?)',
      );
      final targetArgs = <Object?>[
        accountKey,
        _targetStateValue(OfflineTargetState.planning),
        _targetStateValue(OfflineTargetState.running),
        _targetStateValue(OfflineTargetState.waitingNetworkOrError),
        _targetStateValue(OfflineTargetState.partial),
      ];
      if (normalizedTargetPath != null) {
        targetWhere.write(' AND target_path = ?');
        targetArgs.add(normalizedTargetPath);
      }
      if (normalizedIncarnation != null) {
        targetWhere.write(' AND target_incarnation = ?');
        targetArgs.add(normalizedIncarnation);
      }
      await transaction.update(
        targetsTableName,
        {
          'state': _targetStateValue(OfflineTargetState.queued),
          'updated_at': updatedAt,
        },
        where: targetWhere.toString(),
        whereArgs: targetArgs,
      );

      final frontierWhere = StringBuffer('account_key = ? AND state = ?');
      final frontierArgs = <Object?>[
        accountKey,
        _frontierStateValue(OfflineTargetFrontierState.scanning),
      ];
      if (normalizedTargetPath != null) {
        frontierWhere.write(' AND target_path = ?');
        frontierArgs.add(normalizedTargetPath);
      }
      if (normalizedIncarnation != null) {
        frontierWhere.write(' AND target_incarnation = ?');
        frontierArgs.add(normalizedIncarnation);
      }
      await transaction.update(
        targetFrontierTableName,
        {
          'state': _frontierStateValue(OfflineTargetFrontierState.pending),
          'error_code': null,
        },
        where: frontierWhere.toString(),
        whereArgs: frontierArgs,
      );

      final fileWhere = StringBuffer('account_key = ? AND readiness IN (?, ?)');
      final fileArgs = <Object?>[
        accountKey,
        _readinessValue(OfflineReadiness.downloading),
        _readinessValue(OfflineReadiness.verifying),
      ];
      if (normalizedTargetPath != null) {
        fileWhere.write(' AND target_path = ?');
        fileArgs.add(normalizedTargetPath);
      }
      if (normalizedIncarnation != null) {
        fileWhere.write(' AND target_incarnation = ?');
        fileArgs.add(normalizedIncarnation);
      }
      await transaction.update(
        targetFilesTableName,
        {
          'readiness': _readinessValue(OfflineReadiness.queued),
          'error_code': null,
          'updated_at': updatedAt,
        },
        where: fileWhere.toString(),
        whereArgs: fileArgs,
      );
    });
  }

  @override
  Future<void> upsertTargetFile(
    String email,
    OfflineTargetFileRecord file,
  ) async {
    _ensureOpen();
    _validateTargetFilePathRelationship(file);
    final accountKey = accountCacheKey(email);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    await database.transaction((transaction) async {
      await _requireMutableTarget(
        transaction,
        accountKey,
        file.targetPath,
        targetIncarnation: file.targetIncarnation,
      );
      await transaction.insert(
        targetFilesTableName,
        _targetFileToRow(accountKey, file),
        conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
      );
      if (file.readiness == OfflineReadiness.ready && file.hasValidHash) {
        await transaction.delete(
          transientObjectsTableName,
          where:
              "account_key = ? AND length(hash) = 40 AND UPPER(hash) = ? "
              "AND UPPER(hash) NOT GLOB '*[^0-9A-F]*'",
          whereArgs: [accountKey, file.hash],
        );
      }
    });
  }

  @override
  Future<OfflineTargetFileRecord?> getTargetFile(
    String email,
    String targetPath,
    String filePath, {
    String? targetIncarnation,
  }) async {
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final normalizedTargetPath = normalizeOfflineRemotePath(targetPath);
    final normalizedFilePath = normalizeOfflineRemotePath(filePath);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();

    return database.transaction((transaction) async {
      final targetWhere = StringBuffer('account_key = ? AND target_path = ?');
      final targetArgs = <Object?>[accountKey, normalizedTargetPath];
      if (targetIncarnation != null) {
        targetWhere.write(' AND target_incarnation = ?');
        targetArgs.add(normalizeOfflineTargetIncarnation(targetIncarnation));
      }
      final targetRows = await transaction.query(
        targetsTableName,
        where: targetWhere.toString(),
        whereArgs: targetArgs,
        limit: 2,
      );
      if (targetRows.length > 1) {
        throw StateError('Offline target primary key is malformed.');
      }
      if (targetRows.isEmpty) return null;
      final target = _targetFromRow(
        targetRows.single,
        expectedAccountKey: accountKey,
        expectedTargetPath: normalizedTargetPath,
      );
      if (target.state == OfflineTargetState.removing) return null;

      final rows = await transaction.query(
        targetFilesTableName,
        where:
            'account_key = ? AND target_path = ? AND target_incarnation = ? '
            'AND file_path = ?',
        whereArgs: [
          accountKey,
          normalizedTargetPath,
          target.targetIncarnation,
          normalizedFilePath,
        ],
        limit: 2,
      );
      if (rows.length > 1) {
        throw StateError('Offline target file primary key is malformed.');
      }
      if (rows.isEmpty) return null;
      return _targetFileFromRow(
        rows.single,
        expectedAccountKey: accountKey,
        expectedTargetPath: normalizedTargetPath,
      );
    });
  }

  @override
  Future<OfflineTargetFileRecord?> lookupReadyTargetFile(
    String email,
    String filePath,
  ) async {
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final normalizedFilePath = normalizeOfflineRemotePath(filePath);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();

    return database.transaction((transaction) async {
      final rows = await transaction.rawQuery(
        '''
          SELECT f.*
          FROM $targetFilesTableName f
          INNER JOIN $targetsTableName t
            ON t.account_key = f.account_key
           AND t.target_path = f.target_path
           AND t.target_incarnation = f.target_incarnation
          WHERE f.account_key = ?
            AND f.file_path = ?
            AND f.readiness = ?
            AND t.state != ?
            AND f.hash IS NOT NULL
            AND length(f.hash) = 40
            AND UPPER(f.hash) NOT GLOB '*[^0-9A-F]*'
            AND f.size IS NOT NULL
            AND f.size >= 0
          ORDER BY length(f.target_path) DESC,
                   f.target_path ASC,
                   f.target_incarnation ASC
          LIMIT 1
        ''',
        [
          accountKey,
          normalizedFilePath,
          _readinessValue(OfflineReadiness.ready),
          _targetStateValue(OfflineTargetState.removing),
        ],
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      final targetPath = _canonicalPath(
        _requiredText(row, 'target_path'),
        'target_path',
      );
      final membership = _targetFileFromRow(
        row,
        expectedAccountKey: accountKey,
        expectedTargetPath: targetPath,
      );
      if (membership.filePath != normalizedFilePath ||
          membership.readiness != OfflineReadiness.ready ||
          !_hasCompleteTargetMetadata(membership)) {
        throw StateError('Offline target membership is malformed.');
      }
      return membership;
    });
  }

  @override
  Future<bool> markTargetFileReady(
    String email, {
    required String targetPath,
    required String filePath,
    required String targetIncarnation,
    required String hash,
    required int size,
    DateTime? modifiedAt,
    String? revision,
    String? globalRevision,
  }) async {
    _ensureOpen();
    if (size < 0) {
      throw ArgumentError.value(size, 'size', 'Size must be nonnegative.');
    }
    final accountKey = accountCacheKey(email);
    final normalizedTargetPath = normalizeOfflineRemotePath(targetPath);
    final normalizedFilePath = normalizeOfflineRemotePath(filePath);
    final normalizedIncarnation = normalizeOfflineTargetIncarnation(
      targetIncarnation,
    );
    final normalizedHash = normalizeCloudHash(hash);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();

    return database.transaction((transaction) async {
      final targetRows = await transaction.query(
        targetsTableName,
        where: 'account_key = ? AND target_path = ? AND target_incarnation = ?',
        whereArgs: [accountKey, normalizedTargetPath, normalizedIncarnation],
        limit: 2,
      );
      if (targetRows.length > 1) {
        throw StateError('Offline target primary key is malformed.');
      }
      if (targetRows.isEmpty) return false;
      final target = _targetFromRow(
        targetRows.single,
        expectedAccountKey: accountKey,
        expectedTargetPath: normalizedTargetPath,
      );
      if (target.state == OfflineTargetState.removing) return false;

      final rows = await transaction.query(
        targetFilesTableName,
        where:
            'account_key = ? AND target_path = ? AND target_incarnation = ? '
            'AND file_path = ?',
        whereArgs: [
          accountKey,
          normalizedTargetPath,
          normalizedIncarnation,
          normalizedFilePath,
        ],
        limit: 2,
      );
      if (rows.length > 1) {
        throw StateError('Offline target file primary key is malformed.');
      }
      if (rows.isEmpty) return false;
      _targetFileFromRow(
        rows.single,
        expectedAccountKey: accountKey,
        expectedTargetPath: normalizedTargetPath,
      );

      final updated = await transaction.update(
        targetFilesTableName,
        {
          'hash': normalizedHash,
          'size': size,
          'modified_at': modifiedAt?.toUtc().microsecondsSinceEpoch,
          'revision': revision,
          'global_revision': globalRevision,
          'readiness': _readinessValue(OfflineReadiness.ready),
          'bytes_done': size,
          'error_code': null,
          'updated_at': DateTime.now().toUtc().microsecondsSinceEpoch,
        },
        where:
            'account_key = ? AND target_path = ? AND target_incarnation = ? '
            'AND file_path = ?',
        whereArgs: [
          accountKey,
          normalizedTargetPath,
          normalizedIncarnation,
          normalizedFilePath,
        ],
      );
      return updated == 1;
    });
  }

  @override
  Future<bool> updateTargetFileIfMatches(
    String email, {
    required String targetPath,
    required String targetIncarnation,
    required String filePath,
    required String expectedHash,
    required String hash,
    required int size,
    DateTime? modifiedAt,
    String? revision,
    String? globalRevision,
  }) async {
    _ensureOpen();
    if (size < 0) {
      throw ArgumentError.value(size, 'size', 'Size must be nonnegative.');
    }
    final accountKey = accountCacheKey(email);
    final normalizedTargetPath = normalizeOfflineRemotePath(targetPath);
    final normalizedFilePath = normalizeOfflineRemotePath(filePath);
    final normalizedIncarnation = normalizeOfflineTargetIncarnation(
      targetIncarnation,
    );
    final normalizedExpectedHash = normalizeCloudHash(expectedHash);
    final normalizedHash = normalizeCloudHash(hash);
    if (!_pathCovers(normalizedTargetPath, normalizedFilePath) ||
        normalizedFilePath == '/') {
      throw ArgumentError.value(filePath, 'filePath');
    }
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();

    return database.transaction((transaction) async {
      final targetRows = await transaction.query(
        targetsTableName,
        where: 'account_key = ? AND target_path = ? AND target_incarnation = ?',
        whereArgs: [accountKey, normalizedTargetPath, normalizedIncarnation],
        limit: 2,
      );
      if (targetRows.length > 1) {
        throw StateError('Offline target primary key is malformed.');
      }
      if (targetRows.isEmpty) return false;
      final target = _targetFromRow(
        targetRows.single,
        expectedAccountKey: accountKey,
        expectedTargetPath: normalizedTargetPath,
      );
      if (target.state == OfflineTargetState.removing) return false;

      final rows = await transaction.query(
        targetFilesTableName,
        where:
            'account_key = ? AND target_path = ? AND target_incarnation = ? '
            'AND file_path = ?',
        whereArgs: [
          accountKey,
          normalizedTargetPath,
          normalizedIncarnation,
          normalizedFilePath,
        ],
        limit: 2,
      );
      if (rows.length > 1) {
        throw StateError('Offline target file primary key is malformed.');
      }
      if (rows.isEmpty) return false;
      final current = _targetFileFromRow(
        rows.single,
        expectedAccountKey: accountKey,
        expectedTargetPath: normalizedTargetPath,
      );
      if (current.targetIncarnation != normalizedIncarnation ||
          current.readiness != OfflineReadiness.ready ||
          !current.hasValidHash ||
          current.hash != normalizedExpectedHash) {
        return false;
      }

      final updated = await transaction.update(
        targetFilesTableName,
        {
          'hash': normalizedHash,
          'size': size,
          'modified_at': modifiedAt?.toUtc().microsecondsSinceEpoch,
          'revision': revision,
          'global_revision': globalRevision,
          'readiness': _readinessValue(OfflineReadiness.ready),
          'bytes_done': size,
          'error_code': null,
          'updated_at': DateTime.now().toUtc().microsecondsSinceEpoch,
        },
        where:
            'account_key = ? AND target_path = ? AND target_incarnation = ? '
            'AND file_path = ? AND readiness = ? AND length(hash) = 40 AND '
            'UPPER(hash) = ? AND UPPER(hash) NOT GLOB \'*[^0-9A-F]*\'',
        whereArgs: [
          accountKey,
          normalizedTargetPath,
          normalizedIncarnation,
          normalizedFilePath,
          _readinessValue(OfflineReadiness.ready),
          normalizedExpectedHash,
        ],
      );
      return updated == 1;
    });
  }

  @override
  Future<List<OfflineTargetFileRecord>> listTargetFiles(
    String email,
    String targetPath, {
    String? targetIncarnation,
  }) async {
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final normalizedTargetPath = normalizeOfflineRemotePath(targetPath);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    final where = StringBuffer('account_key = ? AND target_path = ?');
    final whereArgs = <Object?>[accountKey, normalizedTargetPath];
    if (targetIncarnation != null) {
      where.write(' AND target_incarnation = ?');
      whereArgs.add(normalizeOfflineTargetIncarnation(targetIncarnation));
    }
    final rows = await database.query(
      targetFilesTableName,
      where: where.toString(),
      whereArgs: whereArgs,
      orderBy: 'file_path ASC',
    );
    return rows
        .map(
          (row) => _targetFileFromRow(
            row,
            expectedAccountKey: accountKey,
            expectedTargetPath: normalizedTargetPath,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> updateTargetFileReadiness(
    String email, {
    required String targetPath,
    required String filePath,
    required String targetIncarnation,
    required OfflineReadiness readiness,
    int? bytesDone,
    int? total,
    String? errorCode,
  }) async {
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final normalizedTargetPath = normalizeOfflineRemotePath(targetPath);
    final normalizedFilePath = normalizeOfflineRemotePath(filePath);
    final normalizedIncarnation = normalizeOfflineTargetIncarnation(
      targetIncarnation,
    );
    final normalizedErrorCode = normalizeOfflineErrorCode(errorCode);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    await database.transaction((transaction) async {
      await _requireMutableTarget(
        transaction,
        accountKey,
        normalizedTargetPath,
        targetIncarnation: normalizedIncarnation,
      );
      final rows = await transaction.query(
        targetFilesTableName,
        where:
            'account_key = ? AND target_path = ? AND target_incarnation = ? '
            'AND file_path = ?',
        whereArgs: [
          accountKey,
          normalizedTargetPath,
          normalizedIncarnation,
          normalizedFilePath,
        ],
        limit: 2,
      );
      if (rows.length > 1) {
        throw StateError('Offline target file primary key is malformed.');
      }
      if (rows.isEmpty) {
        throw StateError('Offline target file membership does not exist.');
      }
      final current = _targetFileFromRow(
        rows.single,
        expectedAccountKey: accountKey,
        expectedTargetPath: normalizedTargetPath,
      );
      final authoritativeSize = total != null && total >= 0
          ? total
          : current.size;
      final requestedBytesDone = bytesDone ?? current.bytesDone;
      final nextBytesDone = _clampTargetFileProgress(
        requestedBytesDone,
        authoritativeSize,
      );
      final updated = await transaction.update(
        targetFilesTableName,
        {
          'readiness': _readinessValue(readiness),
          'size': total != null && total >= 0 ? total : current.size,
          'bytes_done': nextBytesDone,
          'error_code': normalizedErrorCode,
          'updated_at': DateTime.now().toUtc().microsecondsSinceEpoch,
        },
        where:
            'account_key = ? AND target_path = ? AND target_incarnation = ? '
            'AND file_path = ?',
        whereArgs: [
          accountKey,
          normalizedTargetPath,
          normalizedIncarnation,
          normalizedFilePath,
        ],
      );
      if (updated != 1) {
        throw StateError('Offline target file disappeared during update.');
      }
      if (readiness == OfflineReadiness.ready && current.hasValidHash) {
        await transaction.delete(
          transientObjectsTableName,
          where:
              "account_key = ? AND length(hash) = 40 AND UPPER(hash) = ? "
              "AND UPPER(hash) NOT GLOB '*[^0-9A-F]*'",
          whereArgs: [accountKey, current.hash],
        );
      }
    });
  }

  @override
  Future<OfflineTargetRemovalResult> removeTarget(
    String email,
    String targetPath, {
    required String targetIncarnation,
  }) async {
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final normalizedTargetPath = normalizeOfflineRemotePath(targetPath);
    final normalizedIncarnation = normalizeOfflineTargetIncarnation(
      targetIncarnation,
    );
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();

    return database.transaction((transaction) async {
      final targetRows = await transaction.query(
        targetsTableName,
        where: 'account_key = ? AND target_path = ? AND target_incarnation = ?',
        whereArgs: [accountKey, normalizedTargetPath, normalizedIncarnation],
        limit: 2,
      );
      if (targetRows.length > 1) {
        throw StateError('Offline target primary key is malformed.');
      }
      if (targetRows.isEmpty) {
        return OfflineTargetRemovalResult(
          target: null,
          removedFiles: const [],
          releasedHashes: const [],
          remainingReferences: const {},
        );
      }

      final target = _targetFromRow(
        targetRows.single,
        expectedAccountKey: accountKey,
      );
      final fileRows = await transaction.query(
        targetFilesTableName,
        where: 'account_key = ? AND target_path = ? AND target_incarnation = ?',
        whereArgs: [accountKey, normalizedTargetPath, normalizedIncarnation],
        orderBy: 'file_path ASC',
      );
      final removedFiles = fileRows
          .map(
            (row) => _targetFileFromRow(
              row,
              expectedAccountKey: accountKey,
              expectedTargetPath: normalizedTargetPath,
            ),
          )
          .toList(growable: false);
      final releasedHashes = <String>{
        for (final file in removedFiles)
          if (file.hasValidHash) file.hash!,
      };

      // No foreign-key pragma is assumed for this database. Explicit deletes
      // in one transaction give the same ownership cleanup guarantee while
      // keeping direct rows, other targets, and transient rows independent.
      await transaction.delete(
        targetFilesTableName,
        where: 'account_key = ? AND target_path = ? AND target_incarnation = ?',
        whereArgs: [accountKey, normalizedTargetPath, normalizedIncarnation],
      );
      await transaction.delete(
        targetFrontierTableName,
        where: 'account_key = ? AND target_path = ? AND target_incarnation = ?',
        whereArgs: [accountKey, normalizedTargetPath, normalizedIncarnation],
      );
      await transaction.delete(
        targetsTableName,
        where: 'account_key = ? AND target_path = ? AND target_incarnation = ?',
        whereArgs: [accountKey, normalizedTargetPath, normalizedIncarnation],
      );

      final remainingReferences = <String, int>{};
      for (final hash in releasedHashes) {
        remainingReferences[hash] = await _countReferences(
          transaction,
          accountKey: accountKey,
          hash: hash,
        );
      }
      return OfflineTargetRemovalResult(
        target: target,
        removedFiles: removedFiles,
        releasedHashes: releasedHashes,
        remainingReferences: remainingReferences,
      );
    });
  }

  @override
  Future<Map<String, OfflineAvailabilityState>> lookupEffectiveAvailability(
    String email,
    Iterable<String> paths,
  ) async {
    _ensureOpen();
    final requestedPaths = <String>{};
    for (final path in paths) {
      requestedPaths.add(normalizeOfflineRemotePath(path));
    }
    if (requestedPaths.isEmpty) {
      return const <String, OfflineAvailabilityState>{};
    }

    final accountKey = accountCacheKey(email);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    return database.transaction((transaction) async {
      final direct = await _lookupDirectInTransaction(
        transaction,
        accountKey: accountKey,
        paths: requestedPaths,
      );
      final targetRows = await transaction.query(
        targetsTableName,
        where: 'account_key = ?',
        whereArgs: [accountKey],
      );
      final targets = <String, OfflineTargetRecord>{};
      for (final row in targetRows) {
        final target = _targetFromRow(row, expectedAccountKey: accountKey);
        targets[target.targetPath] = target;
      }
      final frontierRows = await transaction.query(
        targetFrontierTableName,
        where: 'account_key = ?',
        whereArgs: [accountKey],
      );
      final frontierByTarget = <String, List<OfflineTargetFrontierRecord>>{};
      for (final row in frontierRows) {
        final targetPath = _requiredText(row, 'target_path');
        final frontier = _frontierFromRow(
          row,
          expectedAccountKey: accountKey,
          expectedTargetPath: targetPath,
        );
        frontierByTarget.putIfAbsent(targetPath, () => []).add(frontier);
      }
      final fileRows = await transaction.query(
        targetFilesTableName,
        where: 'account_key = ?',
        whereArgs: [accountKey],
      );
      final filesByTarget = <String, List<OfflineTargetFileRecord>>{};
      for (final row in fileRows) {
        final targetPath = _requiredText(row, 'target_path');
        final file = _targetFileFromRow(
          row,
          expectedAccountKey: accountKey,
          expectedTargetPath: targetPath,
        );
        filesByTarget.putIfAbsent(targetPath, () => []).add(file);
      }

      final result = <String, OfflineAvailabilityState>{};
      for (final path in requestedPaths) {
        final directRecord = direct[path];
        if (directRecord != null) {
          result[path] = OfflineAvailabilityState(
            path: path,
            source: OfflineAvailabilitySource.direct,
            readiness: OfflineReadiness.ready,
            directRecord: directRecord,
          );
          continue;
        }
        result[path] = _effectiveTargetState(
          path,
          targets: targets,
          frontierByTarget: frontierByTarget,
          filesByTarget: filesByTarget,
        );
      }
      return Map.unmodifiable(result);
    });
  }

  @override
  Future<void> touchTransient(
    String email,
    TransientObjectRecord record,
  ) async {
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    await database.transaction((transaction) async {
      await transaction.insert(
        transientObjectsTableName,
        _transientToRow(accountKey, record),
        conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
      );
    });
  }

  @override
  Future<List<TransientObjectRecord>> listTransient(String email) async {
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    final rows = await database.query(
      transientObjectsTableName,
      where: 'account_key = ?',
      whereArgs: [accountKey],
      orderBy: 'last_accessed_at ASC, hash ASC',
    );
    return rows
        .map((row) => _transientFromRow(row, expectedAccountKey: accountKey))
        .toList(growable: false);
  }

  @override
  Future<void> removeTransient(String email, String hash) async {
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final normalizedHash = normalizeCloudHash(hash);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    await database.transaction((transaction) async {
      await transaction.delete(
        transientObjectsTableName,
        where:
            "account_key = ? AND length(hash) = 40 AND UPPER(hash) = ? "
            "AND UPPER(hash) NOT GLOB '*[^0-9A-F]*'",
        whereArgs: [accountKey, normalizedHash],
      );
    });
  }

  @override
  Future<bool> hasTransientReference(String email, String hash) async {
    _ensureOpen();
    final accountKey = accountCacheKey(email);
    final normalizedHash = normalizeCloudHash(hash);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    final rows = await database.query(
      transientObjectsTableName,
      columns: const ['account_key', 'hash', 'size', 'last_accessed_at'],
      where:
          "account_key = ? AND length(hash) = 40 AND UPPER(hash) = ? "
          "AND UPPER(hash) NOT GLOB '*[^0-9A-F]*'",
      whereArgs: [accountKey, normalizedHash],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    _transientFromRow(rows.single, expectedAccountKey: accountKey);
    return true;
  }

  @override
  Future<void> remove(String email, String path) async {
    _ensureOpen();
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    await database.transaction((transaction) async {
      await transaction.delete(
        tableName,
        where: 'account_key = ? AND path = ?',
        whereArgs: [accountCacheKey(email), normalizeOfflineRemotePath(path)],
      );
    });
  }

  @override
  Future<void> clearAccount(String email) async {
    _ensureOpen();
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    await database.transaction((transaction) async {
      await transaction.delete(
        tableName,
        where: 'account_key = ?',
        whereArgs: [accountCacheKey(email)],
      );
      final accountKey = accountCacheKey(email);
      await transaction.delete(
        transientObjectsTableName,
        where: 'account_key = ?',
        whereArgs: [accountKey],
      );
      await transaction.delete(
        targetFilesTableName,
        where: 'account_key = ?',
        whereArgs: [accountKey],
      );
      await transaction.delete(
        targetFrontierTableName,
        where: 'account_key = ?',
        whereArgs: [accountKey],
      );
      await transaction.delete(
        targetsTableName,
        where: 'account_key = ?',
        whereArgs: [accountKey],
      );
      await transaction.delete(
        snapshotChildrenTableName,
        where: 'account_key = ?',
        whereArgs: [accountKey],
      );
      await transaction.delete(
        snapshotHeadsTableName,
        where: 'account_key = ?',
        whereArgs: [accountKey],
      );
      await transaction.delete(
        snapshotGenerationsTableName,
        where: 'account_key = ?',
        whereArgs: [accountKey],
      );
    });
  }

  @override
  Future<void> storePage(
    String email,
    CloudFolderPage page, {
    int offset = 0,
    int limit = cloudFolderPageSize,
    required DateTime fetchedAt,
  }) async {
    _ensureOpen();
    _validatePageArguments(page, offset: offset, limit: limit);
    final accountKey = accountCacheKey(email);
    final folderPath = normalizeOfflineRemotePath(page.folder.path);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();

    await database.transaction((transaction) async {
      if (offset == 0) {
        await _deleteOlderIncompleteGenerations(
          transaction,
          accountKey: accountKey,
          folderPath: folderPath,
        );
        final generationId = await _createGeneration(
          transaction,
          accountKey: accountKey,
          folderPath: folderPath,
          page: page,
          limit: limit,
          fetchedAt: fetchedAt,
        );
        await _storeChildren(
          transaction,
          generationId: generationId,
          accountKey: accountKey,
          folderPath: folderPath,
          items: page.items,
        );
        await _advanceGeneration(
          transaction,
          generationId: generationId,
          accountKey: accountKey,
          folderPath: folderPath,
          page: page,
          offset: offset,
          limit: limit,
          fetchedAt: fetchedAt,
        );
        return;
      }

      final staging = await _findLatestStagingGeneration(
        transaction,
        accountKey: accountKey,
        folderPath: folderPath,
      );
      if (staging == null) {
        throw StateError('No staging snapshot expects offset $offset.');
      }

      final generationId = _requiredInt(staging, 'generation_id');
      final expectedOffset = _requiredInt(staging, 'next_offset');
      final expectedCount = _requiredInt(staging, 'expected_count');
      final expectedLimit = _requiredInt(staging, 'page_limit');
      if (offset != expectedOffset) {
        throw StateError(
          'Snapshot offset $offset does not match expected offset '
          '$expectedOffset.',
        );
      }
      if (limit != expectedLimit) {
        throw StateError(
          'Snapshot page limit $limit does not match expected limit '
          '$expectedLimit.',
        );
      }
      if (page.totalCount != expectedCount) {
        throw StateError('Snapshot total count changed during refresh.');
      }

      await _storeChildren(
        transaction,
        generationId: generationId,
        accountKey: accountKey,
        folderPath: folderPath,
        items: page.items,
      );
      await _updateFolderMetadata(
        transaction,
        generationId: generationId,
        folder: page.folder,
        fetchedAt: fetchedAt,
      );
      await _advanceGeneration(
        transaction,
        generationId: generationId,
        accountKey: accountKey,
        folderPath: folderPath,
        page: page,
        offset: offset,
        limit: limit,
        fetchedAt: fetchedAt,
      );
    });
  }

  Future<void> _deleteOlderIncompleteGenerations(
    sqflite.DatabaseExecutor transaction, {
    required String accountKey,
    required String folderPath,
  }) async {
    final staleWhere =
        '''
      g.account_key = ? AND g.folder_path = ? AND g.complete = 0
      AND NOT EXISTS (
        SELECT 1
        FROM $snapshotHeadsTableName h
        WHERE h.account_key = g.account_key
          AND h.folder_path = g.folder_path
          AND h.generation_id = g.generation_id
      )
    ''';
    final generationArgs = [accountKey, folderPath];
    await transaction.rawDelete('''
        DELETE FROM $snapshotChildrenTableName
        WHERE generation_id IN (
          SELECT g.generation_id
          FROM $snapshotGenerationsTableName g
          WHERE $staleWhere
        )
      ''', generationArgs);
    await transaction.rawDelete(
      '''
        DELETE FROM $snapshotGenerationsTableName
        WHERE account_key = ? AND folder_path = ? AND complete = 0
          AND generation_id NOT IN (
            SELECT h.generation_id
            FROM $snapshotHeadsTableName h
            WHERE h.account_key = ? AND h.folder_path = ?
          )
      ''',
      [...generationArgs, accountKey, folderPath],
    );
  }

  Future<void> _deleteOtherGenerations(
    sqflite.DatabaseExecutor transaction, {
    required String accountKey,
    required String folderPath,
    required int currentGenerationId,
  }) async {
    const staleAlias = 'g';
    final otherWhere =
        '''
      $staleAlias.account_key = ? AND $staleAlias.folder_path = ?
      AND $staleAlias.generation_id != ?
    ''';
    final generationArgs = [accountKey, folderPath, currentGenerationId];
    await transaction.rawDelete('''
        DELETE FROM $snapshotChildrenTableName
        WHERE generation_id IN (
          SELECT $staleAlias.generation_id
          FROM $snapshotGenerationsTableName $staleAlias
          WHERE $otherWhere
        )
      ''', generationArgs);
    await transaction.rawDelete('''
        DELETE FROM $snapshotGenerationsTableName
        WHERE account_key = ? AND folder_path = ? AND generation_id != ?
      ''', generationArgs);
  }

  @override
  Future<CachedCloudFolderPage?> readFolder(
    String email,
    String path, {
    CloudSort sort = CloudSort.nameAscending,
    int offset = 0,
    int limit = cloudFolderPageSize,
  }) async {
    _ensureOpen();
    _validateReadArguments(offset: offset, limit: limit);
    final accountKey = accountCacheKey(email);
    final folderPath = normalizeOfflineRemotePath(path);
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();

    return database.transaction((transaction) async {
      final headRows = await transaction.query(
        snapshotHeadsTableName,
        where: 'account_key = ? AND folder_path = ?',
        whereArgs: [accountKey, folderPath],
        limit: 2,
      );

      Map<String, Object?>? generation;
      if (headRows.length > 1) {
        throw StateError('Metadata snapshot head is malformed.');
      }
      if (headRows.isNotEmpty) {
        final generationId = _requiredInt(headRows.single, 'generation_id');
        final generations = await transaction.query(
          snapshotGenerationsTableName,
          where: 'generation_id = ? AND account_key = ? AND folder_path = ?',
          whereArgs: [generationId, accountKey, folderPath],
          limit: 2,
        );
        if (generations.length != 1) {
          throw StateError('Metadata snapshot head points to no generation.');
        }
        generation = generations.single;
        if (_requiredInt(generation, 'complete') != 1) {
          throw StateError('Published metadata snapshot is incomplete.');
        }
      } else {
        generation = await _findLatestStagingGeneration(
          transaction,
          accountKey: accountKey,
          folderPath: folderPath,
        );
        if (generation == null) return null;
      }

      return _readGeneration(
        transaction,
        generation,
        accountKey: accountKey,
        folderPath: folderPath,
        sort: sort,
        offset: offset,
        limit: limit,
      );
    });
  }

  @override
  Future<void> close() {
    final existingClose = _closeFuture;
    if (existingClose != null) return existingClose;

    _closed = true;
    final closeFuture = _closeDatabaseIfOpen();
    _closeFuture = closeFuture;
    return closeFuture;
  }

  Future<sqflite.Database> _openDatabaseIfNeeded() {
    _ensureOpen();
    final existing = _databaseFuture;
    if (existing != null) return existing;

    final opening = _openDatabase();
    _databaseFuture = opening;
    return opening;
  }

  Future<sqflite.Database> _openDatabase() async {
    final root = await _rootProvider.getRoot();
    _ensureOpen();

    final directory = Directory(p.join(root.path, _cacheDirectoryName));
    await directory.create(recursive: true);
    _ensureOpen();

    final database = await _databaseFactory.openDatabase(
      p.join(directory.path, databaseFileName),
      options: sqflite.OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: (database, _) => _createSchema(database),
        onUpgrade: (database, oldVersion, _) async {
          if (oldVersion < 2) {
            await _migrateToV2(database);
          }
          if (oldVersion < 3) {
            await _createHashIndex(database);
          }
          if (oldVersion < 4) {
            await _createTransientSchema(database);
          }
          if (oldVersion < 5) {
            await _createTargetSchema(database);
          }
          if (oldVersion < 6) {
            await _migrateToV6(database);
          }
        },
      ),
    );

    if (_closed) {
      await database.close();
      throw StateError('Offline file index is closed.');
    }
    return database;
  }

  Future<void> _closeDatabaseIfOpen() async {
    final opening = _databaseFuture;
    if (opening == null) return;

    sqflite.Database? database;
    try {
      database = await opening;
    } catch (_) {
      // The opening operation owns its own cleanup when close races it.
      return;
    }
    await database.close();
  }

  Future<void> _createSchema(sqflite.Database database) async {
    await database.execute('''
      CREATE TABLE $tableName (
        account_key TEXT NOT NULL,
        path TEXT NOT NULL,
        name TEXT NOT NULL,
        hash TEXT NOT NULL,
        size INTEGER NOT NULL CHECK (size >= 0),
        modified_at INTEGER,
        revision TEXT,
        global_revision TEXT,
        cached_at INTEGER NOT NULL,
        PRIMARY KEY (account_key, path)
      )
    ''');
    await database.execute('''
      CREATE INDEX $_cachedAtIndexName
      ON $tableName (account_key, cached_at DESC, path ASC)
    ''');
    await _createHashIndex(database);
    await _createMetadataSchema(database);
    await _createTransientSchema(database);
    await _createTargetSchema(database);
  }

  /// Creates only the v2 tables. This is deliberately separate from the
  /// fresh-database schema so a v1 database never attempts to recreate
  /// [tableName] during upgrade.
  Future<void> _migrateToV2(sqflite.Database database) async {
    await _createMetadataSchema(database);
  }

  /// Adds target incarnations without changing the meaning of any v5 row.
  ///
  /// v5 had one path identity, so all rows belonging to one old target receive
  /// the same deterministic value.  It is intentionally not random: opening
  /// the same database twice must produce the same ownership identity.
  Future<void> _migrateToV6(sqflite.DatabaseExecutor database) async {
    for (final table in [
      targetsTableName,
      targetFrontierTableName,
      targetFilesTableName,
    ]) {
      if (!await _hasColumn(database, table, 'target_incarnation')) {
        await database.execute(
          'ALTER TABLE $table ADD COLUMN target_incarnation TEXT',
        );
      }
    }

    if (await _tableExists(database, targetsTableName)) {
      final rows = await database.query(
        targetsTableName,
        columns: const ['account_key', 'target_path'],
      );
      for (final row in rows) {
        final accountKey = _requiredText(row, 'account_key');
        final targetPath = _requiredText(row, 'target_path');
        await database.update(
          targetsTableName,
          {
            'target_incarnation': _legacyTargetIncarnation(
              accountKey,
              targetPath,
            ),
          },
          where: 'account_key = ? AND target_path = ?',
          whereArgs: [accountKey, targetPath],
        );
      }
    }

    for (final table in [targetFrontierTableName, targetFilesTableName]) {
      if (!await _tableExists(database, table)) continue;
      final rows = await database.query(
        table,
        columns: const ['account_key', 'target_path'],
      );
      for (final row in rows) {
        final accountKey = _requiredText(row, 'account_key');
        final targetPath = _requiredText(row, 'target_path');
        await database.update(
          table,
          {
            'target_incarnation': _legacyTargetIncarnation(
              accountKey,
              targetPath,
            ),
          },
          where: 'account_key = ? AND target_path = ?',
          whereArgs: [accountKey, targetPath],
        );
      }
    }

    // v4/v5 installations may contain valid lower-case references. Normalize
    // only validated 40-hex values; malformed legacy values remain visible to
    // the row validator instead of being silently repaired.
    for (final table in [tableName, transientObjectsTableName]) {
      if (!await _tableExists(database, table)) continue;
      await database.execute('''
        UPDATE $table
        SET hash = UPPER(hash)
        WHERE length(hash) = 40
          AND UPPER(hash) NOT GLOB '*[^0-9A-F]*'
      ''');
    }
    if (await _tableExists(database, targetFilesTableName)) {
      await database.execute('''
        UPDATE $targetFilesTableName
        SET hash = UPPER(hash)
        WHERE hash IS NOT NULL
          AND length(hash) = 40
          AND UPPER(hash) NOT GLOB '*[^0-9A-F]*'
      ''');
    }
  }

  Future<bool> _tableExists(
    sqflite.DatabaseExecutor database,
    String table,
  ) async {
    final rows = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [table],
    );
    return rows.isNotEmpty;
  }

  Future<bool> _hasColumn(
    sqflite.DatabaseExecutor database,
    String table,
    String column,
  ) async {
    if (!await _tableExists(database, table)) return false;
    final rows = await database.rawQuery('PRAGMA table_info($table)');
    return rows.any((row) => row['name'] == column);
  }

  String _legacyTargetIncarnation(String accountKey, String targetPath) {
    final digest = sha256
        .convert(
          utf8.encode('offline-target-v5\u0000$accountKey\u0000$targetPath'),
        )
        .toString();
    return 'legacy_v5_$digest';
  }

  Future<void> _createHashIndex(sqflite.DatabaseExecutor database) async {
    await database.execute('''
      CREATE INDEX IF NOT EXISTS $_hashIndexName
      ON $tableName (account_key, hash)
    ''');
  }

  Future<void> _createTransientSchema(sqflite.DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS $transientObjectsTableName (
        account_key TEXT NOT NULL,
        hash TEXT NOT NULL,
        size INTEGER NOT NULL CHECK (size >= 0),
        last_accessed_at INTEGER NOT NULL,
        PRIMARY KEY (account_key, hash)
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS $_transientLruIndexName
      ON $transientObjectsTableName (
        account_key, last_accessed_at ASC, hash ASC
      )
    ''');
  }

  Future<void> _createTargetSchema(sqflite.DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS $targetsTableName (
        account_key TEXT NOT NULL,
        target_path TEXT NOT NULL,
        target_incarnation TEXT NOT NULL CHECK (
          length(target_incarnation) BETWEEN 1 AND 128
          AND target_incarnation NOT GLOB '*[^A-Za-z0-9_-]*'
        ),
        target_name TEXT NOT NULL CHECK (length(trim(target_name)) > 0),
        state TEXT NOT NULL CHECK (
          state IN (
            'planning', 'queued', 'running', 'waiting_networkOrError',
            'partial', 'ready', 'removing'
          )
        ),
        scan_complete INTEGER NOT NULL CHECK (scan_complete IN (0, 1)),
        estimate_files INTEGER CHECK (
          estimate_files IS NULL OR estimate_files >= 0
        ),
        estimate_bytes INTEGER CHECK (
          estimate_bytes IS NULL OR estimate_bytes >= 0
        ),
        estimate_has_unknown INTEGER NOT NULL CHECK (
          estimate_has_unknown IN (0, 1)
        ),
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (account_key, target_path)
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS $_targetUpdatedAtIndexName
      ON $targetsTableName (account_key, updated_at DESC, target_path ASC)
    ''');

    await database.execute('''
      CREATE TABLE IF NOT EXISTS $targetFrontierTableName (
        account_key TEXT NOT NULL,
        target_path TEXT NOT NULL,
        target_incarnation TEXT NOT NULL CHECK (
          length(target_incarnation) BETWEEN 1 AND 128
          AND target_incarnation NOT GLOB '*[^A-Za-z0-9_-]*'
        ),
        folder_path TEXT NOT NULL,
        next_offset INTEGER NOT NULL CHECK (next_offset >= 0),
        state TEXT NOT NULL CHECK (
          state IN ('pending', 'scanning', 'complete', 'error')
        ),
        sequence INTEGER NOT NULL CHECK (sequence >= 0),
        error_code TEXT CHECK (
          error_code IS NULL OR (
            length(error_code) BETWEEN 1 AND 64
            AND error_code NOT GLOB '*[^a-z0-9_]*'
          )
        ),
        PRIMARY KEY (account_key, target_path, folder_path),
        CHECK (length(folder_path) > 0)
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS $_targetFrontierClaimIndexName
      ON $targetFrontierTableName (
        account_key, target_path, target_incarnation, state,
        sequence ASC, folder_path ASC
      )
    ''');

    await database.execute('''
      CREATE TABLE IF NOT EXISTS $targetFilesTableName (
        account_key TEXT NOT NULL,
        target_path TEXT NOT NULL,
        target_incarnation TEXT NOT NULL CHECK (
          length(target_incarnation) BETWEEN 1 AND 128
          AND target_incarnation NOT GLOB '*[^A-Za-z0-9_-]*'
        ),
        file_path TEXT NOT NULL,
        name TEXT NOT NULL CHECK (length(trim(name)) > 0),
        hash TEXT,
        size INTEGER CHECK (size IS NULL OR size >= 0),
        modified_at INTEGER,
        revision TEXT,
        global_revision TEXT,
        readiness TEXT NOT NULL CHECK (
          readiness IN (
            'idle', 'queued', 'downloading', 'verifying', 'ready', 'error'
          )
        ),
        bytes_done INTEGER NOT NULL CHECK (
          bytes_done >= 0 AND (size IS NULL OR bytes_done <= size)
        ),
        error_code TEXT CHECK (
          error_code IS NULL OR (
            length(error_code) BETWEEN 1 AND 64
            AND error_code NOT GLOB '*[^a-z0-9_]*'
          )
        ),
        last_seen_scan_id INTEGER CHECK (
          last_seen_scan_id IS NULL OR last_seen_scan_id >= 0
        ),
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (account_key, target_path, file_path)
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS $_targetFilesPathIndexName
      ON $targetFilesTableName (
        account_key, file_path, target_path, target_incarnation
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS $_targetFilesHashIndexName
      ON $targetFilesTableName (
        account_key, hash, readiness, target_path, target_incarnation,
        file_path
      )
    ''');
  }

  Future<void> _createMetadataSchema(sqflite.DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS $snapshotGenerationsTableName (
        generation_id INTEGER PRIMARY KEY AUTOINCREMENT,
        account_key TEXT NOT NULL,
        folder_path TEXT NOT NULL,
        folder_name TEXT NOT NULL,
        folder_type INTEGER NOT NULL CHECK (folder_type BETWEEN 0 AND 2),
        folder_kind TEXT,
        folder_size INTEGER CHECK (
          folder_size IS NULL OR folder_size >= 0
        ),
        folder_modified_at INTEGER,
        folder_hash TEXT,
        folder_revision TEXT,
        folder_global_revision TEXT,
        folder_tree TEXT,
        folder_web_link TEXT,
        folder_virus_scan TEXT,
        folder_file_count INTEGER CHECK (
          folder_file_count IS NULL OR folder_file_count >= 0
        ),
        folder_folder_count INTEGER CHECK (
          folder_folder_count IS NULL OR folder_folder_count >= 0
        ),
        expected_count INTEGER NOT NULL CHECK (expected_count >= 0),
        next_offset INTEGER NOT NULL CHECK (next_offset >= 0),
        page_limit INTEGER NOT NULL CHECK (page_limit > 0),
        fetched_at INTEGER NOT NULL,
        complete INTEGER NOT NULL CHECK (complete IN (0, 1)),
        UNIQUE (account_key, folder_path, generation_id)
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS $snapshotHeadsTableName (
        account_key TEXT NOT NULL,
        folder_path TEXT NOT NULL,
        generation_id INTEGER NOT NULL,
        PRIMARY KEY (account_key, folder_path)
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS $snapshotChildrenTableName (
        generation_id INTEGER NOT NULL,
        account_key TEXT NOT NULL,
        folder_path TEXT NOT NULL,
        child_path TEXT NOT NULL,
        child_name TEXT NOT NULL,
        child_type INTEGER NOT NULL CHECK (child_type BETWEEN 0 AND 2),
        child_kind TEXT,
        child_size INTEGER CHECK (child_size IS NULL OR child_size >= 0),
        child_modified_at INTEGER,
        child_hash TEXT,
        child_revision TEXT,
        child_global_revision TEXT,
        child_tree TEXT,
        child_web_link TEXT,
        child_virus_scan TEXT,
        child_file_count INTEGER CHECK (
          child_file_count IS NULL OR child_file_count >= 0
        ),
        child_folder_count INTEGER CHECK (
          child_folder_count IS NULL OR child_folder_count >= 0
        ),
        PRIMARY KEY (generation_id, child_path)
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS $_snapshotGenerationsIndexName
      ON $snapshotGenerationsTableName (
        account_key, folder_path, generation_id DESC
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS $_snapshotHeadsIndexName
      ON $snapshotHeadsTableName (generation_id)
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS $_snapshotChildrenIndexName
      ON $snapshotChildrenTableName (
        account_key, folder_path, generation_id, child_path
      )
    ''');
  }

  String _targetStateValue(OfflineTargetState state) => switch (state) {
    OfflineTargetState.planning => 'planning',
    OfflineTargetState.queued => 'queued',
    OfflineTargetState.running => 'running',
    OfflineTargetState.waitingNetworkOrError => 'waiting_networkOrError',
    OfflineTargetState.partial => 'partial',
    OfflineTargetState.ready => 'ready',
    OfflineTargetState.removing => 'removing',
  };

  OfflineTargetState _targetStateFromValue(String value) => switch (value) {
    'planning' => OfflineTargetState.planning,
    'queued' => OfflineTargetState.queued,
    'running' => OfflineTargetState.running,
    'waiting_networkOrError' => OfflineTargetState.waitingNetworkOrError,
    'partial' => OfflineTargetState.partial,
    'ready' => OfflineTargetState.ready,
    'removing' => OfflineTargetState.removing,
    _ => throw StateError('Offline target state is invalid.'),
  };

  String _frontierStateValue(OfflineTargetFrontierState state) =>
      switch (state) {
        OfflineTargetFrontierState.pending => 'pending',
        OfflineTargetFrontierState.scanning => 'scanning',
        OfflineTargetFrontierState.complete => 'complete',
        OfflineTargetFrontierState.error => 'error',
      };

  OfflineTargetFrontierState _frontierStateFromValue(String value) =>
      switch (value) {
        'pending' => OfflineTargetFrontierState.pending,
        'scanning' => OfflineTargetFrontierState.scanning,
        'complete' => OfflineTargetFrontierState.complete,
        'error' => OfflineTargetFrontierState.error,
        _ => throw StateError('Offline target frontier state is invalid.'),
      };

  String _readinessValue(OfflineReadiness readiness) => switch (readiness) {
    OfflineReadiness.idle => 'idle',
    OfflineReadiness.queued => 'queued',
    OfflineReadiness.downloading => 'downloading',
    OfflineReadiness.verifying => 'verifying',
    OfflineReadiness.ready => 'ready',
    OfflineReadiness.error => 'error',
  };

  OfflineReadiness _readinessFromValue(String value) => switch (value) {
    'idle' => OfflineReadiness.idle,
    'queued' => OfflineReadiness.queued,
    'downloading' => OfflineReadiness.downloading,
    'verifying' => OfflineReadiness.verifying,
    'ready' => OfflineReadiness.ready,
    'error' => OfflineReadiness.error,
    _ => throw StateError('Offline target file readiness is invalid.'),
  };

  Map<String, Object?> _targetToRow(
    String accountKey,
    OfflineTargetRecord target,
  ) => {
    'account_key': accountKey,
    'target_path': normalizeOfflineRemotePath(target.targetPath),
    'target_incarnation': target.targetIncarnation,
    'target_name': target.targetName,
    'state': _targetStateValue(target.state),
    'scan_complete': target.scanComplete ? 1 : 0,
    'estimate_files': target.estimateFiles,
    'estimate_bytes': target.estimateBytes,
    'estimate_has_unknown': target.estimateHasUnknown ? 1 : 0,
    'created_at': target.createdAt.toUtc().microsecondsSinceEpoch,
    'updated_at': target.updatedAt.toUtc().microsecondsSinceEpoch,
  };

  OfflineTargetRecord _targetFromRow(
    Map<String, Object?> row, {
    required String expectedAccountKey,
    String? expectedTargetPath,
  }) {
    final storedAccountKey = _requiredText(row, 'account_key');
    if (storedAccountKey != expectedAccountKey) {
      throw StateError('Offline target account ownership is malformed.');
    }
    final storedPath = _canonicalPath(
      _requiredText(row, 'target_path'),
      'target_path',
    );
    if (expectedTargetPath != null && storedPath != expectedTargetPath) {
      throw StateError('Offline target path ownership is malformed.');
    }
    final scanComplete = _requiredBoolInt(row, 'scan_complete');
    final unknownEstimate = _requiredBoolInt(row, 'estimate_has_unknown');
    return OfflineTargetRecord(
      targetPath: storedPath,
      targetIncarnation: _requiredTargetIncarnation(row),
      targetName: _requiredText(row, 'target_name'),
      state: _targetStateFromValue(_requiredText(row, 'state')),
      scanComplete: scanComplete,
      estimateFiles: _optionalNonnegativeInt(row, 'estimate_files'),
      estimateBytes: _optionalNonnegativeInt(row, 'estimate_bytes'),
      estimateHasUnknown: unknownEstimate,
      createdAt: _dateFromRow(row, 'created_at'),
      updatedAt: _dateFromRow(row, 'updated_at'),
    );
  }

  Map<String, Object?> _frontierToRow(
    String accountKey,
    OfflineTargetFrontierRecord frontier,
  ) => {
    'account_key': accountKey,
    'target_path': frontier.targetPath,
    'target_incarnation': frontier.targetIncarnation,
    'folder_path': frontier.folderPath,
    'next_offset': frontier.nextOffset,
    'state': _frontierStateValue(frontier.state),
    'sequence': frontier.sequence,
    'error_code': frontier.errorCode,
  };

  OfflineTargetFrontierRecord _frontierFromRow(
    Map<String, Object?> row, {
    required String expectedAccountKey,
    required String expectedTargetPath,
  }) {
    final storedAccountKey = _requiredText(row, 'account_key');
    if (storedAccountKey != expectedAccountKey) {
      throw StateError('Offline target frontier account is malformed.');
    }
    final storedTargetPath = _canonicalPath(
      _requiredText(row, 'target_path'),
      'target_path',
    );
    if (storedTargetPath != expectedTargetPath) {
      throw StateError('Offline target frontier ownership is malformed.');
    }
    final folderPath = _canonicalPath(
      _requiredText(row, 'folder_path'),
      'folder_path',
    );
    if (!_pathCovers(storedTargetPath, folderPath)) {
      throw StateError('Offline target frontier path is malformed.');
    }
    return OfflineTargetFrontierRecord(
      targetPath: storedTargetPath,
      targetIncarnation: _requiredTargetIncarnation(row),
      folderPath: folderPath,
      nextOffset: _requiredInt(row, 'next_offset'),
      state: _frontierStateFromValue(_requiredText(row, 'state')),
      sequence: _requiredInt(row, 'sequence'),
      errorCode: _storedErrorCode(row, 'error_code'),
    );
  }

  Map<String, Object?> _targetFileToRow(
    String accountKey,
    OfflineTargetFileRecord file,
  ) => {
    'account_key': accountKey,
    'target_path': file.targetPath,
    'target_incarnation': file.targetIncarnation,
    'file_path': file.filePath,
    'name': file.name,
    'hash': file.hash,
    'size': file.size,
    'modified_at': file.modifiedAt?.toUtc().microsecondsSinceEpoch,
    'revision': file.revision,
    'global_revision': file.globalRevision,
    'readiness': _readinessValue(file.readiness),
    'bytes_done': file.bytesDone,
    'error_code': file.errorCode,
    'last_seen_scan_id': file.lastSeenScanId,
    'updated_at': file.updatedAt.toUtc().microsecondsSinceEpoch,
  };

  OfflineTargetFileRecord _targetFileFromRow(
    Map<String, Object?> row, {
    required String expectedAccountKey,
    required String expectedTargetPath,
  }) {
    final storedAccountKey = _requiredText(row, 'account_key');
    if (storedAccountKey != expectedAccountKey) {
      throw StateError('Offline target file account is malformed.');
    }
    final storedTargetPath = _canonicalPath(
      _requiredText(row, 'target_path'),
      'target_path',
    );
    if (storedTargetPath != expectedTargetPath) {
      throw StateError('Offline target file ownership is malformed.');
    }
    final filePath = _canonicalPath(
      _requiredText(row, 'file_path'),
      'file_path',
    );
    if (!_pathCovers(storedTargetPath, filePath) || filePath == '/') {
      throw StateError('Offline target file path is malformed.');
    }
    final rawHash = _optionalText(row, 'hash');
    String? hash;
    if (rawHash != null) {
      try {
        hash = normalizeCloudHash(rawHash);
      } on ArgumentError {
        throw StateError('Offline target file hash is malformed.');
      }
    }
    return OfflineTargetFileRecord(
      targetPath: storedTargetPath,
      targetIncarnation: _requiredTargetIncarnation(row),
      filePath: filePath,
      name: _requiredText(row, 'name'),
      hash: hash,
      size: _optionalNonnegativeInt(row, 'size'),
      modifiedAt: _optionalDateFromRow(row, 'modified_at'),
      revision: _optionalText(row, 'revision'),
      globalRevision: _optionalText(row, 'global_revision'),
      readiness: _readinessFromValue(_requiredText(row, 'readiness')),
      bytesDone: _requiredInt(row, 'bytes_done'),
      errorCode: _storedErrorCode(row, 'error_code'),
      lastSeenScanId: _optionalNonnegativeInt(row, 'last_seen_scan_id'),
      updatedAt: _dateFromRow(row, 'updated_at'),
    );
  }

  String? _storedErrorCode(Map<String, Object?> row, String column) {
    final value = _optionalText(row, column);
    if (value == null) return null;
    try {
      return normalizeOfflineErrorCode(value);
    } on ArgumentError {
      throw StateError('Offline index error code is malformed.');
    }
  }

  bool _requiredBoolInt(Map<String, Object?> row, String column) {
    final value = _requiredInt(row, column);
    if (value != 0 && value != 1) {
      throw StateError('Offline index boolean column $column is invalid.');
    }
    return value == 1;
  }

  Future<void> _requireMutableTarget(
    sqflite.DatabaseExecutor transaction,
    String accountKey,
    String targetPath, {
    required String targetIncarnation,
  }) async {
    final rows = await transaction.query(
      targetsTableName,
      where: 'account_key = ? AND target_path = ? AND target_incarnation = ?',
      whereArgs: [accountKey, targetPath, targetIncarnation],
      limit: 2,
    );
    if (rows.length != 1) {
      throw StateError('Offline target does not exist.');
    }
    final target = _targetFromRow(rows.single, expectedAccountKey: accountKey);
    if (target.state == OfflineTargetState.removing) {
      throw StateError('Offline target is being removed.');
    }
  }

  String _requiredTargetIncarnation(Map<String, Object?> row) {
    final value = _requiredText(row, 'target_incarnation');
    try {
      return normalizeOfflineTargetIncarnation(value);
    } on ArgumentError {
      throw StateError('Offline target incarnation is malformed.');
    }
  }

  void _validateFrontierPathRelationship(OfflineTargetFrontierRecord frontier) {
    if (!_pathCovers(frontier.targetPath, frontier.folderPath)) {
      throw ArgumentError.value(
        frontier.folderPath,
        'frontier.folderPath',
        'A frontier folder must belong to its target.',
      );
    }
  }

  void _validateTargetFilePathRelationship(OfflineTargetFileRecord file) {
    if (!_pathCovers(file.targetPath, file.filePath)) {
      throw ArgumentError.value(
        file.filePath,
        'file.filePath',
        'A target file must belong to its target.',
      );
    }
  }

  int _clampTargetFileProgress(int bytesDone, int? size) {
    if (bytesDone < 0) {
      throw ArgumentError.value(
        bytesDone,
        'bytesDone',
        'Downloaded bytes must be nonnegative.',
      );
    }
    return size != null && bytesDone > size ? size : bytesDone;
  }

  bool _pathCovers(String parent, String path) {
    if (parent == '/') return path.startsWith('/');
    return path == parent || path.startsWith('$parent/');
  }

  bool _pathsOverlap(String left, String right) =>
      left == right || _pathCovers(left, right) || _pathCovers(right, left);

  Future<Map<String, OfflineFileRecord>> _lookupDirectInTransaction(
    sqflite.DatabaseExecutor transaction, {
    required String accountKey,
    required Set<String> paths,
  }) async {
    final requestedPaths = paths.toList(growable: false);
    final result = <String, OfflineFileRecord>{};
    for (
      var offset = 0;
      offset < requestedPaths.length;
      offset += _lookupChunkSize
    ) {
      final proposedEnd = offset + _lookupChunkSize;
      final end = proposedEnd < requestedPaths.length
          ? proposedEnd
          : requestedPaths.length;
      final chunk = requestedPaths.sublist(offset, end);
      final placeholders = List.filled(chunk.length, '?').join(', ');
      final rows = await transaction.query(
        tableName,
        where: 'account_key = ? AND path IN ($placeholders)',
        whereArgs: [accountKey, ...chunk],
      );
      for (final row in rows) {
        final record = _fromRow(row);
        if (paths.contains(record.path)) result[record.path] = record;
      }
    }
    return result;
  }

  Future<int> _countReferences(
    sqflite.DatabaseExecutor transaction, {
    required String accountKey,
    required String hash,
  }) async {
    var count = 0;
    final directRows = await transaction.rawQuery(
      'SELECT COUNT(*) AS reference_count FROM $tableName '
      "WHERE account_key = ? AND length(hash) = 40 AND UPPER(hash) = ? "
      "AND UPPER(hash) NOT GLOB '*[^0-9A-F]*'",
      [accountKey, hash],
    );
    count += _requiredInt(directRows.single, 'reference_count');
    final targetRows = await transaction.rawQuery(
      '''
        SELECT COUNT(*) AS reference_count
        FROM $targetFilesTableName
        WHERE account_key = ?
          AND readiness = ?
          AND UPPER(hash) = ?
          AND length(hash) = 40
          AND UPPER(hash) NOT GLOB '*[^0-9A-F]*'
      ''',
      [accountKey, _readinessValue(OfflineReadiness.ready), hash],
    );
    count += _requiredInt(targetRows.single, 'reference_count');
    final transientRows = await transaction.rawQuery(
      'SELECT COUNT(*) AS reference_count FROM $transientObjectsTableName '
      "WHERE account_key = ? AND length(hash) = 40 AND UPPER(hash) = ? "
      "AND UPPER(hash) NOT GLOB '*[^0-9A-F]*'",
      [accountKey, hash],
    );
    count += _requiredInt(transientRows.single, 'reference_count');
    return count;
  }

  OfflineAvailabilityState _effectiveTargetState(
    String path, {
    required Map<String, OfflineTargetRecord> targets,
    required Map<String, List<OfflineTargetFrontierRecord>> frontierByTarget,
    required Map<String, List<OfflineTargetFileRecord>> filesByTarget,
  }) {
    final exactTarget = targets[path];
    if (exactTarget != null) {
      final evaluation = _evaluateTargetFolder(
        exactTarget,
        path: path,
        exactTarget: true,
        frontier: frontierByTarget[exactTarget.targetPath] ?? const [],
        files: filesByTarget[exactTarget.targetPath] ?? const [],
      );
      return OfflineAvailabilityState(
        path: path,
        source: OfflineAvailabilitySource.directTarget,
        // The target row itself proves ownership of the exact target folder.
        // Descendants do not get this exception: they need a matching
        // frontier row or membership below.
        readiness: exactTarget.state == OfflineTargetState.ready
            ? OfflineReadiness.ready
            : evaluation.readiness,
        targetPath: exactTarget.targetPath,
      );
    }

    final membershipCandidates = <_AvailabilityCandidate>[];
    final coveringTargets = <OfflineTargetRecord>[];
    for (final target in targets.values) {
      if (!_pathCovers(target.targetPath, path)) continue;
      coveringTargets.add(target);
      for (final file in filesByTarget[target.targetPath] ?? const []) {
        if (file.filePath != path) continue;
        membershipCandidates.add(
          _AvailabilityCandidate(
            target: target,
            readiness: _membershipReadiness(target, file),
            file: file,
          ),
        );
      }
    }

    if (membershipCandidates.isNotEmpty) {
      membershipCandidates.sort(_compareAvailabilityCandidates);
      final selected = membershipCandidates.first;
      return OfflineAvailabilityState(
        path: path,
        source: OfflineAvailabilitySource.inherited,
        readiness: selected.readiness,
        targetPath: selected.target.targetPath,
        targetFile: selected.file,
      );
    }

    if (coveringTargets.isEmpty) {
      return OfflineAvailabilityState(
        path: path,
        source: OfflineAvailabilitySource.onlineOnly,
        readiness: OfflineReadiness.idle,
      );
    }

    final folderCandidates = <_AvailabilityCandidate>[];
    for (final target in coveringTargets) {
      final evaluation = _evaluateTargetFolder(
        target,
        path: path,
        exactTarget: false,
        frontier: frontierByTarget[target.targetPath] ?? const [],
        files: filesByTarget[target.targetPath] ?? const [],
      );
      // A target covering a path is not evidence that the path belongs to the
      // target. In particular, do not let every([]) make an unknown remote
      // child of a ready target appear offline-ready.
      if (!evaluation.hasEvidence) continue;
      folderCandidates.add(
        _AvailabilityCandidate(target: target, readiness: evaluation.readiness),
      );
    }
    if (folderCandidates.isEmpty) {
      return OfflineAvailabilityState(
        path: path,
        source: OfflineAvailabilitySource.onlineOnly,
        readiness: OfflineReadiness.idle,
      );
    }
    folderCandidates.sort(_compareAvailabilityCandidates);
    final selected = folderCandidates.first;
    return OfflineAvailabilityState(
      path: path,
      source: OfflineAvailabilitySource.inherited,
      readiness: selected.readiness,
      targetPath: selected.target.targetPath,
      targetFile: selected.file,
    );
  }

  OfflineReadiness _membershipReadiness(
    OfflineTargetRecord target,
    OfflineTargetFileRecord file,
  ) {
    if (target.state == OfflineTargetState.removing) {
      return OfflineReadiness.queued;
    }
    if (file.readiness == OfflineReadiness.ready &&
        !_hasCompleteTargetMetadata(file)) {
      return OfflineReadiness.queued;
    }
    return file.readiness;
  }

  _TargetFolderEvaluation _evaluateTargetFolder(
    OfflineTargetRecord target, {
    required String path,
    required bool exactTarget,
    required List<OfflineTargetFrontierRecord> frontier,
    required List<OfflineTargetFileRecord> files,
  }) {
    final relevantFiles = files
        .where((file) => _pathCovers(path, file.filePath))
        .toList(growable: false);
    final relevantFrontier = frontier
        .where((folder) => _pathCovers(path, folder.folderPath))
        .toList(growable: false);
    final hasEvidence = relevantFrontier.isNotEmpty || relevantFiles.isNotEmpty;

    final hasError =
        relevantFrontier.any(
          (folder) => folder.state == OfflineTargetFrontierState.error,
        ) ||
        relevantFiles.any((file) => file.readiness == OfflineReadiness.error);
    final hasScanning =
        relevantFrontier.any(
          (folder) => folder.state == OfflineTargetFrontierState.scanning,
        ) ||
        relevantFiles.any(
          (file) => file.readiness == OfflineReadiness.downloading,
        );
    final hasVerifying = relevantFiles.any(
      (file) => file.readiness == OfflineReadiness.verifying,
    );

    if (target.state == OfflineTargetState.ready &&
        target.scanComplete &&
        !hasError &&
        !hasScanning &&
        !hasVerifying &&
        relevantFrontier.every(
          (folder) => folder.state == OfflineTargetFrontierState.complete,
        ) &&
        relevantFiles.every(
          (file) =>
              file.readiness == OfflineReadiness.ready &&
              _hasCompleteTargetMetadata(file),
        ) &&
        hasEvidence) {
      return _TargetFolderEvaluation(OfflineReadiness.ready, hasEvidence);
    }

    if (hasError || target.state == OfflineTargetState.waitingNetworkOrError) {
      return _TargetFolderEvaluation(OfflineReadiness.error, hasEvidence);
    }
    if (hasVerifying) {
      return _TargetFolderEvaluation(OfflineReadiness.verifying, hasEvidence);
    }
    if (hasScanning) {
      return _TargetFolderEvaluation(OfflineReadiness.downloading, hasEvidence);
    }
    if (exactTarget && target.state == OfflineTargetState.removing) {
      return _TargetFolderEvaluation(OfflineReadiness.queued, hasEvidence);
    }
    return _TargetFolderEvaluation(OfflineReadiness.queued, hasEvidence);
  }

  bool _hasCompleteTargetMetadata(OfflineTargetFileRecord file) {
    final size = file.size;
    final hash = file.hash;
    if (size == null || size < 0 || hash == null) return false;
    try {
      normalizeCloudHash(hash);
      return true;
    } on ArgumentError {
      return false;
    }
  }

  int _compareAvailabilityCandidates(
    _AvailabilityCandidate left,
    _AvailabilityCandidate right,
  ) {
    final readinessOrder = {
      OfflineReadiness.ready: 6,
      OfflineReadiness.error: 5,
      OfflineReadiness.verifying: 4,
      OfflineReadiness.downloading: 3,
      OfflineReadiness.queued: 2,
      OfflineReadiness.idle: 1,
    };
    final byReadiness = readinessOrder[right.readiness]!.compareTo(
      readinessOrder[left.readiness]!,
    );
    if (byReadiness != 0) return byReadiness;
    final bySpecificity = right.target.targetPath.length.compareTo(
      left.target.targetPath.length,
    );
    if (bySpecificity != 0) return bySpecificity;
    return left.target.targetPath.compareTo(right.target.targetPath);
  }

  void _validatePageArguments(
    CloudFolderPage page, {
    required int offset,
    required int limit,
  }) {
    if (offset < 0) {
      throw ArgumentError.value(
        offset,
        'offset',
        'Offset must be nonnegative.',
      );
    }
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'Limit must be positive.');
    }
    if (page.totalCount < 0) {
      throw ArgumentError.value(
        page.totalCount,
        'page.totalCount',
        'Total count must be nonnegative.',
      );
    }
    if (offset > page.totalCount ||
        offset + page.items.length > page.totalCount) {
      throw ArgumentError('Folder page lies outside its total count.');
    }
    if (page.items.length > limit) {
      throw ArgumentError('Folder page contains more items than its limit.');
    }

    final folderPath = _canonicalPath(page.folder.path, 'folder.path');
    _validateNode(page.folder, path: folderPath, column: 'folder');
    for (final item in page.items) {
      final childPath = _canonicalPath(item.path, 'child.path');
      if (childPath == '/') {
        throw ArgumentError.value(
          item.path,
          'child.path',
          'A child path is required.',
        );
      }
      if (_parentPath(childPath) != folderPath) {
        throw ArgumentError.value(
          item.path,
          'child.path',
          'A snapshot child must belong directly to its folder.',
        );
      }
      _validateNode(item, path: childPath, column: 'child');
    }
  }

  String _parentPath(String path) {
    final separator = path.lastIndexOf('/');
    return separator <= 0 ? '/' : path.substring(0, separator);
  }

  void _validateReadArguments({required int offset, required int limit}) {
    if (offset < 0) {
      throw ArgumentError.value(
        offset,
        'offset',
        'Offset must be nonnegative.',
      );
    }
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'Limit must be positive.');
    }
  }

  Future<int> _createGeneration(
    sqflite.DatabaseExecutor transaction, {
    required String accountKey,
    required String folderPath,
    required CloudFolderPage page,
    required int limit,
    required DateTime fetchedAt,
  }) async {
    final row = <String, Object?>{
      'account_key': accountKey,
      'folder_path': folderPath,
      ..._nodeFields(page.folder, 'folder'),
      'expected_count': page.totalCount,
      'next_offset': 0,
      'page_limit': limit,
      'fetched_at': fetchedAt.toUtc().microsecondsSinceEpoch,
      'complete': 0,
    };
    final generationId = await transaction.insert(
      snapshotGenerationsTableName,
      row,
    );
    if (generationId <= 0) {
      throw StateError('SQLite did not return a snapshot generation id.');
    }
    return generationId;
  }

  Future<void> _storeChildren(
    sqflite.DatabaseExecutor transaction, {
    required int generationId,
    required String accountKey,
    required String folderPath,
    required List<CloudNode> items,
  }) async {
    for (final item in items) {
      final childPath = _canonicalPath(item.path, 'child.path');
      await transaction.insert(
        snapshotChildrenTableName,
        {
          'generation_id': generationId,
          'account_key': accountKey,
          'folder_path': folderPath,
          'child_path': childPath,
          ..._nodeFields(item, 'child'),
        },
        conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
      );
    }
  }

  Future<void> _updateFolderMetadata(
    sqflite.DatabaseExecutor transaction, {
    required int generationId,
    required CloudNode folder,
    required DateTime fetchedAt,
  }) async {
    final updated = await transaction.update(
      snapshotGenerationsTableName,
      {
        ..._nodeFields(folder, 'folder'),
        'fetched_at': fetchedAt.toUtc().microsecondsSinceEpoch,
      },
      where: 'generation_id = ?',
      whereArgs: [generationId],
    );
    if (updated != 1) {
      throw StateError('Snapshot generation disappeared during refresh.');
    }
  }

  Future<void> _advanceGeneration(
    sqflite.DatabaseExecutor transaction, {
    required int generationId,
    required String accountKey,
    required String folderPath,
    required CloudFolderPage page,
    required int offset,
    required int limit,
    required DateTime fetchedAt,
  }) async {
    final nextOffset = offset + page.items.length;
    final countRows = await transaction.rawQuery(
      '''
        SELECT COUNT(*) AS child_count
        FROM $snapshotChildrenTableName
        WHERE generation_id = ?
      ''',
      [generationId],
    );
    if (countRows.length != 1) {
      throw StateError('Snapshot child count is malformed.');
    }
    final childCount = _requiredInt(countRows.single, 'child_count');
    final complete = nextOffset == page.totalCount;
    if (complete && childCount != page.totalCount) {
      throw StateError('Snapshot contains duplicate or missing children.');
    }

    final updated = await transaction.update(
      snapshotGenerationsTableName,
      {
        'next_offset': nextOffset,
        'page_limit': limit,
        'fetched_at': fetchedAt.toUtc().microsecondsSinceEpoch,
        'complete': complete ? 1 : 0,
      },
      where: 'generation_id = ?',
      whereArgs: [generationId],
    );
    if (updated != 1) {
      throw StateError('Snapshot generation disappeared during refresh.');
    }

    if (complete) {
      await transaction.insert(
        snapshotHeadsTableName,
        {
          'account_key': accountKey,
          'folder_path': folderPath,
          'generation_id': generationId,
        },
        conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
      );
      await _deleteOtherGenerations(
        transaction,
        accountKey: accountKey,
        folderPath: folderPath,
        currentGenerationId: generationId,
      );
    }
  }

  Future<Map<String, Object?>?> _findLatestStagingGeneration(
    sqflite.DatabaseExecutor transaction, {
    required String accountKey,
    required String folderPath,
  }) async {
    final rows = await transaction.query(
      snapshotGenerationsTableName,
      where: 'account_key = ? AND folder_path = ? AND complete = 0',
      whereArgs: [accountKey, folderPath],
      orderBy: 'generation_id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single;
  }

  Future<CachedCloudFolderPage> _readGeneration(
    sqflite.DatabaseExecutor transaction,
    Map<String, Object?> generation, {
    required String accountKey,
    required String folderPath,
    required CloudSort sort,
    required int offset,
    required int limit,
  }) async {
    final storedAccountKey = _requiredText(generation, 'account_key');
    final storedFolderPath = _canonicalPath(
      _requiredText(generation, 'folder_path'),
      'folder_path',
    );
    if (storedAccountKey != accountKey || storedFolderPath != folderPath) {
      throw StateError('Metadata snapshot account or path is malformed.');
    }

    final generationId = _requiredInt(generation, 'generation_id');
    final expectedCount = _requiredInt(generation, 'expected_count');
    final nextOffset = _requiredInt(generation, 'next_offset');
    final pageLimit = _requiredInt(generation, 'page_limit');
    final completeValue = _requiredInt(generation, 'complete');
    if (expectedCount < 0 ||
        nextOffset < 0 ||
        nextOffset > expectedCount ||
        pageLimit <= 0) {
      throw StateError('Metadata snapshot paging state is malformed.');
    }
    if (completeValue != 0 && completeValue != 1) {
      throw StateError('Metadata snapshot completion state is malformed.');
    }

    final folder = _nodeFromFields(generation, 'folder', path: folderPath);
    final childRows = await transaction.query(
      snapshotChildrenTableName,
      where: 'generation_id = ? AND account_key = ? AND folder_path = ?',
      whereArgs: [generationId, accountKey, folderPath],
    );
    final items = <CloudNode>[];
    final childPaths = <String>{};
    for (final row in childRows) {
      final rowGenerationId = _requiredInt(row, 'generation_id');
      final rowAccountKey = _requiredText(row, 'account_key');
      final rowFolderPath = _canonicalPath(
        _requiredText(row, 'folder_path'),
        'folder_path',
      );
      if (rowGenerationId != generationId ||
          rowAccountKey != accountKey ||
          rowFolderPath != folderPath) {
        throw StateError('Metadata snapshot child ownership is malformed.');
      }
      final childPath = _canonicalPath(
        _requiredText(row, 'child_path'),
        'child_path',
      );
      if (childPath == '/') {
        throw StateError('Metadata snapshot child path is malformed.');
      }
      if (!childPaths.add(childPath)) {
        throw StateError('Metadata snapshot contains duplicate children.');
      }
      items.add(_nodeFromFields(row, 'child', path: childPath));
    }

    if (items.length > expectedCount ||
        items.length > nextOffset ||
        (completeValue == 1 &&
            (nextOffset != expectedCount || items.length != expectedCount))) {
      throw StateError('Metadata snapshot child count is malformed.');
    }

    items.sort((left, right) => _compareNodes(left, right, sort));
    final start = offset < items.length ? offset : items.length;
    final requestedEnd = start + limit;
    final end = requestedEnd < items.length ? requestedEnd : items.length;
    final pageItems = items.sublist(start, end);
    return CachedCloudFolderPage(
      page: CloudFolderPage(
        folder: folder,
        items: pageItems,
        totalCount: expectedCount,
        sort: sort,
      ),
      complete: completeValue == 1,
      fetchedAt: _dateFromRow(generation, 'fetched_at'),
    );
  }

  Map<String, Object?> _nodeFields(CloudNode node, String prefix) {
    final path = _canonicalPath(node.path, '$prefix.path');
    _validateNode(node, path: path, column: prefix);
    return {
      '${prefix}_name': node.name,
      '${prefix}_type': _nodeTypeValue(node.type),
      '${prefix}_kind': node.kind,
      '${prefix}_size': node.size,
      '${prefix}_modified_at': node.modifiedAt?.toUtc().microsecondsSinceEpoch,
      '${prefix}_hash': node.hash,
      '${prefix}_revision': node.revision,
      '${prefix}_global_revision': node.globalRevision,
      '${prefix}_tree': node.tree,
      '${prefix}_web_link': node.webLink,
      '${prefix}_virus_scan': node.virusScan,
      '${prefix}_file_count': node.fileCount,
      '${prefix}_folder_count': node.folderCount,
    };
  }

  void _validateNode(
    CloudNode node, {
    required String path,
    required String column,
  }) {
    if (node.name.trim().isEmpty) {
      throw ArgumentError.value(
        node.name,
        '$column.name',
        'Name must not be empty.',
      );
    }
    if (path == '/' && column == 'child') {
      throw ArgumentError.value(
        path,
        '$column.path',
        'A child path is required.',
      );
    }
    if (node.size != null && node.size! < 0) {
      throw ArgumentError.value(node.size, '$column.size');
    }
    if (node.fileCount != null && node.fileCount! < 0) {
      throw ArgumentError.value(node.fileCount, '$column.fileCount');
    }
    if (node.folderCount != null && node.folderCount! < 0) {
      throw ArgumentError.value(node.folderCount, '$column.folderCount');
    }
  }

  CloudNode _nodeFromFields(
    Map<String, Object?> row,
    String prefix, {
    required String path,
  }) => CloudNode(
    path: path,
    name: _requiredNodeText(row, '${prefix}_name'),
    type: _nodeTypeFromValue(_requiredInt(row, '${prefix}_type')),
    kind: _optionalText(row, '${prefix}_kind'),
    size: _optionalNonnegativeInt(row, '${prefix}_size'),
    modifiedAt: _optionalDateFromRow(row, '${prefix}_modified_at'),
    hash: _optionalText(row, '${prefix}_hash'),
    revision: _optionalText(row, '${prefix}_revision'),
    globalRevision: _optionalText(row, '${prefix}_global_revision'),
    tree: _optionalText(row, '${prefix}_tree'),
    webLink: _optionalText(row, '${prefix}_web_link'),
    virusScan: _optionalText(row, '${prefix}_virus_scan'),
    fileCount: _optionalNonnegativeInt(row, '${prefix}_file_count'),
    folderCount: _optionalNonnegativeInt(row, '${prefix}_folder_count'),
  );

  String _requiredNodeText(Map<String, Object?> row, String column) {
    final value = _requiredText(row, column);
    if (value.trim().isEmpty) {
      throw StateError('Metadata cache column $column is invalid.');
    }
    return value;
  }

  int? _optionalNonnegativeInt(Map<String, Object?> row, String column) {
    final value = _optionalInt(row, column);
    if (value != null && value < 0) {
      throw StateError('Metadata cache column $column is invalid.');
    }
    return value;
  }

  DateTime? _optionalDateFromRow(Map<String, Object?> row, String column) {
    final value = _optionalInt(row, column);
    if (value == null) return null;
    try {
      return DateTime.fromMicrosecondsSinceEpoch(value, isUtc: true);
    } catch (_) {
      throw StateError('Metadata cache column $column is invalid.');
    }
  }

  DateTime _dateFromRow(Map<String, Object?> row, String column) {
    final value = _requiredInt(row, column);
    try {
      return DateTime.fromMicrosecondsSinceEpoch(value, isUtc: true);
    } catch (_) {
      throw StateError('Metadata cache column $column is invalid.');
    }
  }

  int _nodeTypeValue(CloudNodeType type) => switch (type) {
    CloudNodeType.file => 0,
    CloudNodeType.folder => 1,
    CloudNodeType.unknown => 2,
  };

  CloudNodeType _nodeTypeFromValue(int value) => switch (value) {
    0 => CloudNodeType.file,
    1 => CloudNodeType.folder,
    2 => CloudNodeType.unknown,
    _ => throw StateError('Metadata cache node type is invalid.'),
  };

  String _canonicalPath(String path, String column) {
    try {
      return normalizeOfflineRemotePath(path);
    } on ArgumentError {
      throw StateError('Metadata cache column $column is invalid.');
    }
  }

  int _compareNodes(CloudNode left, CloudNode right, CloudSort sort) {
    final primary = switch (sort.field) {
      CloudSortField.name => left.name.compareTo(right.name),
      CloudSortField.size => _compareNullable(
        left.size,
        right.size,
        (a, b) => a.compareTo(b),
      ),
      CloudSortField.modifiedAt => _compareNullable(
        left.modifiedAt,
        right.modifiedAt,
        (a, b) => a.compareTo(b),
      ),
    };
    if (primary != 0) {
      return sort.order == CloudSortOrder.ascending ? primary : -primary;
    }
    return left.path.compareTo(right.path);
  }

  int _compareNullable<T>(T? left, T? right, int Function(T, T) compare) {
    if (left == null) return right == null ? 0 : -1;
    if (right == null) return 1;
    return compare(left, right);
  }

  Map<String, Object?> _toRow(String accountKey, OfflineFileRecord record) => {
    'account_key': accountKey,
    'path': normalizeOfflineRemotePath(record.path),
    'name': record.name,
    'hash': normalizeCloudHash(record.hash),
    'size': record.size,
    'modified_at': record.modifiedAt?.toUtc().microsecondsSinceEpoch,
    'revision': record.revision,
    'global_revision': record.globalRevision,
    'cached_at': record.cachedAt.toUtc().microsecondsSinceEpoch,
  };

  Map<String, Object?> _transientToRow(
    String accountKey,
    TransientObjectRecord record,
  ) => {
    'account_key': accountKey,
    'hash': normalizeCloudHash(record.hash),
    'size': record.size,
    'last_accessed_at': record.lastAccessedAt.toUtc().microsecondsSinceEpoch,
  };

  TransientObjectRecord _transientFromRow(
    Map<String, Object?> row, {
    required String expectedAccountKey,
  }) {
    final storedAccountKey = _requiredText(row, 'account_key');
    if (storedAccountKey != expectedAccountKey) {
      throw StateError('Transient object account ownership is malformed.');
    }
    final size = _requiredInt(row, 'size');
    if (size < 0) {
      throw StateError('Transient object size is malformed.');
    }
    final accessedAt = _requiredInt(row, 'last_accessed_at');
    final hash = _requiredText(row, 'hash');
    late final String normalizedHash;
    try {
      normalizedHash = normalizeCloudHash(hash);
    } on ArgumentError {
      throw StateError('Transient object hash is malformed.');
    }
    try {
      return TransientObjectRecord(
        hash: normalizedHash,
        size: size,
        lastAccessedAt: DateTime.fromMicrosecondsSinceEpoch(
          accessedAt,
          isUtc: true,
        ),
      );
    } on ArgumentError {
      throw StateError('Transient object timestamp is malformed.');
    }
  }

  OfflineFileRecord _fromRow(Map<String, Object?> row) {
    final size = _requiredInt(row, 'size');
    final cachedAt = _requiredInt(row, 'cached_at');
    final modifiedAt = _optionalInt(row, 'modified_at');
    return OfflineFileRecord(
      path: _requiredText(row, 'path'),
      name: _requiredText(row, 'name'),
      hash: _requiredText(row, 'hash'),
      size: size,
      modifiedAt: modifiedAt == null
          ? null
          : DateTime.fromMicrosecondsSinceEpoch(modifiedAt, isUtc: true),
      revision: _optionalText(row, 'revision'),
      globalRevision: _optionalText(row, 'global_revision'),
      cachedAt: DateTime.fromMicrosecondsSinceEpoch(cachedAt, isUtc: true),
    );
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Offline file index is closed.');
  }
}

final class _AvailabilityCandidate {
  const _AvailabilityCandidate({
    required this.target,
    required this.readiness,
    this.file,
  });

  final OfflineTargetRecord target;
  final OfflineReadiness readiness;
  final OfflineTargetFileRecord? file;
}

final class _TargetFolderEvaluation {
  const _TargetFolderEvaluation(this.readiness, this.hasEvidence);

  final OfflineReadiness readiness;
  final bool hasEvidence;
}

String _requiredText(Map<String, Object?> row, String column) {
  final value = row[column];
  if (value is! String) {
    throw StateError('Offline index column $column is invalid.');
  }
  return value;
}

String? _optionalText(Map<String, Object?> row, String column) {
  final value = row[column];
  if (value == null) return null;
  if (value is! String) {
    throw StateError('Offline index column $column is invalid.');
  }
  return value;
}

int _requiredInt(Map<String, Object?> row, String column) {
  final value = row[column];
  if (value is! int) {
    throw StateError('Offline index column $column is invalid.');
  }
  return value;
}

int? _optionalInt(Map<String, Object?> row, String column) {
  final value = row[column];
  if (value == null) return null;
  if (value is! int) {
    throw StateError('Offline index column $column is invalid.');
  }
  return value;
}
