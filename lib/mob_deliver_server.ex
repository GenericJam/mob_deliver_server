defmodule MobDeliverServer do
  @moduledoc """
  Reference server for [mob_deliver](https://github.com/GenericJam/mob_deliver)
  wire format v1.

  Three pieces, one per stage:

    * `build/2` compiles a Phoenix project's `mobile/` tree into
      content-addressed BEAMs;
    * `publish/2` stores the BEAMs and a signed manifest in a
      `MobDeliverServer.Storage`;
    * `MobDeliverServer.Plug` serves `POST /manifest` and
      `GET /beam/:sha256` from that storage.

  `mix mob_deliver.gen.key` and `mix mob_deliver.publish` wrap the first
  two for CI.
  """

  alias MobDeliverServer.Manifest
  alias MobDeliverServer.Storage

  @typedoc "Module key (`\"MyApp.HomeScreen\"`, `\":my_mod\"`) => `{sha, beam}`."
  @type build :: %{String.t() => {Storage.sha(), binary()}}

  @typedoc "What `publish/2` wrote: the manifest body and its fields."
  @type published :: %{body: binary(), fields: Manifest.fields()}

  @default_storage {MobDeliverServer.Storage.FS, root: "priv/mob_deliver"}

  @doc """
  Compiles `source` — a directory (every `**/*.ex` under it) or a list of
  `.ex` files — and returns each module's stripped BEAM and its SHA-256.

  Compiles against the current code path, so modules the sources use
  (`use MyAppWeb.MobileScreen`, the app's own modules) must already be
  compiled and loadable; `mix mob_deliver.publish` runs `mix compile`
  first. Modules this call loads that weren't loaded before are unloaded
  again afterwards.

  ## Determinism

  The same source compiled by the same toolchain yields the same SHA, so
  an unchanged module keeps its blob across publishes and devices don't
  refetch it. Elixir embeds the absolute source path in the `CInf`,
  `Dbgi` and `Docs` chunks, so each BEAM is stripped to the chunks the VM
  needs to load and run it — `:beam_lib.significant_chunks/0` plus `Attr`,
  the same set `Mix.Release` keeps with `strip_beams: true`. Debug info
  and docs don't ship to devices. The `Line` chunk keeps source paths
  relative to the current working directory (Elixir's default
  `:relative_paths`), so compile from the project root — as the mix task
  does — for SHAs that don't depend on where the checkout lives.

  ## Options

    * `:tmp_dir` — parent of the scratch directory the compiler writes to
      (default `System.tmp_dir!/0`); removed afterwards.
  """
  @spec build(Path.t() | [Path.t()], keyword()) ::
          {:ok, build()} | {:error, {:compile_failed, [map()]} | {:no_sources, term()}}
  def build(source, opts \\ []) do
    case source_files(source) do
      [] -> {:error, {:no_sources, source}}
      files -> compile(files, opts)
    end
  end

  @doc """
  Stores every BEAM of `build` and then the signed manifest for it, so a
  manifest is never visible before the blobs it references.

  ## Options

    * `:app` (required) — app id, e.g. `"com.example.myapp"`;
    * `:channel` (required) — e.g. `"production"`;
    * `:private_key` (required) — key-file form, see
      `MobDeliverServer.Manifest`;
    * `:min_app_version` — lowest native app version the manifest
      supports, e.g. `"1.4.0"`;
    * `:force_update_after` — `DateTime` or ISO 8601 string; after it,
      clients below `:min_app_version` must update from the store;
    * `:issued_at` — `DateTime` (default now); clients follow the
      newest `issued_at` for the forced-update gate;
    * `:storage` — `{module, config}` (default
      `{MobDeliverServer.Storage.FS, root: "priv/mob_deliver"}`).
  """
  @spec publish(build(), keyword()) :: {:ok, published()} | {:error, term()}
  def publish(build, opts) when is_map(build) do
    {storage_mod, storage_config} = Keyword.get(opts, :storage, @default_storage)

    with {:ok, fields} <- manifest_fields(build, opts),
         {:ok, _seed} <- Manifest.decode_private_key(Keyword.fetch!(opts, :private_key)),
         :ok <- put_blobs(build, storage_mod, storage_config) do
      body = Manifest.sign(fields, Keyword.fetch!(opts, :private_key))

      case storage_mod.put_manifest(storage_config, fields["app"], fields["channel"], body) do
        :ok -> {:ok, %{body: body, fields: fields}}
        {:error, reason} -> {:error, {:put_manifest, reason}}
      end
    end
  end

  @doc """
  The manifest `modules` key for `module`: `"MyApp.HomeScreen"` for Elixir
  modules, `":my_mod"` for Erlang ones (`inspect/1`'s shape).
  """
  @spec module_key(module()) :: String.t()
  def module_key(module) when is_atom(module) do
    case Atom.to_string(module) do
      "Elixir." <> name -> name
      name -> ":" <> name
    end
  end

  defp source_files(files) when is_list(files), do: files

  defp source_files(dir) when is_binary(dir) do
    if File.dir?(dir), do: dir |> Path.join("**/*.ex") |> Path.wildcard() |> Enum.sort(), else: []
  end

  defp compile(files, opts) do
    tmp =
      Path.join(
        Keyword.get_lazy(opts, :tmp_dir, &System.tmp_dir!/0),
        "mob_deliver_server_build_" <> Integer.to_string(System.unique_integer([:positive]))
      )

    loaded_before = MapSet.new(:code.all_loaded(), &elem(&1, 0))
    previous_options = Code.compiler_options(ignore_module_conflict: true)

    try do
      File.mkdir_p!(tmp)

      case Kernel.ParallelCompiler.compile_to_path(files, tmp, return_diagnostics: true) do
        {:ok, modules, _warnings} ->
          unload_new(modules, loaded_before)
          {:ok, Map.new(modules, &built_module(&1, tmp))}

        {:error, errors, _warnings} ->
          {:error, {:compile_failed, errors}}
      end
    after
      Code.compiler_options(previous_options)
      File.rm_rf(tmp)
    end
  end

  defp built_module(module, dir) do
    beam = dir |> Path.join(Atom.to_string(module) <> ".beam") |> File.read!() |> strip()
    {module_key(module), {sha256(beam), beam}}
  end

  defp strip(beam) do
    {:ok, {_module, chunks}} =
      :beam_lib.chunks(beam, [~c"Attr" | :beam_lib.significant_chunks()], [:allow_missing_chunks])

    {:ok, stripped} =
      :beam_lib.build_module(for {_, data} = chunk <- chunks, is_binary(data), do: chunk)

    stripped
  end

  defp unload_new(modules, loaded_before) do
    for module <- modules, not MapSet.member?(loaded_before, module) do
      :code.purge(module)
      :code.delete(module)
    end

    :ok
  end

  defp sha256(binary), do: Base.encode16(:crypto.hash(:sha256, binary), case: :lower)

  defp manifest_fields(build, opts) do
    app = Keyword.fetch!(opts, :app)
    channel = opts |> Keyword.fetch!(:channel) |> to_string()

    with :ok <- check_name(:app, app),
         :ok <- check_name(:channel, channel),
         {:ok, modules} <- modules(build),
         {:ok, issued_at} <-
           datetime(:issued_at, Keyword.get_lazy(opts, :issued_at, &DateTime.utc_now/0)),
         {:ok, force_update_after} <-
           datetime(:force_update_after, Keyword.get(opts, :force_update_after)),
         {:ok, min_app_version} <- min_app_version(Keyword.get(opts, :min_app_version)) do
      fields =
        %{
          "manifest_version" => 1,
          "app" => app,
          "channel" => channel,
          "issued_at" => issued_at,
          "min_app_version" => min_app_version,
          "force_update_after" => force_update_after,
          "modules" => modules
        }
        |> Map.reject(fn {_, value} -> is_nil(value) end)

      {:ok, fields}
    end
  end

  defp check_name(field, name) do
    if Storage.valid_name?(name), do: :ok, else: {:error, {:invalid, field, name}}
  end

  defp modules(build) do
    Enum.reduce_while(build, {:ok, %{}}, fn {key, {sha, beam}}, {:ok, acc} ->
      if is_binary(key) and key != "" and is_binary(beam) and sha256(beam) == sha,
        do: {:cont, {:ok, Map.put(acc, key, "sha256:" <> sha)}},
        else: {:halt, {:error, {:invalid, :build, key}}}
    end)
  end

  defp datetime(_field, nil), do: {:ok, nil}

  defp datetime(field, iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> datetime(field, datetime)
      {:error, _} -> {:error, {:invalid, field, iso}}
    end
  end

  defp datetime(_field, %DateTime{} = datetime) do
    {:ok,
     datetime
     |> DateTime.shift_zone!("Etc/UTC")
     |> DateTime.truncate(:second)
     |> DateTime.to_iso8601()}
  end

  defp datetime(field, other), do: {:error, {:invalid, field, other}}

  defp min_app_version(nil), do: {:ok, nil}
  defp min_app_version(version) when is_binary(version) and version != "", do: {:ok, version}
  defp min_app_version(other), do: {:error, {:invalid, :min_app_version, other}}

  defp put_blobs(build, storage_mod, storage_config) do
    build
    |> Enum.uniq_by(fn {_key, {sha, _beam}} -> sha end)
    |> Enum.reduce_while(:ok, fn {_key, {sha, beam}}, :ok ->
      case storage_mod.put_blob(storage_config, sha, beam) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:put_blob, sha, reason}}}
      end
    end)
  end
end
