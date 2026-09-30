defmodule MobDeliverServer.Storage.FS do
  @moduledoc """
  Filesystem storage: `{MobDeliverServer.Storage.FS, root: "/srv/mob_deliver"}`.

  Layout under `root`:

      beam/<sha>                              raw .beam bytes
      manifests/<app>/<channel>.json          signed manifest body
      replaced/<app>/<channel>/<ms>-<id>.json manifests replaced by a publish

  Every write goes to a temp file in the target directory, is fsynced,
  then renamed over the target, so a concurrent reader (the plug) sees
  the old file or the new one, never a partial one. Invalid SHAs and
  names are refused before any path is built.

  `put_manifest/4` keeps the manifest it replaces under `replaced/`, so
  `prune/2` knows which blobs a device may still be fetching for a
  manifest it got just before the publish. Nothing else reads it, and
  `prune/2` deletes entries older than its grace period.
  """

  @behaviour MobDeliverServer.Storage

  alias MobDeliverServer.Storage

  @default_grace 7 * 24 * 60 * 60

  @typedoc "What `prune/2` deleted (or, with `dry_run: true`, would delete)."
  @type prune_result :: %{
          deleted: [Storage.sha()],
          bytes: non_neg_integer(),
          kept: non_neg_integer(),
          replaced_deleted: non_neg_integer()
        }

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
    if valid_names?(app, channel) do
      path = manifest_path(config, app, channel)
      with :ok <- keep_replaced(config, app, channel, path), do: atomic_write(path, body)
    else
      {:error, :invalid_name}
    end
  end

  @impl true
  def get_manifest(config, app, channel) do
    if valid_names?(app, channel),
      do: read(manifest_path(config, app, channel)),
      else: {:error, :invalid_name}
  end

  @doc """
  Deletes blobs no manifest under `root` references, once they're old
  enough that no device can still be fetching them.

  A blob is kept if any of these holds:

    * a current manifest (any app, any channel) references it;
    * a manifest replaced less than `:older_than` seconds ago references
      it — a device that fetched that manifest just before the publish
      is still downloading its blobs;
    * the blob was written less than `:older_than` seconds ago — a
      publish in progress writes blobs before its manifest.

  Replaced manifests older than `:older_than` are deleted as well. A
  current or recent replaced manifest that can't be read or parsed stops
  the prune before anything is deleted. Devices that haven't checked for
  updates within the grace period may miss a blob their old manifest
  names; they fetch the current manifest at their next check.

  Don't run it concurrently with a publish to the same root with a grace
  shorter than the publish takes: each blob's age is checked again right
  before it is deleted, but the check and the delete aren't atomic.

  ## Options

    * `:older_than` — grace period in seconds (default 7 days);
    * `:dry_run` — report what would be deleted, delete nothing;
    * `:now` — current POSIX time in seconds (default the system clock).
  """
  @spec prune(keyword(), keyword()) :: {:ok, prune_result()} | {:error, term()}
  def prune(config, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)
    cutoff = now - Keyword.get(opts, :older_than, @default_grace)
    dry_run? = Keyword.get(opts, :dry_run, false)
    {recent_replaced, stale_replaced} = replaced_manifests(config, cutoff)

    with {:ok, referenced} <- referenced(current_manifests(config) ++ recent_replaced),
         {:ok, blobs} <- blobs(config) do
      stale =
        for {sha, path} <- blobs,
            not MapSet.member?(referenced, sha),
            {:ok, %{mtime: mtime, size: size}} <- [stat(path)],
            mtime < cutoff,
            do: {sha, path, size}

      deleted = if dry_run?, do: stale, else: Enum.filter(stale, &delete_stale(&1, cutoff))
      if not dry_run?, do: Enum.each(stale_replaced, &File.rm/1)

      {:ok,
       %{
         deleted: Enum.map(deleted, &elem(&1, 0)),
         bytes: deleted |> Enum.map(&elem(&1, 2)) |> Enum.sum(),
         kept: length(blobs) - length(deleted),
         replaced_deleted: length(stale_replaced)
       }}
    end
  end

  defp keep_replaced(config, app, channel, path) do
    case File.read(path) do
      {:ok, old} ->
        name = "#{System.os_time(:millisecond)}-#{MobDeliverServer.random_suffix()}.json"
        atomic_write(Path.join([root(config), "replaced", app, channel, name]), old)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:read, path, reason}}
    end
  end

  defp current_manifests(config),
    do: Path.wildcard(Path.join([root(config), "manifests", "*", "*.json"]))

  defp replaced_manifests(config, cutoff) do
    [root(config), "replaced", "*", "*", "*.json"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.split_with(&recent?(&1, cutoff))
  end

  # An unstattable entry counts as recent, so reading it fails and stops
  # the prune rather than silently dropping the blobs it protects.
  defp recent?(path, cutoff) do
    case stat(path) do
      {:ok, %{mtime: mtime}} -> mtime >= cutoff
      {:error, _} -> true
    end
  end

  defp referenced(paths) do
    Enum.reduce_while(paths, {:ok, MapSet.new()}, fn path, {:ok, acc} ->
      case manifest_shas(path) do
        {:ok, shas} -> {:cont, {:ok, MapSet.union(acc, shas)}}
        {:error, reason} -> {:halt, {:error, {:unreadable_manifest, path, reason}}}
      end
    end)
  end

  defp manifest_shas(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"modules" => modules}} when is_map(modules) <- JSON.decode(body) do
      {:ok, MapSet.new(for {_key, "sha256:" <> sha} <- modules, do: sha)}
    else
      {:ok, _other} -> {:error, :no_modules}
      {:error, reason} -> {:error, reason}
    end
  end

  defp blobs(config) do
    dir = Path.join(root(config), "beam")

    case File.ls(dir) do
      {:ok, names} ->
        {:ok, for(sha <- names, Storage.valid_sha?(sha), do: {sha, Path.join(dir, sha)})}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:list, dir, reason}}
    end
  end

  # Checked again just before deleting: a publish may have rewritten the
  # blob (fresh mtime) since the scan.
  defp delete_stale({_sha, path, _size}, cutoff) do
    match?({:ok, %{mtime: mtime}} when mtime < cutoff, stat(path)) and File.rm(path) == :ok
  end

  defp stat(path), do: File.stat(path, time: :posix)

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

  # The temp name is random (`System.unique_integer/1` repeats across VMs,
  # and several publishers may share a root) and removed only if this call
  # created it.
  defp atomic_write(path, binary) do
    dir = Path.dirname(path)
    tmp = Path.join(dir, ".tmp-" <> MobDeliverServer.random_suffix())

    with :ok <- mkdir_p(dir),
         :ok <- write_synced(tmp, binary) do
      with {:error, _} = error <- rename(tmp, path) do
        _ = File.rm(tmp)
        error
      end
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
      {:ok, :ok} ->
        :ok

      {:ok, {:error, reason}} ->
        _ = File.rm(path)
        {:error, {:write, path, reason}}

      {:error, reason} ->
        {:error, {:write, path, reason}}
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
