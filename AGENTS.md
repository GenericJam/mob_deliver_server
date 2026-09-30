# AGENTS.md — orientation for AI agents working on mob_deliver_server

You're in **mob_deliver_server**, the reference server library for
[mob_deliver](../mob_deliver) (the on-device client plugin for Mob). It
builds a Phoenix project's `mobile/` tree into content-addressed BEAMs,
signs a manifest, stores both, and serves them over wire format v1.

**Read the wire contract first:** mob_deliver's
[`decisions/2026-09-19-scope-and-wire-format.md`](../mob_deliver/decisions/2026-09-19-scope-and-wire-format.md)
— sections "Wire format v1", "Manifest signing", "Forced-update window",
"Phoenix-native server layout". The client is the reference for the
canonical signing payload (`MobDeliver.Manifest.signing_payload/1`);
this repo reimplements it independently.

> **Keep this file current.** When you change the storage layout, the
> build pipeline, or hit a gotcha that would trip the next agent, fix it
> here in the same commit.

## Anatomy

* `lib/mob_deliver_server.ex` — `build/2` (ParallelCompiler into a temp
  dir, strip to `:beam_lib.significant_chunks/0` + `Attr`, SHA-256;
  unloads modules it newly loaded), `publish/2` (validate, blobs first,
  signed manifest last), `module_key/1`.
* `lib/mob_deliver_server/manifest.ex` — canonical JSON, `sign/2`, key
  file format (`ed25519-private:<base64 seed>`), `public_key_string/1`
  (client form `ed25519:<base64 public>`).
* `lib/mob_deliver_server/storage.ex` — the behaviour (`put_blob/3`,
  `get_blob/2`, `put_manifest/4`, `get_manifest/3`) plus `valid_sha?/1`
  and `valid_name?/1`. `storage/fs.ex` — the filesystem implementation.
* `lib/mob_deliver_server/plug.ex` — the two endpoints. Validates the
  SHA / app / channel before calling storage.
* `lib/mix/tasks/` — `mob_deliver.gen.key`, `mob_deliver.publish`.
* `test/` — golden vector + escaping + >32-key ordering, sign/verify,
  build determinism (including a moved checkout), publish layout, plug
  status codes and headers, task behaviour, and `interop_test.exs`
  against the real client.

## Rules

1. **Never depend on mob_deliver at runtime.** Client and server are
   peers across the wire (mob_deliver AGENTS.md rule 6). mob_deliver is a
   `only: :test, runtime: false` path dep used solely by the interop
   tests; nothing under `lib/` may reference `MobDeliver.*`.
2. **The signing payload is byte-for-byte contract.** Any change to
   `MobDeliverServer.Manifest` canonical encoding must keep the golden
   vector and the interop tests green. Maps are sorted explicitly — maps
   with more than 32 keys don't iterate in key order.
3. **Never build a path or object key from unvalidated input.** The plug
   checks `Storage.valid_sha?/1` / `valid_name?/1` before storage is
   called; `Storage.FS` checks again.
4. **Blobs before manifest.** A published manifest must never reference
   a blob that isn't stored yet; manifest replacement is atomic.
5. **Build output must stay deterministic.** Don't keep chunks that embed
   absolute paths or timestamps (`CInf`, `Dbgi`, `Docs`). Compile from
   the project root: the `Line` chunk holds cwd-relative paths.
6. **No compile-time `~r//` regex literals** in `lib/` (OTP 28.0
   devices; mob AGENTS.md rule 10). Use binary matching / `Base.decode16`.
7. **No cloud SDK deps.** S3/GCS are roll-your-own via the storage
   behaviour; `plug` is the only runtime dependency.

## Pre-commit

```bash
mix format
mix credo --strict   # ExSlop + jump_credo_checks
mix compile --warnings-as-errors
mix test             # needs ../mob_deliver checked out
```

Git-local for now (no GitHub remote yet); CI config in
`.github/workflows/test.yml` checks out mob_deliver alongside.
