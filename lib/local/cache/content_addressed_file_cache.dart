import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'application_cache_root.dart';

final class CacheObjectPaths {
  const CacheObjectPaths({required this.objectFile, required this.partFile});

  final File objectFile;
  final File partFile;
}

/// A final CAS object discovered at its canonical account-scoped path.
///
/// Enumeration is deliberately metadata-only. Callers that need to trust the
/// contents must validate the object through the normal cache lookup path.
final class CacheObjectCandidate {
  const CacheObjectCandidate({required this.file, required this.hash});

  final File file;
  final String hash;
}

final class ContentAddressedFileCache {
  ContentAddressedFileCache({
    required String email,
    Directory? root,
    CacheRootProvider? rootProvider,
  }) : assert(root == null || rootProvider == null),
       _email = email,
       _rootProvider = root == null
           ? rootProvider ?? const ApplicationCacheRoot()
           : FixedCacheRoot(root);

  final String _email;
  final CacheRootProvider _rootProvider;

  String get accountDirectoryName => accountCacheKey(_email);

  Future<Directory> accountDirectory() async {
    final root = await _rootProvider.getRoot();
    return Directory(_join(root.path, 'cloud_cache', accountDirectoryName));
  }

  Future<CacheObjectPaths> paths(String hash) async {
    final normalizedHash = normalizeCloudHash(hash);
    final account = await accountDirectory();
    final objectDirectory = Directory(
      _join(
        account.path,
        'objects',
        normalizedHash.substring(0, 2),
        normalizedHash.substring(2, 4),
      ),
    );
    return CacheObjectPaths(
      objectFile: File(_join(objectDirectory.path, normalizedHash)),
      partFile: File(_join(objectDirectory.path, '$normalizedHash.part')),
    );
  }

  Future<File> objectFile(String hash) async => (await paths(hash)).objectFile;

  Future<File> partFile(String hash) async {
    final part = (await paths(hash)).partFile;
    await part.parent.create(recursive: true);
    return part;
  }

  Future<File?> lookup(String hash, {int? expectedSize}) async {
    if (expectedSize != null && expectedSize < 0) {
      throw ArgumentError.value(expectedSize, 'expectedSize');
    }
    final object = (await paths(hash)).objectFile;
    if (!await object.exists()) return null;
    if (expectedSize != null && await object.length() != expectedSize) {
      return null;
    }
    return object;
  }

  /// Enumerates only canonical final object files for this account.
  ///
  /// The walk is intentionally limited to `objects/<AA>/<BB>/<HASH>` and
  /// never follows a symlink. Unknown entries, temporary parts and malformed
  /// names are ignored. The result is sorted by hash because directory
  /// iteration order is not stable across platforms.
  Future<List<CacheObjectCandidate>> enumerateFinalObjects() async {
    final account = await accountDirectory();
    if (!await _isDirectoryWithoutFollowingLinks(account.path)) {
      return const <CacheObjectCandidate>[];
    }

    final objects = Directory(_join(account.path, 'objects'));
    if (!await _isDirectoryWithoutFollowingLinks(objects.path)) {
      return const <CacheObjectCandidate>[];
    }

    final candidates = <CacheObjectCandidate>[];
    final firstLevel = await objects.list(followLinks: false).toList();
    firstLevel.sort(_compareEntities);
    for (final first in firstLevel) {
      final firstName = p.basename(first.path);
      if (!_uppercaseHexPair.hasMatch(firstName) ||
          !await _isDirectoryWithoutFollowingLinks(first.path)) {
        continue;
      }

      final secondDirectory = Directory(first.path);
      final secondLevel = await secondDirectory
          .list(followLinks: false)
          .toList();
      secondLevel.sort(_compareEntities);
      for (final second in secondLevel) {
        final secondName = p.basename(second.path);
        if (!_uppercaseHexPair.hasMatch(secondName) ||
            !await _isDirectoryWithoutFollowingLinks(second.path)) {
          continue;
        }

        final objectDirectory = Directory(second.path);
        final entries = await objectDirectory.list(followLinks: false).toList();
        entries.sort(_compareEntities);
        for (final entry in entries) {
          final name = p.basename(entry.path);
          if (!_uppercaseCloudHash.hasMatch(name) ||
              !name.startsWith(firstName) ||
              name.substring(2, 4) != secondName ||
              await FileSystemEntity.type(entry.path, followLinks: false) !=
                  FileSystemEntityType.file) {
            continue;
          }
          candidates.add(
            CacheObjectCandidate(file: File(entry.path), hash: name),
          );
        }
      }
    }

    candidates.sort((left, right) {
      final byHash = left.hash.compareTo(right.hash);
      return byHash == 0 ? left.file.path.compareTo(right.file.path) : byHash;
    });
    return List.unmodifiable(candidates);
  }

