import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:easy_cloud/cloud_mail/probe/cloud_hash.dart';

import 'probe_client.dart';
import 'probe_options.dart';

Future<void> main(List<String> arguments) async {
  final options = ProbeOptions.parse(arguments);
  if (options.command == 'help' || options.hasFlag('help')) {
    _printUsage();
    return;
  }
  if (!_commands.contains(options.command)) {
    stderr.writeln('Unknown command: ${options.command}');
    _printUsage();
    exitCode = 2;
    return;
  }
  if ((options.command == 'upload' ||
          options.command == 'roundtrip' ||
          options.command == 'tiny-roundtrip') &&
      !options.hasFlag('confirm-write')) {
    stderr.writeln(
      '${options.command} requires the explicit --confirm-write flag.',
    );
    exitCode = 2;
    return;
  }
  if (options.command == 'conflict-roundtrip') {
    if (!options.hasFlag('confirm-write')) {
      stderr.writeln(
        'conflict-roundtrip requires the exact --confirm-write flag.',
      );
      exitCode = 2;
      return;
    }
    if (options.positionals.isNotEmpty ||
        options.value('remote-file') != null ||
        options.hasFlag('remote-file') ||
        options.hasFlag('conflict')) {
      stderr.writeln(
        'conflict-roundtrip generates its own paths and does not accept '
        'positional paths or conflict overrides.',
      );
      exitCode = 2;
      return;
    }
  }

  final client = CloudProbeClient(options);
  try {
    final credentials = _readCredentials(options);
    var session = await client.login(credentials.email, credentials.password);
    stdout.writeln(
      'login succeeded: client_id=${options.clientId}, expires_in=${session.expiresIn ?? 'unknown'}, refresh_token=${session.refreshToken == null ? 'absent' : 'present'}',
    );

    if (options.command == 'login') return;
    if (options.command == 'refresh') {
      session = await client.refresh(session);
      stdout.writeln(
        'refresh succeeded: expires_in=${session.expiresIn ?? 'unknown'}',
      );
      return;
    }
    if (options.command == 'suite') {
      await _runReadOnlySuite(client, session, options);
      return;
    }
    if (options.command == 'roundtrip') {
      await _runRoundtrip(client, session, options);
      return;
    }
    if (options.command == 'conflict-roundtrip') {
      await _runConflictRoundtrip(client, session);
      return;
    }
    if (options.command == 'tiny-roundtrip') {
      await _runTinyRoundtrip(client, session);
      return;
    }

    await client.acquireCsrf(session);
    stdout.writeln('csrf succeeded');

    switch (options.command) {
      case 'csrf':
        return;
      case 'dispatcher':
        await client.probeDispatcher(session);
      case 'root':
        await client.listFolder(
          session,
          '/',
          offset: _integerOption(options, 'offset', 0),
          limit: _integerOption(options, 'limit', 100),
          sortType: options.value('sort') ?? 'name',
          sortOrder: options.value('order') ?? 'asc',
        );
      case 'list':
        await client.listFolder(
          session,
          _positional(options, 0, 'remote path'),
          offset: _integerOption(options, 'offset', 0),
          limit: _integerOption(options, 'limit', 100),
          sortType: options.value('sort') ?? 'name',
          sortOrder: options.value('order') ?? 'asc',
        );
      case 'sort-matrix':
        await client.probeSortMatrix(
          session,
          options.value('path') ?? '/',
          limit: _integerOption(options, 'limit', 100),
        );
      case 'stat':
        await client.stat(session, _positional(options, 0, 'remote path'));
      case 'search':
        await client.search(
          session,
          _positional(options, 0, 'query'),
          path: options.value('path') ?? '/',
          limit: _integerOption(options, 'limit', 100),
        );
      case 'range':
        await client.probeRange(
          session,
          _positional(options, 0, 'remote path'),
          start: _integerOption(options, 'start', 0),
          end: _integerOption(options, 'end', 31),
        );
      case 'download':
        await client.download(
          session,
          _positional(options, 0, 'remote path'),
          File(_positional(options, 1, 'local destination')),
          overwrite: options.hasFlag('overwrite'),
        );
      case 'upload':
        await client.upload(
          session,
          File(_positional(options, 0, 'local source')),
          _positional(options, 1, 'remote path'),
        );
      case 'history':
        await client.history(session, _positional(options, 0, 'remote path'));
      default:
        throw ProbeException('Unknown command: ${options.command}');
    }
  } on ProbeException catch (error) {
    stderr.writeln('Probe failed: $error');
    exitCode = 2;
  } on SocketException catch (error) {
    stderr.writeln(
      'Network failure: ${error.osError?.message ?? 'connection failed'}',
    );
    exitCode = 3;
  } on HandshakeException {
    stderr.writeln('TLS handshake failed.');
    exitCode = 3;
  } on HttpException {
    stderr.writeln('HTTP protocol failure.');
    exitCode = 3;
  } on FormatException {
    stderr.writeln('The service returned an invalid response format.');
    exitCode = 4;
  } catch (error) {
    stderr.writeln('Unexpected probe failure (${error.runtimeType}).');
    exitCode = 4;
  } finally {
    client.close();
  }
}

