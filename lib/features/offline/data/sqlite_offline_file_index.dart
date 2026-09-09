import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;

import '../../../local/cache/application_cache_root.dart';
import '../../../local/cache/content_addressed_file_cache.dart';
import '../application/offline_file_index.dart';

/// SQLite-backed implementation of [OfflineFileIndex].
///
/// The database is opened on the first operation, not in the constructor.
/// Account identity is represented only by [accountCacheKey]; raw email
/// addresses and credentials are never written to SQLite.
final class SqliteOfflineFileIndex implements OfflineFileIndex {
  SqliteOfflineFileIndex({
    CacheRootProvider? rootProvider,
    sqflite.DatabaseFactory? databaseFactory,
  }) : _rootProvider = rootProvider ?? const ApplicationCacheRoot(),
       _databaseFactory = databaseFactory ?? sqflite.databaseFactory;

  static const int schemaVersion = 1;
  static const String databaseFileName = 'offline_file_index.sqlite';
  static const String tableName = 'offline_files';

  static const _cacheDirectoryName = 'cloud_cache';
  static const _cachedAtIndexName = 'offline_files_account_cached_at_idx';

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
    await database.insert(
      tableName,
      _toRow(accountKey, record),
      conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
    );
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
  Future<void> remove(String email, String path) async {
    _ensureOpen();
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    await database.delete(
      tableName,
      where: 'account_key = ? AND path = ?',
      whereArgs: [accountCacheKey(email), normalizeOfflineRemotePath(path)],
    );
  }

  @override
  Future<void> clearAccount(String email) async {
    _ensureOpen();
    final database = await _openDatabaseIfNeeded();
    _ensureOpen();
    await database.delete(
      tableName,
      where: 'account_key = ?',
      whereArgs: [accountCacheKey(email)],
    );
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
          if (oldVersion < schemaVersion) {
            await _createSchema(database);
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
      revision: row['revision'] as String?,
      globalRevision: row['global_revision'] as String?,
      cachedAt: DateTime.fromMicrosecondsSinceEpoch(cachedAt, isUtc: true),
    );
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Offline file index is closed.');
  }
}

String _requiredText(Map<String, Object?> row, String column) {
  final value = row[column];
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