  /// Revalidates a discovered candidate without opening or hashing its
  /// contents. This is used immediately before ownership queries and again
  /// before deletion to close the enumeration/race window.
  Future<bool> isCanonicalFinalObject(CacheObjectCandidate candidate) async {
    final normalizedHash = normalizeCloudHash(candidate.hash);
    if (candidate.hash != normalizedHash) return false;
    final expected = await objectFile(normalizedHash);
    if (candidate.file.path != expected.path) return false;
    final type = await FileSystemEntity.type(
      candidate.file.path,
      followLinks: false,
    );
    return type == FileSystemEntityType.file;
  }

  /// Moves a caller-verified part into the content-addressed object path.
  ///
  /// The cache deliberately does not calculate or verify the content hash.
  /// The optional part argument is normally the value returned by
  /// [partFile]. A same-directory rename keeps the commit streaming and
  /// atomic when there is no previous object.
  Future<void> commit(String hash, [File? part]) async {
    final cachePaths = await paths(hash);
    final source = part ?? (await partFile(hash));
    await cachePaths.objectFile.parent.create(recursive: true);
    if (await cachePaths.objectFile.exists()) {
      if (source.path != cachePaths.objectFile.path && await source.exists()) {
        await source.delete();
      }
      return;
    }
    if (source.path == cachePaths.objectFile.path) {
      throw FileSystemException(
        'Cache object does not exist.',
        cachePaths.objectFile.path,
      );
    }
    if (!await source.exists()) {
      throw FileSystemException('Cache part does not exist.', source.path);
    }

    try {
      await source.rename(cachePaths.objectFile.path);
    } on FileSystemException {
      // Another writer may have completed the same object between the
      // existence check and rename. Do not leave a duplicate part behind.
      if (!await cachePaths.objectFile.exists()) rethrow;
      if (await source.exists()) await source.delete();
    }
  }

  Future<void> discardObject(String hash) async {
    final object = (await paths(hash)).objectFile;
    if (await object.exists()) await object.delete();
  }
}

final _uppercaseHexPair = RegExp(r'^[0-9A-F]{2}$');
final _uppercaseCloudHash = RegExp(r'^[0-9A-F]{40}$');

Future<bool> _isDirectoryWithoutFollowingLinks(String path) async =>
    await FileSystemEntity.type(path, followLinks: false) ==
    FileSystemEntityType.directory;

int _compareEntities(FileSystemEntity left, FileSystemEntity right) =>
    left.path.compareTo(right.path);

String accountCacheKey(String email) =>
    sha256.convert(utf8.encode(email.trim().toLowerCase())).toString();

String normalizeCloudHash(String hash) {
  final normalized = hash.trim().toUpperCase();
  if (!RegExp(r'^[0-9A-F]{40}$').hasMatch(normalized)) {
    throw ArgumentError.value(
      hash,
      'hash',
      'Expected a 40-character hex hash.',
    );
  }
  return normalized;
}

String _join(String base, String child, [String? child2, String? child3]) {
  var result = base;
  for (final part in [child, child2, child3]) {
    if (part == null) continue;
    if (!result.endsWith(Platform.pathSeparator)) {
      result += Platform.pathSeparator;
    }
    result += part;
  }
  return result;
}
