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

5. Parse the first response field as a 40-character hexadecimal hash. Some
   references allow `<hash>;<size>`.
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

Observed conflict strings include `strict`, `rename`, and `rewrite`. Their
semantics differ between reference code and the `tucha` emulator. The probe
uses only `strict` unless another mode is explicitly added for a dedicated test
account. Production editing must perform a fresh `stat` before replacement and
show a conflict UI instead of silently using `rewrite`.

An uploaded but unregistered content object may remain after a failed
`file/add`; this is preferable to overwriting an existing path.

## Live checklist

- [x] `/u` response grammar and upload shard extraction confirmed.
- [ ] Empty and small uploads tested.
- [x] Upload response hash matches the local hash for the fixture.
- [x] `file/add` root-level leading slash handling confirmed.
- [ ] `strict` rejects an existing path without modifying it.
- [x] Successful registration is confirmed by `stat`.
- [ ] Maximum practical size and timeout behavior measured separately.
