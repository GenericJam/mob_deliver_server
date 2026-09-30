# Changelog

All notable changes to **mob_deliver_server** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.1.0-dev] - unreleased

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
