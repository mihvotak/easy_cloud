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

Foreground external opens do not create an `offline_files` binding. After
cryptographic verification they touch an account-scoped durable
`transient_objects` row (`hash`, `size`, `last_accessed_at`). Transient objects
use an exact 524288000-byte (500 MiB) per-account LRU; hashes with an offline
binding and the latest prepared open remain protected. A subsequent open makes
the previous prepared hash eligible again. Pruning removes only final CAS
objects, never `.part` files. Transient rows survive restart and are eligible
on the next prune. After an authenticated account attach, resume or account
sync, a deterministic reconciliation pass walks only canonical uppercase final
objects for that account. Each hash is checked under the same download lock
against direct/ready-target and transient references; only an unreferenced
object is deleted. The pass never reads or hashes object contents, follows
symlinks, touches `.part` files or changes SQLite ownership. Missing files are
successes; filesystem/reference failures leave the candidate in place, other
candidates continue in hash order, and the failure is retried on the next
resume. An enumeration error aborts before deletion. Reconciliation is
cancellable and awaited by repository shutdown.

«Сохранить как» uses the same verified foreground preparation and CAS path
validation as an external open, then launches Android SAF
`ACTION_CREATE_DOCUMENT`. The destination URI is written as a stream with
truncate semantics; the source is never loaded into memory and no storage
permission, staging copy or persistable URI grant is used. A cancelled picker
returns quietly. If a newer foreground action starts after the picker was
launched, Android cannot cancel that already-visible picker; its eventual
callback is nevertheless ignored by the stale Dart attempt and cannot show a
snackbar for the old action.

## Internal text editor

Supported final extensions are `txt`, `md`, `json`, `xml`, `yaml`, `yml`,
`csv`, `log`, `ini`, and `conf` (case-insensitive). Browser and search rows
prepare editor content through the same transient `startOpen` CAS path as an
external open; preparation never creates an offline marker or invokes the
platform opener. The verified bytes are decoded as strict UTF-8 first and as
Windows-1251 only when UTF-8 is malformed. A leading UTF-8 BOM is retained as
metadata and all line endings stay unchanged. The first save of a Windows-1251
file asks whether to preserve that encoding or convert to UTF-8, and remembers
the choice until the editor closes. Because Flutter EditableText lays out the
whole document, inline rendering is limited to 2 MiB to prevent Android
ANRs/crashes; larger files remain available through the external opener.

Saving captures the remote path, cloud hash, size, modification time, revision,
and global revision. A fresh stat is compared before upload. If the remote file
changed, the editor requires an explicit overwrite, adjacent-copy, or cancel
choice. An unknown post-registration outcome stays dirty and is never retried
automatically; a verified remote save may still report a local offline-ownership
failure as a partial success.

Successful online folder listings are stored as account-isolated paginated
snapshot generations. A multi-page refresh is staged separately, so the last
complete generation remains readable until its replacement is complete. On a
network or timeout failure, the normal browser reads the cached generation and
shows only a compact bottom connection panel with a retry action.

Visible files use a batched SQLite lookup for persistent direct offline-ready
markers. The tile marker API also distinguishes inherited folder pins, which
will be populated by the recursive offline queue. Removing a direct pin is a
local operation: it does not require network refresh and deletes the immutable
content object only after the final same-account hash reference is removed.

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
