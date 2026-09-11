# Upload flow

Upload changes cloud state. The probe requires `--confirm-write` and uses
`conflict=strict` by default.

## Candidate protocol

1. Read the local file size and calculate its Mail.ru cloud hash.
2. Optionally try deduplication by calling `file/add` with the hash and size.
   This optimization is disabled in the initial probe to keep behavior clear.
3. Resolve the upload shard:

   ```text
   GET https://dispatcher.cloud.mail.ru/u?token=<access token>
   ```

4. Upload raw bytes:

   ```text
   PUT <upload-shard>?client_id=cloud-win&token=<access token>
   Content-Length: <size>
   Content-Type: application/octet-stream
   ```

5. Parse the complete trimmed response as exactly a 40-character hexadecimal
   hash or `<hash>;<decimal size>`; when the optional size is present it must
   equal the local size.
6. Require the server hash to equal the locally calculated hash.
7. Register the object:

   ```text
   POST https://cloud.mail.ru/api/v2/file/add?access_token=<token>
   X-CSRF-Token: <csrf>
   Content-Type: application/x-www-form-urlencoded

   api=2
   conflict=strict
   home=/<remote path>
   hash=<server hash>
   size=<size>
   ```

8. Run `stat` and verify path, size, and hash.

This complete sequence was confirmed in production on 2026-09-09 with a
94-byte fixture. The upload shard returned HTTP 201 and the same cloud hash as
the local streaming implementation. `file/add` returned an API envelope with a
string body, and stat confirmed the registered size and hash.

## Conflict safety

Production probing on 2026-09-11 confirmed all three conflict modes on the
dedicated test account. `strict` rejected an existing path without changing
it, `rewrite` replaced the path and created a history version, and `rename`
returned the adjacent server-selected path with a ` (1)` suffix. Production
editing must still perform a fresh `stat` before replacement and show a
conflict UI instead of silently using `rewrite`.

An uploaded but unregistered content object may remain after a failed
`file/add`; this is preferable to overwriting an existing path.

## Destructive conflict roundtrip

The dedicated live probe was successfully run on 2026-09-11:

```text
dart run tool/cloud_probe/cloud_probe.dart conflict-roundtrip --confirm-write
```

It logs in once, creates two distinct small local fixtures, seeds B at a unique
temporary path, and checks the following sequence against a unique original:

1. `strict` creates A and a stat confirms A's hash and size.
2. `strict` rejects B with an `exists` classification and the original remains A.
3. `rewrite` registers B at the original and a stat confirms B.
4. History is checked best-effort for a visible B version.
5. `rename` registers A and must return a distinct adjacent server-selected path;
   the exact sanitized basename and any `(1)` evidence are reported.
6. Finally, only the original, temporary B seed, and returned renamed path are
   removed.

The exact `--confirm-write` flag is required. The live run stat-verified every
result, observed the rewritten file in history, and removed all three generated
remote paths successfully.

## Live checklist

- [x] `/u` response grammar and upload shard extraction confirmed.
- [ ] Empty and small uploads tested.
- [x] Upload response hash matches the local hash for the fixture.
- [x] `file/add` root-level leading slash handling confirmed.
- [x] `strict` rejects an existing path without modifying it.
- [x] Dedicated `conflict-roundtrip` confirms `strict`, `rewrite`, and `rename` live semantics.
- [x] Successful registration is confirmed by `stat`.
- [ ] Maximum practical size and timeout behavior measured separately.
