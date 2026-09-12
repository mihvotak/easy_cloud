import 'dart:io';

final class ProbeOptions {
  ProbeOptions({
    required this.command,
    required this.positionals,
    required this.values,
    required this.flags,
  });

  factory ProbeOptions.parse(List<String> arguments) {
    String? command;
    final positionals = <String>[];
    final values = <String, String>{};
    final flags = <String>{};

    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (!argument.startsWith('--')) {
        if (command == null) {
          command = argument;
        } else {
          positionals.add(argument);
        }
        continue;
      }

      final separator = argument.indexOf('=');
      if (separator > 2) {
        values[argument.substring(2, separator)] = argument.substring(
          separator + 1,
        );
        continue;
      }

      final name = argument.substring(2);
      if (index + 1 < arguments.length &&
          !arguments[index + 1].startsWith('--') &&
          _valueOptions.contains(name)) {
        values[name] = arguments[++index];
      } else {
        flags.add(name);
      }
    }

    return ProbeOptions(
      command: command ?? 'help',
      positionals: positionals,
      values: values,
      flags: flags,
    );
  }

  final String command;
  final List<String> positionals;
  final Map<String, String> values;
  final Set<String> flags;

  String get clientId =>
      values['client-id'] ??
      Platform.environment['CLOUD_MAIL_CLIENT_ID'] ??
      'cloud-win';

  Uri get oauthUrl => Uri.parse(
    values['oauth-url'] ??
        Platform.environment['CLOUD_MAIL_OAUTH_URL'] ??
        'https://o2.mail.ru/token',
  );

  Uri get apiUrl => _directoryUri(
    values['api-url'] ??
        Platform.environment['CLOUD_MAIL_API_URL'] ??
        'https://cloud.mail.ru/api/v2/',
  );

  Uri get dispatcherUrl => _directoryUri(
    values['dispatcher-url'] ??
        Platform.environment['CLOUD_MAIL_DISPATCHER_URL'] ??
        'https://dispatcher.cloud.mail.ru/',
  );

  String? get email {
    final configured =
        values['email'] ??
        Platform.environment['CLOUD_MAIL_EMAIL'] ??
        Platform.environment['MAILRU_CLOUD_EMAIL'];
    if (configured != null && configured.trim().isNotEmpty) return configured;

    final accountFile = File('.cloud_probe_account');
    if (!accountFile.existsSync()) return null;
    final account = accountFile.readAsStringSync().trim();
    return account.isEmpty ? null : account;
  }

  bool hasFlag(String name) => flags.contains(name);

  String? value(String name) => values[name];

  static Uri _directoryUri(String value) {
    final normalized = value.endsWith('/') ? value : '$value/';
    return Uri.parse(normalized);
  }
}

const _valueOptions = <String>{
  'api-url',
  'client-id',
  'dispatcher-url',
  'email',
  'end',
  'limit',
  'oauth-url',
  'offset',
  'order',
  'path',
  'remote-file',
  'start',
  'sort',
};
