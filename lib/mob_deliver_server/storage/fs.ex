defmodule MobDeliverServer.Storage.FS do
  @moduledoc """
  Filesystem storage: `{MobDeliverServer.Storage.FS, root: "priv/mob_deliver"}`.

  Layout under `root`:

      beam/<sha>                      raw .beam bytes
      manifests/<app>/<channel>.json  signed manifest body

  Every write goes to a temp file in the target directory, is fsynced,
  then renamed over the target, so a concurrent reader (the plug) sees
  the old file or the new one, never a partial one. Invalid SHAs and
  names are refused before any path is built.
  """

  @behaviour MobDeliverServer.Storage

  alias MobDeliverServer.Storage

  @impl true
  def put_blob(config, sha, binary) when is_binary(binary) do
    if Storage.valid_sha?(sha),
      do: atomic_write(blob_path(config, sha), binary),
      else: {:error, :invalid_sha}
  end

  @impl true
  def get_blob(config, sha) do
    if Storage.valid_sha?(sha), do: read(blob_path(config, sha)), else: {:error, :invalid_sha}
  end

  @impl true
  def put_manifest(config, app, channel, body) when is_binary(body) do
    if valid_names?(app, channel),
      do: atomic_write(manifest_path(config, app, channel), body),
      else: {:error, :invalid_name}
  end

  @impl true
  def get_manifest(config, app, channel) do
    if valid_names?(app, channel),
      do: read(manifest_path(config, app, channel)),
      else: {:error, :invalid_name}
  end

  defp valid_names?(app, channel), do: Storage.valid_name?(app) and Storage.valid_name?(channel)

  defp blob_path(config, sha), do: Path.join([root(config), "beam", sha])

  defp manifest_path(config, app, channel),
    do: Path.join([root(config), "manifests", app, channel <> ".json"])

  defp root(config), do: Keyword.fetch!(config, :root)

  defp read(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, {:read, path, reason}}
    end
  end

  defp atomic_write(path, binary) do
    dir = Path.dirname(path)
    tmp = Path.join(dir, ".tmp-" <> Integer.to_string(System.unique_integer([:positive])))

    with :ok <- mkdir_p(dir),
         :ok <- write_synced(tmp, binary),
         :ok <- rename(tmp, path) do
      :ok
    else
      {:error, _} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  defp mkdir_p(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir, dir, reason}}
    end
  end

  defp write_synced(path, binary) do
    case File.open(path, [:write, :binary, :exclusive], &write_and_sync(&1, binary)) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, {:write, path, reason}}
      {:error, reason} -> {:error, {:write, path, reason}}
    end
  end

  defp write_and_sync(device, binary) do
    with :ok <- IO.binwrite(device, binary), do: :file.sync(device)
  end

  defp rename(from, to) do
    case File.rename(from, to) do
      :ok -> :ok
      {:error, reason} -> {:error, {:rename, to, reason}}
    end
  end
end
