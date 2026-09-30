defmodule Mix.Tasks.MobDeliver.Prune do
  @shortdoc "Deletes published BEAMs no manifest references any more"

  @moduledoc """
  Deletes blobs from a filesystem store (`mix mob_deliver.publish`'s
  `--out`) that no manifest references, after a grace period.

      mix mob_deliver.prune [--out mob_deliver_publish] [--older-than 7d] [--dry-run]

  A blob survives while any current manifest under the store (every app,
  every channel) references it, while a manifest replaced within the
  grace period references it (devices that fetched that manifest just
  before a publish are still downloading), and while the blob itself is
  younger than the grace period (a publish in progress writes blobs
  first). Replaced manifests older than the grace period are deleted too.
  See `MobDeliverServer.Storage.FS.prune/2`.

  ## Options

    * `--out` — storage root, default `mob_deliver_publish`;
    * `--older-than` — grace period: a number with a unit, `s`, `m`, `h`
      or `d` (default `7d`). Keep it longer than your devices' update
      check interval;
    * `--dry-run` — print what would be deleted, delete nothing.

  Run it where the store lives (the server's storage root, if you copy
  the publish output there) and not concurrently with a publish that
  takes longer than the grace period.
  """

  use Mix.Task

  @switches [out: :string, older_than: :string, dry_run: :boolean]

  @units %{"s" => 1, "m" => 60, "h" => 3600, "d" => 86_400}

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    out = Keyword.get(opts, :out, "mob_deliver_publish")
    older_than = opts |> Keyword.get(:older_than, "7d") |> seconds!()
    dry_run? = Keyword.get(opts, :dry_run, false)

    if not File.dir?(out), do: Mix.raise("no store at #{out} (pass --out)")

    case MobDeliverServer.Storage.FS.prune([root: out],
           older_than: older_than,
           dry_run: dry_run?
         ) do
      {:ok, result} ->
        report(result, out, dry_run?)

      {:error, reason} ->
        Mix.raise("mob_deliver.prune failed, nothing deleted: #{inspect(reason)}")
    end
  end

  defp seconds!(duration) do
    {number, unit} = String.split_at(duration, -1)

    with {:ok, scale} <- Map.fetch(@units, unit),
         {n, ""} when n >= 0 <- Integer.parse(number) do
      n * scale
    else
      _ ->
        Mix.raise(
          "--older-than must be a number with a unit (s, m, h, d), e.g. 7d; got #{inspect(duration)}"
        )
    end
  end

  defp report(result, out, dry_run?) do
    shell = Mix.shell()
    verb = if dry_run?, do: "Would delete", else: "Deleted"

    for sha <- Enum.sort(result.deleted), do: shell.info("  #{sha}")

    shell.info(
      "#{verb} #{length(result.deleted)} blob(s), #{result.bytes} bytes, from #{out}; " <>
        "kept #{result.kept}. #{verb} #{result.replaced_deleted} replaced manifest(s)."
    )
  end
end
