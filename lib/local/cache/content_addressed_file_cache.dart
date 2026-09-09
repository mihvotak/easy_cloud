import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'application_cache_root.dart';

final class CacheObjectPaths {
  const CacheObjectPaths({required this.objectFile, required this.partFile});

  final File objectFile;
  final File partFile;
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
