# Easy Cloud

Easy Cloud is a dark Android-first Flutter client for personal Cloud Mail.ru
storage. It uses the reverse-engineered web API behind an isolated Dart layer.

Implemented:

- OAuth login with a Mail.ru application password;
- CSRF acquisition and refresh-token rotation;
- encrypted session storage backed by Android Keystore;
- session restoration, serialized refresh, and logout;
- folder navigation with Android back handling and pull-to-refresh;
- server-side sorting by name, size, or modification time;
- paginated listings and file/folder metadata;
- server-side name search in the current folder with navigation from results;
- resumable streaming downloads with progress, cancellation, integrity checks,
  and an account-isolated content-addressed offline cache;
- sanitized protocol probe and live contract documentation under `docs/`.

The normal Mail.ru account password is not supported. Create an application
password with full mail, cloud, and calendar protocol access.

## Development

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

The debug APK is produced at:

```text
build/app/outputs/flutter-apk/app-debug.apk
```

See [`tool/cloud_probe/README.md`](tool/cloud_probe/README.md) for live API
contract checks. Never commit account passwords, OAuth tokens, or probe output
containing private file paths.
