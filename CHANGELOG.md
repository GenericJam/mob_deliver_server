# Changelog

All notable changes to **mob_deliver_server** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.2.0] - 2026-09-30

### Added
- `mix mob_deliver.prune` and `MobDeliverServer.Storage.FS.prune/2` —
  delete blobs no manifest in the store references any more (every app
  and channel), after a grace period (`--older-than`, default `7d`, by
  file mtime); `--dry-run` reports only. Blobs dropped by a publish
  within the grace period are kept, so a device that fetched the
  previous manifest can still download them. To know that,
  `Storage.FS.put_manifest/4` now keeps the manifest it replaces under
  `replaced/<app>/<channel>/` (pruned with the same grace period).
- `mix mob_deliver.publish` refuses a signing key whose public half
  doesn't match the project's `config :mob_deliver, :trusted_publish_key`
  (every device built from that config would reject the manifest with
  `:invalid_signature`); `--force` publishes anyway with a warning, e.g.
  during a key rotation. Projects without that setting aren't checked.
- `MobDeliverServer.valid_app_version?/1` and `gate_fields/1`.

### Changed
- `min_app_version` must be dotted numeric (`1`, `1.4`, `1.4.0`): the
  form the client's forced-update gate compares. `publish/2` and the
  task used to accept any non-empty string, which the client ignores
  (leaving the gate open). `force_update_after` without
  `min_app_version` is rejected too: the client ignores such a deadline.
  The publish task checks both flags, with a message naming the flag,
  before compiling.

### Fixed
- README "Development" described mob_deliver as both a Hex and a path
  dependency for the interop tests; it's Hex by default, or the checkout
  at `MOB_DELIVER_PATH`.

## [0.1.0] - 2026-09-30

### Added
- `MobDeliverServer.Manifest` — canonical signing payload (wire format
  v1), Ed25519 `sign/2`, key file format
  (`ed25519-private:<base64 seed>`) and `public_key_string/1` for the
  client's `trusted_publish_key`. Pinned to mob_deliver's golden vector.
- `MobDeliverServer.build/2` — compiles a `mobile/` tree against the
  current code path into stripped, deterministic, content-addressed
  BEAMs keyed like the manifest (`"MyApp.HomeScreen"`, `":my_mod"`).
- `MobDeliverServer.publish/2` — writes blobs, then the signed manifest,
  through the `MobDeliverServer.Storage` behaviour;
  `MobDeliverServer.Storage.FS` ships (`beam/<sha>`,
  `manifests/<app>/<channel>.json`, temp-file + fsync + rename writes).
- `MobDeliverServer.Plug` — `POST /manifest` and `GET /beam/:sha256`
  with the wire's content types and cache headers, strong ETags / `304`,
  body-size limit, SHA and name validation before storage is touched.
- `mix mob_deliver.gen.key` and `mix mob_deliver.publish`.
- Interop tests against the real client (`MobDeliver.Manifest.verify/3`,
  `MobDeliver.Client.fetch_manifest/1`, `fetch_beam/2`).
