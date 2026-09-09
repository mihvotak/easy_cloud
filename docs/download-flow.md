# Download flow

## Candidate protocol

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
   ```

6. Stream to `<destination>.part`.
7. Flush and close the temporary file.
8. Verify expected size and cloud hash when metadata is available.
9. Atomically rename the temporary file to the destination.

The probe follows the same temporary-file rule and refuses to overwrite an
existing destination unless `--overwrite` is passed.

## Resume experiment

`WebDavMailRuCloud` sends HTTP `Range`; `tucha` emulates it, but current
`CloudMailRu` does not implement resume. Probe command `range` requests a small
byte interval and records:

```text
HTTP status, Accept-Ranges, Content-Range, Content-Length, response shape
```

Production returned a valid `206`, `Accept-Ranges: bytes`, and matching
`Content-Range` on 2026-09-09. A future `200` response to a Range request still
means the client must restart from byte zero.

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
- Retry authentication at most once.
- Do not log shard URLs before removing their token query parameters.
- Treat disk-full and integrity failures separately from network failures.

## Live checklist

- [x] `/d` response grammar and shard URL extraction confirmed.
- [ ] Leading slash and Unicode path encoding confirmed.
- [x] Root-level ASCII path encoding confirmed.
- [ ] Redirect behavior confirmed independently.
- [x] A 94-byte file hash matched upload, stat, and downloaded content.
- [ ] Boundary and large production file hashes confirmed.
- [ ] Zero-byte and 1-20-byte files tested.
- [x] Range support confirmed with a 32-byte partial response.
- [ ] Interrupted download leaves no final file.