const _commands = <String>{
  'login',
  'suite',
  'roundtrip',
  'conflict-roundtrip',
  'tiny-roundtrip',
  'refresh',
  'csrf',
  'dispatcher',
  'root',
  'list',
  'sort-matrix',
  'stat',
  'search',
  'range',
  'download',
  'upload',
  'history',
};

Future<OAuthSession> _runReadOnlySuite(
  CloudProbeClient client,
  OAuthSession session,
  ProbeOptions options, {
  bool includeRemoteFile = true,
}) async {
  session = await _prepareReadOnlySession(client, session);

  await _runOptionalCheck('dispatcher', () => client.probeDispatcher(session));
  await _runOptionalCheck(
    'root',
    () => client.listFolder(
      session,
      '/',
      offset: _integerOption(options, 'offset', 0),
      limit: _integerOption(options, 'limit', 100),
    ),
  );
  await _runOptionalCheck(
    'legacy search',
    () => client.search(
      session,
      options.positionals.firstOrNull ?? 'a',
      path: options.value('path') ?? '/',
      limit: _integerOption(options, 'limit', 100),
    ),
  );

  final remoteFile = includeRemoteFile ? options.value('remote-file') : null;
  if (remoteFile != null) await _runFileChecks(client, session, remoteFile);
  return session;
}

Future<OAuthSession> _prepareReadOnlySession(
  CloudProbeClient client,
  OAuthSession session,
) async {
  stdout.writeln('\n=== refresh ===');
  try {
    session = await client.refresh(session);
    stdout.writeln(
      'refresh succeeded: expires_in=${session.expiresIn ?? 'unknown'}',
    );
  } on ProbeException catch (error) {
    stdout.writeln('refresh unsupported or failed: $error');
    stdout.writeln('continuing with the original access token');
  }

  stdout.writeln('\n=== csrf ===');
  await client.acquireCsrf(session);
  stdout.writeln('csrf succeeded');
  return session;
}

Future<void> _runRoundtrip(
  CloudProbeClient client,
  OAuthSession session,
  ProbeOptions options,
) async {
  session = await _runReadOnlySuite(
    client,
    session,
    options,
    includeRemoteFile: false,
  );
  final remoteFile =
      options.value('remote-file') ??
      '/easy-cloud-probe-${DateTime.now().millisecondsSinceEpoch}.txt';
  final fixture = File('tool/cloud_probe/fixtures/probe.txt');
  var registered = false;

  stdout.writeln('\n=== upload ===');
  try {
    await client.upload(session, fixture, remoteFile);
    registered = true;
    stdout.writeln('upload succeeded');
    await _runFileChecks(client, session, remoteFile);
  } finally {
    if (registered) {
      stdout.writeln('\n=== cleanup ===');
      try {
        await client.removeFile(session, remoteFile);
        stdout.writeln('remote probe file moved to trash');
      } on ProbeException catch (error) {
        stdout.writeln('cleanup failed: $error');
        stdout.writeln('remove the generated root-level probe file manually');
      }
    }
  }
}

