defmodule MobDeliverServer.Storage do
  @moduledoc """
  Where published blobs and signed manifests live.

  A storage is a `{module, config}` pair; `module` implements this
  behaviour and receives `config` as the first argument of every
  callback. `MobDeliverServer.Storage.FS` ships with the library. S3, GCS
  or a database are roll-your-own: implement the four callbacks with
  your cloud client of choice and pass `{MyApp.S3Storage, bucket: ...}`
  to `MobDeliverServer.publish/2` and `MobDeliverServer.Plug`.

  Contract for implementations:

    * `put_blob/3` stores `binary` under `sha` (lowercase hex SHA-256 of
      `binary`). Blobs are immutable: re-putting a SHA stores the same
      bytes.
    * `put_manifest/4` replaces the manifest for `app` + `channel`
      atomically — a reader sees the old body or the new one, never a
      partial write. `MobDeliverServer.publish/2` writes every blob before
      the manifest that references them.
    * `get_*` return `{:error, :not_found}` for anything absent; other
      errors surface as a 500 from the plug.
    * Callers validate `sha` with `valid_sha?/1` and `app`/`channel` with
      `valid_name?/1` before calling in; implementations that build paths
      or object keys from them should check again rather than trust it.
  """

  @type t :: {module(), term()}
  @type sha :: String.t()

  @callback put_blob(config :: term(), sha(), binary()) :: :ok | {:error, term()}
  @callback get_blob(config :: term(), sha()) :: {:ok, binary()} | {:error, :not_found | term()}
  @callback put_manifest(
              config :: term(),
              app :: String.t(),
              channel :: String.t(),
              body :: binary()
            ) ::
              :ok | {:error, term()}
  @callback get_manifest(config :: term(), app :: String.t(), channel :: String.t()) ::
              {:ok, binary()} | {:error, :not_found | term()}

  @doc "Whether `sha` is 64 lowercase hex characters."
  @spec valid_sha?(term()) :: boolean()
  def valid_sha?(sha) when is_binary(sha) and byte_size(sha) == 64,
    do: match?({:ok, _}, Base.decode16(sha, case: :lower))

  def valid_sha?(_), do: false

  @doc """
  Whether `name` is usable as an app id or channel: 1–128 bytes of ASCII
  letters, digits, `.`, `_`, `-`, not starting with `.` (so never `.`,
  `..`, or a hidden file). `"com.example.myapp"` and `"production"` pass.
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?("." <> _), do: false

  def valid_name?(name) when is_binary(name) and byte_size(name) in 1..128,
    do: name |> :binary.bin_to_list() |> Enum.all?(&name_char?/1)

  def valid_name?(_), do: false

  defp name_char?(char) when char in ?a..?z or char in ?A..?Z or char in ?0..?9, do: true
  defp name_char?(char), do: char in [?., ?_, ?-]
end
