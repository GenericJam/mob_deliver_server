defmodule MobDeliverServer.TestHelpers do
  @moduledoc false

  alias MobDeliverServer.Manifest

  @doc "A fresh private key (key-file form) and its raw public key."
  def keypair do
    private = Manifest.generate_private_key()
    "ed25519:" <> public = Manifest.public_key_string(private)
    {private, Base.decode64!(public)}
  end

  @doc "Writes `files` (`relative path => source`) under `dir`; returns `dir`."
  def write_sources(dir, files) do
    for {path, source} <- files do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, source)
    end

    dir
  end

  @doc "A module name unique to this test run, so builds never collide."
  def unique_module(prefix) do
    "#{prefix}#{System.unique_integer([:positive])}"
  end

  @doc "A `MobDeliverServer.build/2`-shaped map of in-memory fake BEAMs."
  def fake_build(keys) do
    Map.new(keys, fn key ->
      beam = "beam of " <> key
      {key, {Base.encode16(:crypto.hash(:sha256, beam), case: :lower), beam}}
    end)
  end
end

defmodule MobDeliverServer.RecordingStorage do
  @moduledoc false
  # Storage that reports every call to the test process and serves canned
  # data — proves which requests reach storage at all.
  @behaviour MobDeliverServer.Storage

  @impl true
  def put_blob(config, sha, binary), do: record(config, {:put_blob, sha, binary}, :ok)

  @impl true
  def get_blob(config, sha),
    do: record(config, {:get_blob, sha}, Map.get(config[:blobs], sha, {:error, :not_found}))

  @impl true
  def put_manifest(config, app, channel, body),
    do: record(config, {:put_manifest, app, channel, body}, :ok)

  @impl true
  def get_manifest(config, app, channel),
    do: record(config, {:get_manifest, app, channel}, {:error, :not_found})

  defp record(config, call, reply) do
    send(config[:pid], {:storage, call})
    reply
  end
end

ExUnit.start()
