defmodule MobDeliverServer.PruneTest do
  use ExUnit.Case, async: true

  alias MobDeliverServer.Storage.FS
  alias MobDeliverServer.TestHelpers

  @moduletag :tmp_dir

  @day 86_400

  setup %{tmp_dir: tmp_dir} do
    {private, _public} = TestHelpers.keypair()
    %{private: private, config: [root: tmp_dir]}
  end

  defp publish(ctx, keys, app \\ "a", channel \\ "production") do
    build = TestHelpers.fake_build(keys)

    {:ok, _} =
      MobDeliverServer.publish(build,
        app: app,
        channel: channel,
        private_key: ctx.private,
        storage: {FS, ctx.config}
      )

    Map.new(build, fn {key, {sha, _beam}} -> {key, sha} end)
  end

  defp blob?(ctx, sha), do: File.exists?(Path.join([ctx.tmp_dir, "beam", sha]))
  defp in_days(days), do: System.os_time(:second) + days * @day

  test "keeps what any current manifest references and drops the rest once stale", ctx do
    %{"Shared" => shared, "Dropped" => dropped} = publish(ctx, ["Shared", "Dropped"])
    %{"Other" => other} = publish(ctx, ["Other"], "b", "beta")
    publish(ctx, ["Shared"])

    # A day later every blob is still inside the 7-day grace.
    assert {:ok, %{deleted: []}} = FS.prune(ctx.config, now: in_days(1))

    assert {:ok, %{deleted: [^dropped], kept: 2, replaced_deleted: 1}} =
             FS.prune(ctx.config, now: in_days(8))

    refute blob?(ctx, dropped)
    assert blob?(ctx, shared) and blob?(ctx, other)
    assert Path.wildcard(Path.join(ctx.tmp_dir, "replaced/**/*.json")) == []

    # The manifests the plug serves are untouched.
    assert {:ok, _} = FS.get_manifest(ctx.config, "a", "production")
    assert {:ok, _} = FS.get_manifest(ctx.config, "b", "beta")
  end

  test "a recently replaced manifest protects old blobs a device may still be fetching", ctx do
    %{"Dropped" => dropped} = publish(ctx, ["Dropped"])
    old = Path.join([ctx.tmp_dir, "beam", dropped])
    File.touch!(old, System.os_time(:second) - 30 * @day)

    publish(ctx, ["Next"])

    # The blob is a month old, but it left the current manifest just now.
    assert {:ok, %{deleted: []}} = FS.prune(ctx.config)
    assert blob?(ctx, dropped)
  end

  test "an unreferenced blob younger than the grace period survives (publish in flight)", ctx do
    publish(ctx, ["Current"])
    {sha, beam} = TestHelpers.fake_build(["InFlight"])["InFlight"]
    :ok = FS.put_blob(ctx.config, sha, beam)

    assert {:ok, %{deleted: []}} = FS.prune(ctx.config, older_than: 60)
    assert {:ok, %{deleted: [^sha]}} = FS.prune(ctx.config, older_than: 60, now: in_days(1))
  end

  test "dry run reports without deleting", ctx do
    %{"Dropped" => dropped} = publish(ctx, ["Dropped"])
    publish(ctx, ["Next"])

    assert {:ok, %{deleted: [^dropped], bytes: bytes, replaced_deleted: 1}} =
             FS.prune(ctx.config, now: in_days(8), dry_run: true)

    assert bytes == byte_size("beam of Dropped")
    assert blob?(ctx, dropped)
    assert [_] = Path.wildcard(Path.join(ctx.tmp_dir, "replaced/**/*.json"))
  end

  test "an unreadable manifest stops the prune before anything is deleted", ctx do
    %{"Dropped" => dropped} = publish(ctx, ["Dropped"])
    publish(ctx, ["Next"])
    broken = Path.join([ctx.tmp_dir, "manifests", "c", "production.json"])
    File.mkdir_p!(Path.dirname(broken))
    File.write!(broken, "{not json")

    assert {:error, {:unreadable_manifest, ^broken, _}} = FS.prune(ctx.config, now: in_days(8))
    assert blob?(ctx, dropped)
  end

  test "an empty or missing store prunes nothing", ctx do
    assert {:ok, %{deleted: [], kept: 0}} = FS.prune(root: Path.join(ctx.tmp_dir, "none"))
  end
end
