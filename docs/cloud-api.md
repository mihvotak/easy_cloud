# Cloud Mail.ru protocol map

This document records the reverse-engineered API surface used by Easy Cloud.
Cloud Mail.ru does not publish this API as a stable client contract. Every
operation must be verified by `tool/cloud_probe` before it is enabled in the
application.

## Confidence levels

- `CONFIRMED_LIVE`: verified against the target production service and dated.
- `CONFIRMED_REFERENCE`: present in at least one current reference client.
- `LEGACY`: present only in an old client or deprecated protocol.
- `UNCONFIRMED`: inferred or implemented by an emulator only.

## Live observations

| Date | Operation | Configuration | Result |
|---|---|---|---|
| 2026-09-09 | OAuth password grant | Production `o2.mail.ru`, `client_id=cloud-win`, `@list.ru` test account | Endpoint and OAuth error shape confirmed; credentials rejected with HTTP 200 and `error_code=3`. Successful authentication is not yet confirmed. |
| 2026-09-09 | OAuth password grant | Production `o2.mail.ru`, `client_id=cloud-win`, application password | Success; `expires_in=3600`, refresh token present. |
| 2026-09-09 | OAuth refresh grant | Production `o2.mail.ru`, `client_id=cloud-win` | Success; rotated access and refresh tokens, `expires_in=3600`, scope present. |
| 2026-09-09 | CSRF | Production API v2 | Success; `body.token` returned. |
| 2026-09-09 | API and OAuth dispatchers | Production API v2 and `dispatcher.cloud.mail.ru` | Success; API shard arrays and plain-text `/d` and `/u` responses confirmed. |
| 2026-09-09 | Root folder listing | Production API v2 | Success; folder metadata, counts, sort, revision fields, and list confirmed. |
| 2026-09-09 | `folder/find` | Production API v2, root scope | Success; server-side search is currently available. |
| 2026-09-09 | Upload and `file/add` | Production upload shard and API v2 | Raw PUT returned HTTP 201 and a 40-character hash; strict registration and subsequent stat succeeded. |
| 2026-09-09 | File stat and history | Production API v2 | Stat returned size/hash/mtime; history returned `uid`, `time`, `name`, `path`, and `size`, but no hash or revision for this account. |
| 2026-09-09 | Range and download | Production download shard | `Range: bytes=0-31` returned HTTP 206, `Accept-Ranges: bytes`, and valid `Content-Range`; complete content passed size and cloud-hash checks. |
| 2026-09-09 | File removal | Production API v2 | `file/remove` moved the generated probe file to trash. |
| 2026-09-09 | Folder sorting | Production API v2, root listing | `name`, `size`, and `mtime` each accepted `asc` and `desc`; `body.sort` matched every request. Tested folder had two children, so cross-page ordering remains unverified. |

## Service defaults

| Service | Default | Confidence | Source |
|---|---|---|---|
| OAuth | `https://o2.mail.ru/token` | `CONFIRMED_REFERENCE` | `CloudMailRu` OAuth strategy, `WebDavMailRuCloud` mobile OAuth |
| API v2 | `https://cloud.mail.ru/api/v2` | `CONFIRMED_REFERENCE` | `CloudMailRu` endpoint constants |
| Dispatcher | `https://dispatcher.cloud.mail.ru` | `CONFIRMED_REFERENCE` | Both current reference clients |
| Client ID | `cloud-win` | `CONFIRMED_REFERENCE` | Current `CloudMailRu` |
| Alternate client ID | `cloud-android` | `CONFIRMED_REFERENCE` | `WebDavMailRuCloud` WebM1Bin |

All defaults can be overridden in the probe with environment variables. This
is intended for contract testing, not for accepting arbitrary servers in the
production application.

## Endpoint matrix

