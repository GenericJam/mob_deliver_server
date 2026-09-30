# mob_deliver_server

Reference server for [mob_deliver](https://github.com/GenericJam/mob_deliver) —
content-addressed BEAM delivery for [Mob](https://hexdocs.pm/mob) apps.

> **Status: v0.1.0-dev.** Not yet on Hex. Implements wire format v1 as
> pinned in mob_deliver's
> [`decisions/2026-09-19-scope-and-wire-format.md`](https://github.com/GenericJam/mob_deliver/blob/master/decisions/2026-09-19-scope-and-wire-format.md).

## What it does

mob_deliver (the on-device client) fetches a signed manifest with
`POST /manifest` and individual `.beam` files with `GET /beam/:sha256`,
verifies them, and hot-loads them. This library is the other side of
that wire, for a Phoenix (or any Plug) app:

1. **Build** — compile the `.ex` files under your project's `mobile/`
   directory into content-addressed BEAMs (`MobDeliverServer.build/2`).
   Deterministic: an unchanged module keeps its SHA, so devices never
   re-download it.
2. **Publish** — store the BEAMs and an Ed25519-signed manifest listing
   them (`MobDeliverServer.publish/2`, `mix mob_deliver.publish`).
3. **Serve** — `MobDeliverServer.Plug` answers the two wire endpoints
   from that store, with the right cache headers.

The wire is a protocol, not a library: any server that serves the same
two endpoints works, and the client never depends on this package.

## Quick start

```elixir
# mix.exs
def deps do
  [
    {:mob_deliver_server, github: "GenericJam/mob_deliver_server"}
  ]
end
```

### 1. Generate a signing key

```bash
mix mob_deliver.gen.key --out mob_deliver_signing.key
```

Writes the private key (mode `0600`; refuses to overwrite an existing
file) and prints the public half. **Keep the private key out of version
control** — add it to `.gitignore`, and store its contents as a CI secret.

### 2. Configure the mob app (client)

```elixir
# config/config.exs of the mob app
config :mob_deliver,
  trusted_publish_key: "ed25519:…",          # printed by gen.key; baked in at compile time
  endpoint: "https://example.com/deliver",
  app: "com.example.myapp",
  channel: "production"
```

### 3. Mount the plug in Phoenix

```elixir
# lib/my_app_web/router.ex
forward "/deliver", MobDeliverServer.Plug,
  storage: {MobDeliverServer.Storage.FS, root: "/srv/mob_deliver"}
```

`forward` works from any scope/pipeline; the plug needs no session,
CSRF protection, or `:accepts` — put it outside the `:browser` pipeline.
If your endpoint's `Plug.Parsers` already decoded the JSON body, the plug
uses `conn.body_params`; otherwise it reads the body itself, capped at
`:max_body_bytes` (default 8 KiB).

### 4. Publish

```bash
mix mob_deliver.publish --app com.example.myapp --channel production \
  --key-file mob_deliver_signing.key   # or: MOB_DELIVER_SIGNING_KEY="$(cat …)"
```

Runs `mix compile`, compiles every `.ex` under `mobile/` against the
project, writes `mob_deliver_publish/beam/<sha>` and
`mob_deliver_publish/manifests/<app>/<channel>.json`, prints one line per
module, and exits non-zero on any failure. Gitignore the output directory
and keep it out of `priv/` — mob_dev copies the app's whole `priv/` into
the native binary, which would bundle the delivered screens into the next
store build. Copy it to the server's storage root. Other options:
`--mobile-dir`, `--out`, `--min-app-version 1.4.0`,
`--force-update-after 2026-10-19T00:00:00Z` (see the ADR's
"Forced-update window").

Blobs are written before the manifest, and every write is
temp-file + rename, so a running server never serves a manifest whose
BEAMs are missing or a half-written file.

## Serving notes

* **TLS.** Serve over HTTPS. The manifest signature protects integrity
  even over a compromised transport, but TLS keeps what you ship private
  and stops trivial replay of an older signed manifest. On Android (or
  anywhere the BEAM lacks a system trust store) the client passes
  `cacerts` via its `:req_options`.
* **Caching.** `GET /beam/:sha256` responses are immutable
  (`Cache-Control: public, max-age=31536000, immutable`, strong `ETag`
  = the SHA, `304` on `If-None-Match`) — put a CDN in front freely.
  `POST /manifest` responses are `Cache-Control: no-cache`; POSTs aren't
  cached by CDNs anyway.
* **Determinism.** `build/2` strips each BEAM to the chunks the VM needs
  (`:beam_lib.significant_chunks/0` plus `Attr`, as `mix release` does),
  because Elixir embeds absolute source paths in the compile-info, debug
  info, and docs chunks. Line tables keep paths relative to the working
  directory, so compile from the project root (the mix task does). The
  same source with the same Elixir/OTP gives the same SHA; a toolchain
  upgrade changes every SHA and devices refetch.

## Roll-your-own storage (S3, GCS, …)

No cloud SDKs are bundled. Implement the `MobDeliverServer.Storage`
behaviour — four callbacks — with your client of choice:

```elixir
defmodule MyApp.S3Storage do
  @behaviour MobDeliverServer.Storage

  @impl true
  def put_blob(config, sha, beam), do: put_object(config, "beam/" <> sha, beam)
  @impl true
  def get_blob(config, sha), do: get_object(config, "beam/" <> sha)
  @impl true
  def put_manifest(config, app, channel, body),
    do: put_object(config, "manifests/#{app}/#{channel}.json", body)
  @impl true
  def get_manifest(config, app, channel),
    do: get_object(config, "manifests/#{app}/#{channel}.json")

  # put_object/3 → :ok | {:error, _}; get_object/2 → {:ok, binary} |
  # {:error, :not_found} | {:error, _}
end
```

Then publish from your own task and serve with the same plug:

```elixir
{:ok, build} = MobDeliverServer.build("mobile")

{:ok, _} =
  MobDeliverServer.publish(build,
    app: "com.example.myapp",
    channel: "production",
    private_key: System.fetch_env!("MOB_DELIVER_SIGNING_KEY"),
    storage: {MyApp.S3Storage, bucket: "deliver"}
  )

# router
forward "/deliver", MobDeliverServer.Plug, storage: {MyApp.S3Storage, bucket: "deliver"}
```

A manifest replace must be atomic from a reader's view (S3 `PUT` is).
You can also skip the plug entirely and serve the same layout from a
static host, as long as something answers `POST /manifest` with the
stored body.

## Development

```bash
mix test                 # includes interop tests against ../mob_deliver
mix format
mix credo --strict
mix compile --warnings-as-errors
```

The interop tests use mob_deliver as a test-only path dependency, so
clone it next to this repo (`~/code/mob_deliver`).

## License

MIT — see [LICENSE](LICENSE).
