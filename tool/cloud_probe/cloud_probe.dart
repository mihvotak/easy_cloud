import 'dart:io';

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
  if ((options.command == 'upload' || options.command == 'roundtrip') &&
      !options.hasFlag('confirm-write')) {
    stderr.writeln(
      '${options.command} requires the explicit --confirm-write flag.',
    );
    exitCode = 2;
    return;
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
--confirm-write flag is present.
''');
}