Future<void> _runConflictRoundtrip(
  CloudProbeClient client,
  OAuthSession session,
) async {
  final startedAt = DateTime.now().toUtc();
  final createdPaths = <String>{};
  final fixtureDirectory = await Directory.systemTemp.createTemp(
    'easy-cloud-conflict-probe-',
  );
  Object? operationError;
  StackTrace? operationStack;
  var cleanupFailed = false;

  try {
    stdout.writeln('\n=== conflict-roundtrip ===');
    stdout.writeln('capability probe date: ${startedAt.toIso8601String()}');

    await client.acquireCsrf(session);
    stdout.writeln('csrf succeeded');

    final nonce = _conflictProbeNonce();
    final originalPath = '/easy-cloud-conflict-probe-$nonce.txt';
    final seedPath = '/easy-cloud-conflict-probe-$nonce-seed.txt';
    final fixtureA = File(
      '${fixtureDirectory.path}${Platform.pathSeparator}a.txt',
    );
    final fixtureB = File(
      '${fixtureDirectory.path}${Platform.pathSeparator}b.txt',
    );
    await fixtureA.writeAsString('easy-cloud conflict fixture A $nonce\n');
    await fixtureB.writeAsString(
      'easy-cloud conflict fixture B $nonce has distinct content\n',
    );
    final expectedA = await _localIdentity(fixtureA);
    final expectedB = await _localIdentity(fixtureB);
    if (expectedA.hash == expectedB.hash || expectedA.size == expectedB.size) {
      throw ProbeException('Conflict fixtures did not remain distinct.');
    }
    stdout.writeln(
      'fixtures ready: A=${expectedA.size} bytes/${expectedA.hash}, '
      'B=${expectedB.size} bytes/${expectedB.hash}',
    );

    stdout.writeln('\n=== strict: create original with A ===');
    final uploadedA = await client.uploadContent(session, fixtureA);
    _requireIdentityEquals(uploadedA, expectedA, 'fixture A upload');
    final addA = await client.registerByIdentity(
      session,
      uploadedA,
      originalPath,
      conflict: FileConflict.strict,
    );
    _requireFileAddSuccess(addA, 'strict registration of fixture A');
    createdPaths.add(originalPath);
    await _verifyRemoteMetadata(
      client,
      session,
      originalPath,
      expectedA,
      label: 'original after A',
    );

    stdout.writeln('\n=== seed B at a temporary path ===');
    final uploadedB = await client.uploadContent(session, fixtureB);
    _requireIdentityEquals(uploadedB, expectedB, 'fixture B upload');
    final addSeed = await client.registerByIdentity(
      session,
      uploadedB,
      seedPath,
      conflict: FileConflict.strict,
    );
    _requireFileAddSuccess(addSeed, 'strict registration of fixture B seed');
    createdPaths.add(seedPath);
    await _verifyRemoteMetadata(
      client,
      session,
      seedPath,
      expectedB,
      label: 'temporary B seed',
    );

    stdout.writeln('\n=== strict conflict ===');
    final strictConflict = await client.registerByIdentity(
      session,
      uploadedB,
      originalPath,
      conflict: FileConflict.strict,
    );
    if (strictConflict.error != FileAddError.exists) {
      throw ProbeException(
        'strict conflict did not reject as exists '
        '(classification=${_fileAddClassification(strictConflict)}, '
        'HTTP ${strictConflict.statusCode}).',
      );
    }
    stdout.writeln(
      'strict conflict rejected as exists: path=$originalPath, '
      'HTTP ${strictConflict.statusCode}',
    );
    await _verifyRemoteMetadata(
      client,
      session,
      originalPath,
      expectedA,
      label: 'original after strict rejection',
    );

    stdout.writeln('\n=== rewrite conflict ===');
    final rewrite = await client.registerByIdentity(
      session,
      uploadedB,
      originalPath,
      conflict: FileConflict.rewrite,
    );
    _requireFileAddSuccess(rewrite, 'rewrite registration of fixture B');
    if (rewrite.returnedPath != null && rewrite.returnedPath != originalPath) {
      throw ProbeException(
        'rewrite returned an unexpected safe path: ${rewrite.returnedPath}',
      );
    }
    stdout.writeln(
      'rewrite succeeded: path=$originalPath, '
      'returned=${rewrite.returnedPath ?? 'not reported'}',
    );
    await _verifyRemoteMetadata(
      client,
      session,
      originalPath,
      expectedB,
      label: 'original after rewrite',
    );
    await _reportRewriteHistory(client, session, originalPath, expectedB);

    stdout.writeln('\n=== rename conflict ===');
    final rename = await client.registerByIdentity(
      session,
      uploadedA,
      originalPath,
      conflict: FileConflict.rename,
    );
    _requireFileAddSuccess(rename, 'rename registration of fixture A');
    final renamedPath = rename.returnedPath;
    if (renamedPath == null) {
      throw ProbeException(
        'rename succeeded without a safe server-selected path.',
      );
    }
    createdPaths.add(renamedPath);
    if (renamedPath == originalPath) {
      throw ProbeException('rename returned the original path.');
    }
    if (!_areAdjacentPaths(originalPath, renamedPath)) {
      throw ProbeException(
        'rename returned a path outside the original folder.',
      );
    }
    if (renamedPath == seedPath) {
      throw ProbeException('rename returned the temporary seed path.');
    }
    final renamedBasename = _basename(renamedPath);
    final namingEvidence = renamedBasename.contains('(1)')
        ? 'expected "(1)" marker present'
        : RegExp(r'\(\d+\)').hasMatch(renamedBasename)
        ? 'server numeric conflict suffix present'
        : 'server-specific basename; no "(1)" marker required';
    stdout.writeln('rename selected: path=$renamedPath');
    stdout.writeln(
      'rename basename=${jsonEncode(renamedBasename)}; evidence=$namingEvidence',
    );
    await _verifyRemoteMetadata(
      client,
      session,
      renamedPath,
      expectedA,
      label: 'renamed A output',
    );
    await _verifyRemoteMetadata(
      client,
      session,
      originalPath,
      expectedB,
      label: 'original after rename',
    );

    stdout.writeln(
      'conflict capability probe completed: date=${startedAt.toIso8601String()}',
    );
  } catch (error, stack) {
    operationError = error;
    operationStack = stack;
  } finally {
    try {
      cleanupFailed = await _cleanupConflictPaths(
        client,
        session,
        createdPaths,
      );
    } catch (error) {
      cleanupFailed = true;
      stderr.writeln(
        'remote cleanup failed unexpectedly (runtime=${error.runtimeType}); '
        'generated paths may remain.',
      );
    }
    try {
      if (await fixtureDirectory.exists()) {
        await fixtureDirectory.delete(recursive: true);
      }
    } catch (error) {
      cleanupFailed = true;
      stderr.writeln(
        'local fixture cleanup failed (runtime=${error.runtimeType}); '
        'temporary content may remain.',
      );
    }
  }

  if (operationError != null) {
    Error.throwWithStackTrace(
      operationError,
      operationStack ?? StackTrace.current,
    );
  }
  if (cleanupFailed) {
    throw ProbeException(
      'Conflict roundtrip finished with cleanup failures; inspect the '
      'reported generated paths.',
    );
  }
}