| Operation | Method and endpoint | Authentication | Main request | Response | Confidence |
|---|---|---|---|---|---|
| Login | `POST https://o2.mail.ru/token` | App password | Form: `client_id`, `grant_type=password`, `username`, `password` | OAuth JSON | `CONFIRMED_LIVE` 2026-09-09 |
| Refresh | `POST https://o2.mail.ru/token` | Refresh token | Form: `client_id`, `grant_type=refresh_token`, `refresh_token` | OAuth JSON | `CONFIRMED_LIVE` 2026-09-09 |
| CSRF | `GET /tokens/csrf` | `access_token` query | No body | `body.token` | `CONFIRMED_LIVE` 2026-09-09 |
| API dispatcher | `POST /dispatcher/` | `access_token` query and CSRF header | Empty body | Arrays `get`, `upload`, `thumbnails`, etc. | `CONFIRMED_LIVE` 2026-09-09 |
| Download shard | `GET <dispatcher>/d` | `token` query | No body | Plain text: `URL IP COUNT` | `CONFIRMED_LIVE` 2026-09-09 |
| Upload shard | `GET <dispatcher>/u` | `token` query | No body | Plain text: `URL IP COUNT` | `CONFIRMED_LIVE` 2026-09-09 |
| List folder | `GET /folder` | API auth | Query: `home`, `offset`, `limit`, `sort` (`name`/`size`/`mtime`, `asc`/`desc`) | `body.list`, `body.count`, `body.sort` | `CONFIRMED_LIVE` 2026-09-09 |
| Stat node | `GET /file` | API auth | Query: `home` | One node in `body` | `CONFIRMED_LIVE` 2026-09-09 |
| Search | `GET /folder/find` | API auth | Query: `q`, `path`, `limit`, legacy CSRF `token` | Folder-like object with `body.list` | `CONFIRMED_LIVE` 2026-09-09 |
| Download | `GET <download-shard>/<path>` | `client_id`, `token` query | Optional `Range` | Binary body; HTTP 206 for valid Range | `CONFIRMED_LIVE` 2026-09-09 |
| Upload content | `PUT <upload-shard>` | `client_id`, `token` query | Raw bytes | HTTP 201 and 40-character cloud hash | `CONFIRMED_LIVE` 2026-09-09 |
| Register file | `POST /file/add` | API auth | Form: `api=2`, `conflict`, `home`, `hash`, `size` | API envelope with string body | `CONFIRMED_LIVE` 2026-09-09 |
| File history | `GET /file/history` | API auth | Query: `home` | Array in `body`; hash/rev may be absent | `CONFIRMED_LIVE` 2026-09-09 |
| Remove file | `POST /file/remove` | API auth | Form: `home`, empty `conflict` | API envelope with string body | `CONFIRMED_LIVE` 2026-09-09 |

API auth currently means:

- query parameter `access_token=<OAuth access token>`;
- `X-CSRF-Token: <csrf token>` after CSRF acquisition.

The VK ID cookie mode is deliberately outside the first implementation.

## Envelope and errors

Typical API response:

```json
{
  "email": "user@example.com",
  "body": {},
  "time": 1700490243535,
  "status": 200
}
```

The body can be an object, array, string, or null. Authentication expiry has
historically appeared as any of:

```text
body == "token"
error == "NOT/AUTHORIZED"
status == 403
HTTP 401 or 403
```

Shard errors are not API envelopes and may be plain text. Probe output records
HTTP status and response shape, but never response values containing secrets.

## Folder model

Observed fields include:

```text
home, name, type, kind, size, mtime, hash, tree, rev, grev,
weblink, virus_scan, count.files, count.folders
```

`rev` and `grev` are opaque metadata. None of the inspected implementations
provides a reliable delta endpoint or documents revision increment semantics.

File history fields are account-dependent. The live test returned `uid`,
`time`, `name`, `path`, and `size`, but omitted `hash` and `rev`. Restoration by
content identity must therefore be exposed only when those fields are present.

Folder listing must paginate. A requested `limit=65535` is not evidence that
the complete directory is returned; current reference code mentions a server
cap of roughly 8000 entries.

The server accepted all six combinations of `name`, `size`, or `mtime` with
`asc` or `desc`, and echoed each selection in `body.sort`. This confirms the
sorting contract, but the live test directory was too small to verify ordering
across page boundaries. The client therefore delegates sorting to the server
and never re-sorts an individual page locally.

## Search

`folder/find` is implemented only by the historical `mailru-cloud-api` client:

```text
GET /api/v2/folder/find?q=<name>&path=<path>&limit=<n>&token=<csrf>
```

It is absent from current `CloudMailRu`, `WebDavMailRuCloud`, and `tucha`, but a
live probe on 2026-09-09 confirmed that it remains available in production.
The capability still needs graceful fallback because it is supported only by
historical reference code and can disappear independently of the core API.

## References

- [`CloudMailRu/src/Domain/Constants/CloudConstants.pas`](../../CloudMailRu/src/Domain/Constants/CloudConstants.pas)
- [`CloudMailRu/src/Domain/ValueObjects/CloudEndpoints.pas`](../../CloudMailRu/src/Domain/ValueObjects/CloudEndpoints.pas)
- [`CloudMailRu/src/Infrastructure/Authentication/OAuthAppAuthStrategy.pas`](../../CloudMailRu/src/Infrastructure/Authentication/OAuthAppAuthStrategy.pas)
- [`CloudMailRu/src/Application/Listing/CloudListingService.pas`](../../CloudMailRu/src/Application/Listing/CloudListingService.pas)
- [`CloudMailRu/src/Application/Upload/CloudFileUploader.pas`](../../CloudMailRu/src/Application/Upload/CloudFileUploader.pas)
- [`CloudMailRu/src/Application/Download/CloudFileDownloader.pas`](../../CloudMailRu/src/Application/Download/CloudFileDownloader.pas)
- [`WebDavMailRuCloud/.../Mobile/Requests`](../../WebDavMailRuCloud/MailRuCloud/MailRuCloudApi/Base/Repos/MailRuCloud/Mobile/Requests)
- [`tucha/API_SPEC.md`](../../tucha/API_SPEC.md)
- [`mailru-cloud-api/cloud_mail_api/api/folder.py`](../../mailru-cloud-api/cloud_mail_api/api/folder.py)
