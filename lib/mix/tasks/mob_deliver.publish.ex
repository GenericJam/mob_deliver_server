defmodule Mix.Tasks.MobDeliver.Publish do
  @shortdoc "Compiles mobile/, signs a manifest, and publishes BEAMs"

  @moduledoc """
  Compiles the project's `mobile/` tree into content-addressed BEAMs,
  signs a manifest for them, and writes both to a filesystem store that
  `MobDeliverServer.Plug` serves.

      mix mob_deliver.publish --app com.example.myapp [options]

  Runs `mix compile` first, so the `mobile/` sources compile against the
  project's current code. Prints one line per module and exits non-zero on
  any failure — safe to run in CI.

  ## Options

    * `--app` (required) — app id the client is configured with;
    * `--channel` — default `production`;
    * `--mobile-dir` — default `mobile`;
    * `--key-file` — private key written by `mix mob_deliver.gen.key`.
      Without it the key is read from the `MOB_DELIVER_SIGNING_KEY`
      environment variable (the key file's contents);
    * `--out` — storage root, default `mob_deliver_publish` (keep it out
      of `priv/`: mob_dev bundles the app's `priv/` into the binary);
    * `--min-app-version` — dotted numeric, e.g. `1.4.0`; anything else is
      rejected (the client's gate couldn't compare it);
    * `--force-update-after` — ISO 8601 timestamp, e.g.
      `2026-10-19T00:00:00Z`; requires `--min-app-version`;
    * `--force` — publish even though the signing key doesn't match the
      project's `trusted_publish_key` (see below).

  ## Signing key check

  If the project the task runs in configures
  `config :mob_deliver, trusted_publish_key: ...` (the mob app's own
  config), the task refuses to publish with a key whose public half is
  different: every device built with that config would reject the
  manifest with `{:error, :invalid_signature}` and never update. Pass
  `--force` when that is intended — e.g. signing for devices still on an
  older build during a key rotation. Projects without the setting (a
  Phoenix server that isn't the mob app) aren't checked.

  To publish somewhere other than the local filesystem (S3, GCS), call
  `MobDeliverServer.build/2` + `MobDeliverServer.publish/2` with your own
  `MobDeliverServer.Storage` from a task of your own.
  """

  use Mix.Task

  @switches [
    app: :string,
    channel: :string,
    mobile_dir: :string,
    key_file: :string,
    out: :string,
    min_app_version: :string,
    force_update_after: :string,
    force: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    app = Keyword.get(opts, :app) || Mix.raise("--app is required")
    channel = Keyword.get(opts, :channel, "production")
    mobile_dir = Keyword.get(opts, :mobile_dir, "mobile")
    out = Keyword.get(opts, :out, "mob_deliver_publish")
    private_key = private_key(opts)
    gate_fields!(opts)
    check_trusted_key!(private_key, Keyword.get(opts, :force, false))

    Mix.Task.run("compile")

    build = build!(mobile_dir)

    publish_opts = [
      app: app,
      channel: channel,
      private_key: private_key,
      min_app_version: Keyword.get(opts, :min_app_version),
      force_update_after: Keyword.get(opts, :force_update_after),
      storage: {MobDeliverServer.Storage.FS, root: out}
    ]

    case MobDeliverServer.publish(build, publish_opts) do
      {:ok, %{fields: fields}} -> report(fields, out)
      {:error, reason} -> Mix.raise("mob_deliver.publish failed: #{format_error(reason)}")
    end
  end

  defp private_key(opts) do
    key =
      case Keyword.fetch(opts, :key_file) do
        {:ok, path} ->
          read_key_file(path)

        :error ->
          System.get_env("MOB_DELIVER_SIGNING_KEY") ||
            Mix.raise("pass --key-file or set MOB_DELIVER_SIGNING_KEY")
      end

    case MobDeliverServer.Manifest.decode_private_key(key) do
      {:ok, _seed} -> key
      {:error, :malformed_key} -> Mix.raise("signing key is not an ed25519-private: key")
    end
  end

  defp read_key_file(path) do
    case File.read(path) do
      {:ok, key} -> key
      {:error, reason} -> Mix.raise("could not read #{path}: #{:file.format_error(reason)}")
    end
  end

  # Before compiling: a typo in a gate flag shouldn't cost a build.
  defp gate_fields!(opts) do
    case MobDeliverServer.gate_fields(opts) do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.raise("mob_deliver.publish: #{format_error(reason)}")
    end
  end

  # `mix` loads config/config.exs before running a task, and the client
  # reads `trusted_publish_key` with `Application.compile_env/2` from
  # that same config, so the application env is the value devices built
  # from this project carry.
  defp check_trusted_key!(private_key, force?) do
    case Application.get_env(:mob_deliver, :trusted_publish_key) do
      nil ->
        :ok

      trusted ->
        signing = MobDeliverServer.Manifest.public_key_string(private_key)
        if not same_public_key?(trusted, signing), do: key_mismatch!(trusted, signing, force?)
    end
  end

  defp same_public_key?(trusted, signing) do
    case decode_public(trusted) do
      :error -> false
      public -> public == decode_public(signing)
    end
  end

  defp decode_public("ed25519:" <> encoded) do
    case Base.decode64(encoded) do
      {:ok, <<_::binary-size(32)>> = public} -> public
      _ -> :error
    end
  end

  defp decode_public(_), do: :error

  defp key_mismatch!(trusted, signing, force?) do
    message =
      "the signing key's public half (#{signing}) doesn't match " <>
        "config :mob_deliver, trusted_publish_key: #{inspect(trusted)}; " <>
        "devices built with that config will reject this manifest (:invalid_signature)"

    if force?,
      do: Mix.shell().error("warning: #{message}; publishing anyway (--force)"),
      else: Mix.raise("mob_deliver.publish: #{message}. Pass --force to publish anyway.")
  end

  defp format_error({:invalid, :min_app_version, value}),
    do: "--min-app-version must be dotted numeric like 1.4.0, got #{inspect(value)}"

  defp format_error({:invalid, :force_update_after, value}),
    do:
      "--force-update-after must be an ISO 8601 timestamp like 2026-10-19T00:00:00Z, " <>
        "got #{inspect(value)}"

  defp format_error({:force_update_after_without_min_app_version, _deadline}),
    do: "--force-update-after needs --min-app-version (the client ignores a deadline without it)"

  defp format_error(reason), do: inspect(reason)

  defp build!(mobile_dir) do
    case MobDeliverServer.build(mobile_dir) do
      {:ok, build} ->
        build

      {:error, {:no_sources, _}} ->
        Mix.raise("no .ex files under #{mobile_dir}")

      {:error, {:compile_failed, errors}} ->
        Mix.raise("compiling #{mobile_dir} failed with #{length(errors)} error(s)")
    end
  end

  defp report(fields, out) do
    shell = Mix.shell()

    for {key, "sha256:" <> sha} <- Enum.sort(fields["modules"]) do
      shell.info("  #{sha}  #{key}")
    end

    shell.info(
      "Published #{map_size(fields["modules"])} module(s) for #{fields["app"]} " <>
        "on #{fields["channel"]} (issued_at #{fields["issued_at"]}) to #{out}"
    )
  end
end