Future<void> _runTinyRoundtrip(
  CloudProbeClient client,
  OAuthSession session,
) async {
  await client.acquireCsrf(session);
  final directory = await Directory.systemTemp.createTemp(
    'easy-cloud-tiny-probe-',
  );
  final createdPaths = <String>{};
  Object? operationError;
  StackTrace? operationStack;
  var cleanupFailed = false;
  try {
    final nonce = _conflictProbeNonce();
    for (final size in const [0, 1, 2, 20, 21]) {
      final fixture = File(
        '${directory.path}${Platform.pathSeparator}$size.bin',
      );
      await fixture.writeAsBytes(
        List<int>.generate(size, (index) => 0x41 + index % 26),
      );
      final expected = await _localIdentity(fixture);
      final path = '/easy-cloud-tiny-probe-$nonce-$size.txt';
      stdout.writeln('\n=== tiny upload: $size bytes ===');
      final uploaded = size <= 20
          ? expected
          : await client.uploadContent(session, fixture);
      _requireIdentityEquals(uploaded, expected, '$size-byte identity');
      final added = await client.registerByIdentity(
        session,
        uploaded,
        path,
        conflict: FileConflict.strict,
      );
      _requireFileAddSuccess(added, '$size-byte registration');
      createdPaths.add(path);
      await _verifyRemoteMetadata(
        client,
        session,
        path,
        expected,
        label: '$size-byte file',
      );
    }
  } catch (error, stack) {
    operationError = error;
    operationStack = stack;
  } finally {
    cleanupFailed = await _cleanupConflictPaths(client, session, createdPaths);
    try {
      await directory.delete(recursive: true);
    } catch (_) {
      cleanupFailed = true;
    }
  }
  if (operationError != null) {
    Error.throwWithStackTrace(
      operationError,
      operationStack ?? StackTrace.current,
    );
  }
  if (cleanupFailed) {
    throw ProbeException('Tiny roundtrip finished with cleanup failures.');
  }
}

