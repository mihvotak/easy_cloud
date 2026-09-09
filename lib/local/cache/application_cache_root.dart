import 'dart:io';

import 'package:path_provider/path_provider.dart';

abstract interface class CacheRootProvider {
  Future<Directory> getRoot();
}

final class ApplicationCacheRoot implements CacheRootProvider {
  const ApplicationCacheRoot();

  @override
  Future<Directory> getRoot() => getApplicationSupportDirectory();
}

final class FixedCacheRoot implements CacheRootProvider {
  const FixedCacheRoot(this.directory);

  final Directory directory;

  @override
  Future<Directory> getRoot() async => directory;
}
