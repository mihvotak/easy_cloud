# Download flow

## Implemented protocol

1. Authenticate and acquire CSRF.
2. Resolve a short-lived download shard:

   ```text
   GET https://dispatcher.cloud.mail.ru/d?token=<access token>
   ```

3. Take the first whitespace-delimited field as the shard URL.
4. Build the download URL from the shard and percent-encoded cloud path.
5. Send:

   ```text
   GET <shard>/<path>?client_id=cloud-win&token=<access token>
   User-Agent: cloud-win
   Accept-Encoding: identity
   ```

6. Stream to `<destination>.part`.
7. Flush and close the temporary file.
8. Verify expected size and cloud hash when metadata is available.
9. Atomically rename the temporary file to the destination.

The application resolves only HTTPS shards under trusted Mail.ru download
domains. Loopback HTTP is accepted only by local transport tests. The probe
follows the same temporary-file rule and refuses to overwrite an existing
destination unless `--overwrite` is passed.

## Application cache

Downloaded objects are private application-support files:

```text
cloud_cache/<sha256-normalized-email>/objects/AA/BB/<CLOUD_HASH>
```

The account directory prevents metadata and ready-state reuse after an account
switch. Operations for the same account and content hash are serialized, so a
shared `.part` cannot be truncated or committed concurrently. An existing final
object is accepted only after size and Mail.ru cloud-hash verification.

Verified objects are registered in `cloud_cache/offline_file_index.sqlite`.
The index stores only the account hash, normalized remote path, display name,
cloud hash, size, revisions and timestamps. It never stores raw email addresses,
OAuth credentials or local object paths. Records are written after a verified
cache hit or atomic commit and are shown in the account-scoped «Офлайн-файлы»
screen.

## Resume experiment

The binary transport resumes a useful `.part` with HTTP `Range`. Probe command
`range` requests a small byte interval and records:

```text
HTTP status, Accept-Ranges, Content-Range, Content-Length, response shape
```

Production returned a valid `206`, `Accept-Ranges: bytes`, and matching
`Content-Range` on 2026-09-09. A `200` response to a Range request makes the
client truncate the part and restart from byte zero; `416` does the same once.

## Integrity

Mail.ru cloud hash:

```text
size <= 20: content followed by zero bytes to exactly 20 bytes, uppercase hex
size > 20:  SHA1("mrCloud" + content + decimal size), uppercase hex
```

The implementation is streaming for files over 20 bytes. Local and remote hash
must not be treated as equivalent until live vectors have been compared.

## Failure rules

- Never retain a final file after an incomplete response.
- Preserve a useful `.part` only after Range support is confirmed.
- Re-resolve the shard after authorization, redirect, or shard failures.
- Retry authentication and transient shard resolution at most once each.
- Reject responses that exceed metadata size before writing the excess chunk.
- Cancel active operations and clear download UI state when the account changes.
- Do not log shard URLs before removing their token query parameters.
- Treat disk-full and integrity failures separately from network failures.

## Live checklist

- [x] `/d` response grammar and shard URL extraction confirmed.
- [x] Leading slash and Unicode path encoding covered by transport tests.
- [x] Root-level ASCII path encoding confirmed.
- [ ] Redirect behavior confirmed independently.
- [x] A 94-byte file hash matched upload, stat, and downloaded content.
- [ ] Boundary and large production file hashes confirmed.
- [ ] Zero-byte and 1-20-byte files tested.
- [x] Range support confirmed with a 32-byte partial response.
- [x] Interrupted download leaves no final file; a useful partial file may be
  retained for a validated resume.