Future<CloudFileIdentity> _localIdentity(File file) async => CloudFileIdentity(
  hash: await calculateCloudFileHash(file),
  size: await file.length(),
);

void _requireIdentityEquals(
  CloudFileIdentity actual,
  CloudFileIdentity expected,
  String label,
) {
  if (actual.hash != expected.hash || actual.size != expected.size) {
    throw ProbeException('$label did not preserve the local identity.');
  }
}

void _requireFileAddSuccess(FileAddResult result, String operation) {
  if (!result.succeeded) {
    throw ProbeException(
      '$operation failed (classification=${_fileAddClassification(result)}, '
      'HTTP ${result.statusCode}).',
    );
  }
}

String _fileAddClassification(FileAddResult result) =>
    result.error?.name ?? 'success';

Future<void> _verifyRemoteMetadata(
  CloudProbeClient client,
  OAuthSession session,
  String path,
  CloudFileIdentity expected, {
  required String label,
}) async {
  final metadata = await client.readMetadata(session, path);
  final actualHash = metadata.hash?.toUpperCase();
  if (metadata.size != expected.size || actualHash != expected.hash) {
    throw ProbeException(
      '$label stat mismatch (expected size=${expected.size}, '
      'hash=${expected.hash}).',
    );
  }
  stdout.writeln(
    'stat verified: $label path=$path size=${expected.size} hash=${expected.hash}',
  );
}

Future<void> _reportRewriteHistory(
  CloudProbeClient client,
  OAuthSession session,
  String path,
  CloudFileIdentity identity,
) async {
  stdout.writeln('\n=== history after rewrite ===');
  try {
    final response = await client.history(session, path);
    switch (_historyEvidence(response, identity)) {
      case _HistoryEvidence.hash:
        stdout.writeln('history: new B version visible (hash match)');
      case _HistoryEvidence.size:
        stdout.writeln(
          'history: new B version visible (size-only; hash omitted)',
        );
      case _HistoryEvidence.notVisible:
        stdout.writeln('history: new B version not visible');
      case _HistoryEvidence.unknown:
        stdout.writeln(
          'history: new B version visibility unknown (no comparable fields)',
        );
    }
  } on ProbeException {
    stdout.writeln(
      'history: new B version visibility unknown (unsupported/error)',
    );
  } on SocketException {
    stdout.writeln(
      'history: new B version visibility unknown (network failure)',
    );
  } catch (error) {
    stdout.writeln(
      'history: new B version visibility unknown (runtime=${error.runtimeType})',
    );
  }
}

