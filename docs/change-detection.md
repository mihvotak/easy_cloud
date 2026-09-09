# Change detection

## Confirmed limitations

No inspected implementation exposes a reliable change feed, cursor, SSE, or
WebSocket. `rev`, `grev`, tree revision, and binary mobile revision structures
exist, but their increment and scope semantics are not documented or consumed
consistently.

Therefore Easy Cloud V1 uses reconciliation, not real-time synchronization.

## File identity comparison

Compare remote state in this order:

```text
1. revision or global revision, only after live behavior is understood
2. content hash
3. size
4. modification time
```

A revision value alone must not invalidate or validate cached content. A stable
hash binds a cached object even after rename or move.

## Reconciliation scopes

V1 refreshes only bounded scopes:

- current folder on open and pull-to-refresh;
- recently indexed folders on app resume;
- files and folders explicitly pinned for offline access;
- locally edited files before upload.

It does not recursively scan the entire account on every launch.

## Offline file state

```text
ONLINE_ONLY
QUEUED
DOWNLOADING
OFFLINE_READY
OUTDATED
CONFLICT
ERROR
```

For each pinned file, `stat` is compared with the stored binding. A changed hash
marks the local copy `OUTDATED`; a locally edited copy plus a remote change is
`CONFLICT`. Remote deletions do not immediately delete local content.

For pinned folders, the application compares paginated child listings and then
queues bounded child reconciliation. The queue is persistent and resumable.

## Editor concurrency

When a text file is opened, store baseline path, hash, size, mtime, and opaque
revision fields. Before upload, fetch `stat` again. If identity differs, do not
overwrite automatically. Offer remote preview, local copy upload, or explicit
forced replacement.

## Probe observations to collect

- [ ] Whether `rev` changes after content replacement.
- [ ] Whether `grev` changes after child add/remove/rename.
- [ ] Whether parent folder metadata changes after child changes.
- [ ] Whether hash remains stable after rename/move.
- [ ] Whether history is retained after rename/move.
- [ ] Timestamp precision and server timezone behavior.

The initial live history response omitted both hash and revision. Change and
conflict detection cannot depend on history availability and must continue to
use current stat metadata plus the locally stored edit baseline.
