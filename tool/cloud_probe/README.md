# Cloud probe

The probe verifies the reverse-engineered Cloud Mail.ru contract without
persisting credentials or session data.

Run from the `easy_cloud` directory:

```bash
dart run tool/cloud_probe/cloud_probe.dart help
dart run tool/cloud_probe/cloud_probe.dart login
dart run tool/cloud_probe/cloud_probe.dart suite
dart run tool/cloud_probe/cloud_probe.dart root
dart run tool/cloud_probe/cloud_probe.dart stat /Documents/example.txt
dart run tool/cloud_probe/cloud_probe.dart sort-matrix
```

Credentials can be entered interactively. For local automation, use environment
variables:

```bash
export CLOUD_MAIL_EMAIL='probe-account@mail.ru'
export CLOUD_MAIL_APP_PASSWORD='application-password'
dart run tool/cloud_probe/cloud_probe.dart dispatcher
```

The aliases `MAILRU_CLOUD_EMAIL` and `MAILRU_CLOUD_PASS` are also accepted.

Prefer `suite` for initial contract verification. It asks for credentials once
and runs only read-only checks: login, refresh, CSRF, dispatchers, root listing,
and legacy search. A failed optional capability is reported without preventing
the remaining checks.

To include stat, history, Range, and a verified temporary download:

```bash
dart run tool/cloud_probe/cloud_probe.dart suite --remote-file /EasyCloudProbe/probe.txt
```

The downloaded content is stored under the operating system temporary
directory and removed before the probe exits.

The optional `.cloud_probe_account` file contains only the test email and is
ignored by Git. The application password is still entered once with hidden
terminal echo and retained only in process memory.

Run the complete contract test, including upload and cleanup, with one password
prompt:

```bash
dart run tool/cloud_probe/cloud_probe.dart roundtrip --confirm-write
```

The command generates a unique root-level remote filename, uses
`conflict=strict`, verifies stat/history/Range/download, and then moves only the
file created by that run to trash.

Run the destructive conflict capability probe only against the dedicated test
account:

```bash
dart run tool/cloud_probe/cloud_probe.dart conflict-roundtrip --confirm-write
```

This command creates two distinct temporary fixtures, registers A at a unique
original path, verifies that `strict` rejects B without changing A, verifies
`rewrite` replaces the generated original with B, and verifies `rename` returns
an adjacent server-selected path whose stat matches A. It then removes only the
generated original, B seed, and renamed output paths. The command itself
generates the paths and accepts no conflict-mode or remote-path override.
`rewrite` is intentionally destructive even though every path is unique: use a
test account whose probe files may be replaced and deleted. Live capability
results are dated in the command output and are not assumed by this README.

To verify the 0/1/2/20/21-byte protocol boundary and clean up every generated
path, run:

```bash
dart run tool/cloud_probe/cloud_probe.dart tiny-roundtrip --confirm-write
```

Do not put these variables in a committed `.env` file, shell script, IDE launch
configuration, or test fixture. The password is intentionally not accepted as
a command-line argument because command lines may be visible to other processes.

Search is a legacy experiment:

```bash
dart run tool/cloud_probe/cloud_probe.dart search report --path /Documents
```

Folder sorting can be checked without modifying cloud content:

```bash
dart run tool/cloud_probe/cloud_probe.dart sort-matrix --path /
dart run tool/cloud_probe/cloud_probe.dart root --sort mtime --order desc
```

Upload modifies the test account and requires an explicit confirmation flag:

```bash
dart run tool/cloud_probe/cloud_probe.dart upload ./probe.txt /EasyCloudProbe/probe.txt --confirm-write
```

Use only a dedicated test account and a unique remote path. A standalone upload
does not delete its file and never uses an overwrite conflict mode.

The currently configured account is dedicated to protocol testing. Its cloud
files may be created, replaced, moved, or deleted by future probe scenarios.
Credentials remain subject to the storage rules above.