enum _HistoryEvidence { hash, size, notVisible, unknown }

_HistoryEvidence _historyEvidence(
  ProbeResponse response,
  CloudFileIdentity identity,
) {
  Object? decoded;
  try {
    decoded = response.json;
  } on FormatException {
    return _HistoryEvidence.unknown;
  }
  if (decoded is! Map) return _HistoryEvidence.unknown;
  Object? body = decoded['body'];
  if (body is Map) body = body['list'];
  if (body is! List) return _HistoryEvidence.unknown;
  if (body.isEmpty) return _HistoryEvidence.notVisible;

  var comparable = false;
  var sizeMatch = false;
  for (final entry in body) {
    if (entry is! Map) continue;
    final hash = entry['hash'];
    if (hash is String) {
      comparable = true;
      if (hash.toUpperCase() == identity.hash) {
        return _HistoryEvidence.hash;
      }
    }
    final size = _historyInt(entry['size']);
    if (size != null) {
      comparable = true;
      if (size == identity.size) sizeMatch = true;
    }
  }
  if (sizeMatch) return _HistoryEvidence.size;
  return comparable ? _HistoryEvidence.notVisible : _HistoryEvidence.unknown;
}

int? _historyInt(Object? value) => switch (value) {
  int number => number,
  String text => int.tryParse(text),
  _ => null,
};

Future<bool> _cleanupConflictPaths(
  CloudProbeClient client,
  OAuthSession session,
  Set<String> paths,
) async {
  var failed = false;
  for (final path in paths.toList(growable: false).reversed) {
    stdout.writeln('cleanup: removing path=$path');
    try {
      await client.removeFile(session, path);
      stdout.writeln('cleanup succeeded: path=$path');
    } on ProbeException {
      failed = true;
      stderr.writeln('cleanup failed: path=$path (probe error)');
    } on SocketException {
      failed = true;
      stderr.writeln('cleanup failed: path=$path (network failure)');
    } on HandshakeException {
      failed = true;
      stderr.writeln('cleanup failed: path=$path (TLS failure)');
    } on HttpException {
      failed = true;
      stderr.writeln('cleanup failed: path=$path (HTTP protocol failure)');
    } catch (error) {
      failed = true;
      stderr.writeln(
        'cleanup failed: path=$path (runtime=${error.runtimeType})',
      );
    }
  }
  if (failed) {
    stderr.writeln(
      'cleanup incomplete: generated paths may remain; credentials and tokens '
      'were not printed.',
    );
  }
  return failed;
}

String _conflictProbeNonce() {
  final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch;
  final random = Random.secure().nextInt(0x7fffffff);
  return '$timestamp-${random.toRadixString(16).padLeft(8, '0')}';
}

bool _areAdjacentPaths(String first, String second) =>
    _parentPath(first) == _parentPath(second);

String _parentPath(String path) {
  final separator = path.lastIndexOf('/');
  return separator <= 0 ? '/' : path.substring(0, separator);
}

String _basename(String path) => path.substring(path.lastIndexOf('/') + 1);

Future<void> _runFileChecks(
  CloudProbeClient client,
  OAuthSession session,
  String remoteFile,
) async {
  await _runOptionalCheck('stat', () => client.stat(session, remoteFile));
  await _runOptionalCheck('history', () => client.history(session, remoteFile));
  await _runOptionalCheck(
    'range',
    () => client.probeRange(session, remoteFile),
  );
  await _runTemporaryDownload(client, session, remoteFile);
}

Future<void> _runTemporaryDownload(
  CloudProbeClient client,
  OAuthSession session,
  String remoteFile,
) async {
  stdout.writeln('\n=== download ===');
  final directory = await Directory.systemTemp.createTemp('easy-cloud-probe-');
  try {
    await client.download(
      session,
      remoteFile,
      File('${directory.path}${Platform.pathSeparator}download.bin'),
    );
    stdout.writeln('download succeeded; temporary local content removed');
  } on ProbeException catch (error) {
    stdout.writeln('download unsupported or failed: $error');
  } finally {
    await directory.delete(recursive: true);
  }
}

Future<void> _runOptionalCheck(
  String name,
  Future<void> Function() operation,
) async {
  stdout.writeln('\n=== $name ===');
  try {
    await operation();
    stdout.writeln('$name succeeded');
  } on ProbeException catch (error) {
    stdout.writeln('$name unsupported or failed: $error');
  }
}

({String email, String password}) _readCredentials(ProbeOptions options) {
  final email = options.email ?? _prompt('Mail.ru email: ');
  final password =
      Platform.environment['CLOUD_MAIL_APP_PASSWORD'] ??
      Platform.environment['MAILRU_CLOUD_PASS'] ??
      _promptSecret('Mail.ru application password: ');
  if (email.trim().isEmpty || password.isEmpty) {
    throw ProbeException('Email and application password are required.');
  }
  return (email: email.trim(), password: password);
}

String _prompt(String message) {
  stdout.write(message);
  return stdin.readLineSync()?.trim() ?? '';
}

String _promptSecret(String message) {
  stdout.write(message);
  final canHide = stdin.hasTerminal;
  if (canHide) stdin.echoMode = false;
  try {
    return stdin.readLineSync() ?? '';
  } finally {
    if (canHide) {
      stdin.echoMode = true;
      stdout.writeln();
    }
  }
}

String _positional(ProbeOptions options, int index, String label) {
  if (index >= options.positionals.length) {
    throw ProbeException('Missing $label for ${options.command}.');
  }
  return options.positionals[index];
}

int _integerOption(ProbeOptions options, String name, int fallback) {
  final raw = options.value(name);
  if (raw == null) return fallback;
  final value = int.tryParse(raw);
  if (value == null) throw ProbeException('--$name must be an integer.');
  return value;
}

void _printUsage() {
  stdout.writeln('''
Cloud Mail.ru contract probe

Usage:
  dart run tool/cloud_probe/cloud_probe.dart <command> [arguments] [options]

Commands:
  login
  suite [search-query] [--path /scope] [--remote-file /file] [--limit N]
  roundtrip --confirm-write [--remote-file /unique-test-file.txt]
  conflict-roundtrip --confirm-write
  tiny-roundtrip --confirm-write
  refresh
  csrf
  dispatcher
  root [--offset N] [--limit N] [--sort name|size|mtime] [--order asc|desc]
  list <remote-path> [--offset N] [--limit N] [--sort name|size|mtime] [--order asc|desc]
  sort-matrix [--path /scope] [--limit N]
  stat <remote-path>
  search <query> [--path /scope] [--limit N]
  range <remote-path> [--start N] [--end N]
  download <remote-path> <local-path> [--overwrite]
  upload <local-path> <remote-path> --confirm-write
  history <remote-path>

Credentials:
  CLOUD_MAIL_EMAIL
  CLOUD_MAIL_APP_PASSWORD
  .cloud_probe_account      local ignored file containing only the email

Protocol overrides:
  CLOUD_MAIL_CLIENT_ID       default: cloud-win
  CLOUD_MAIL_OAUTH_URL       default: https://o2.mail.ru/token
  CLOUD_MAIL_API_URL         default: https://cloud.mail.ru/api/v2/
  CLOUD_MAIL_DISPATCHER_URL  default: https://dispatcher.cloud.mail.ru/

The application password cannot be passed as a command-line option. Tokens and
passwords are redacted from request logs. Upload is disabled unless the exact
--confirm-write flag is present. conflict-roundtrip is destructive: it creates,
replaces, renames, and deletes probe files; use it only with the dedicated test
account. It generates all remote paths itself and never accepts a conflict mode
from the command line.
''');
}
