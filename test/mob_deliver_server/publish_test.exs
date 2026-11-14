defmodule MobDeliverServer.PublishTest do
  use ExUnit.Case, async: true

  alias MobDeliverServer.Manifest
  alias MobDeliverServer.Storage.FS
  alias MobDeliverServer.TestHelpers

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    {private, public} = TestHelpers.keypair()
    %{private: private, public: public, storage: {FS, root: tmp_dir}}
  end

  test "writes blobs and the signed manifest in the documented layout", ctx do
    build = TestHelpers.fake_build(["MyApp.HomeScreen", ":my_mod"])

    {:ok, %{body: body, fields: fields}} =
      MobDeliverServer.publish(build,
        app: "com.example.app",
        channel: "beta",
        private_key: ctx.private,
        min_app_version: "1.4.0",
        force_update_after: "2026-10-19T02:00:00+02:00",
        issued_at: ~U[2026-09-30 12:00:00.123456Z],
        storage: ctx.storage
      )

    for {_key, {sha, beam}} <- build do
      assert File.read!(Path.join([ctx.tmp_dir, "beam", sha])) == beam
    end

    assert File.read!(Path.join([ctx.tmp_dir, "manifests", "com.example.app", "beta.json"])) ==
             body

    {:ok, decoded} = JSON.decode(body)
    "ed25519:" <> signature = decoded["signature"]
    assert Map.delete(decoded, "signature") == fields

    assert fields == %{
             "manifest_version" => 1,
             "app" => "com.example.app",
             "channel" => "beta",
             "issued_at" => "2026-09-30T12:00:00Z",
             "min_app_version" => "1.4.0",
             "force_update_after" => "2026-10-19T00:00:00Z",
             "modules" => Map.new(build, fn {key, {sha, _}} -> {key, "sha256:" <> sha} end)
           }

    assert :crypto.verify(
             :eddsa,
             :none,
             Manifest.signing_payload(fields),
             Base.decode64!(signature),
             [
               ctx.public,
               :ed25519
             ]
           )
  end

  test "omits unset optional fields and leaves no temp files", ctx do
    {:ok, %{fields: fields}} =
      MobDeliverServer.publish(TestHelpers.fake_build(["A"]),
        app: "app",
        channel: :production,
        private_key: ctx.private,
        storage: ctx.storage
      )

    assert Map.keys(fields) |> Enum.sort() == ~w(app channel issued_at manifest_version modules)
    assert fields["channel"] == "production"
    assert ctx.tmp_dir |> Path.join("**/.tmp-*") |> Path.wildcard(match_dot: true) == []
  end

  test "rejects input the client would refuse, before writing anything", ctx do
    good = [app: "app", channel: "production", private_key: ctx.private, storage: ctx.storage]
    build = TestHelpers.fake_build(["A"])
    {sha, _} = build["A"]

    assert {:error, {:invalid, :build, "A"}} =
             MobDeliverServer.publish(%{"A" => {sha, "other bytes"}}, good)

    for version <- ["", "1.4-beta", "v1.4", "1..2", "1.0-debug", 140] do
      assert {:error, {:invalid, :min_app_version, ^version}} =
               MobDeliverServer.publish(build, Keyword.put(good, :min_app_version, version))
    end

    assert {:error, {:invalid, :force_update_after, "next tuesday"}} =
             MobDeliverServer.publish(
               build,
               good ++ [min_app_version: "1.4.0", force_update_after: "next tuesday"]
             )

    # Without a floor the client ignores the deadline.
    assert {:error, {:force_update_after_without_min_app_version, "2026-10-19T00:00:00Z"}} =
             MobDeliverServer.publish(
               build,
               Keyword.put(good, :force_update_after, "2026-10-19T00:00:00Z")
             )

    assert {:error, {:invalid, :app, "../etc"}} =
             MobDeliverServer.publish(build, Keyword.put(good, :app, "../etc"))

    assert {:error, :malformed_key} =
             MobDeliverServer.publish(build, Keyword.put(good, :private_key, "x"))

    assert File.ls!(ctx.tmp_dir) == []
  end

  describe "a publish is dated after the manifest it replaces (devices refuse older ones)" do
    setup ctx do
      %{opts: [app: "app", channel: "production", private_key: ctx.private, storage: ctx.storage]}
    end

    defp issued_at(build, opts) do
      {:ok, %{fields: %{"issued_at" => issued_at}}} = MobDeliverServer.publish(build, opts)
      issued_at
    end

    test "two publishes in the same second get increasing issued_at", %{opts: opts} do
      first = issued_at(TestHelpers.fake_build(["A"]), opts)
      second = issued_at(TestHelpers.fake_build(["B"]), opts)
      third = issued_at(TestHelpers.fake_build(["C"]), opts)

      assert first < second and second < third
    end

    test "after a future-dated publish, the next one is dated after it", %{opts: opts} do
      future = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
      issued_at(TestHelpers.fake_build(["A"]), Keyword.put(opts, :issued_at, future))

      assert issued_at(TestHelpers.fake_build(["B"]), opts) ==
               future |> DateTime.add(1) |> DateTime.to_iso8601()
    end

    test "an explicit issued_at that isn't later is refused, and nothing is written",
         %{opts: opts, tmp_dir: tmp_dir} do
      issued_at(
        TestHelpers.fake_build(["A"]),
        Keyword.put(opts, :issued_at, ~U[2026-10-02 00:00:00Z])
      )

      before = File.ls!(Path.join(tmp_dir, "beam"))
      build = TestHelpers.fake_build(["B"])

      for at <- [~U[2026-10-01 00:00:00Z], ~U[2026-10-02 00:00:00Z]] do
        assert MobDeliverServer.publish(build, Keyword.put(opts, :issued_at, at)) ==
                 {:error,
                  {:issued_at_not_after_current, DateTime.to_iso8601(at), "2026-10-02T00:00:00Z"}}
      end

      assert File.ls!(Path.join(tmp_dir, "beam")) == before
      assert issued_at(build, Keyword.put(opts, :issued_at, ~U[2026-10-03 00:00:00Z]))
    end

    test "other channels don't count", %{opts: opts} do
      future = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
      issued_at(TestHelpers.fake_build(["A"]), Keyword.put(opts, :issued_at, future))

      beta = issued_at(TestHelpers.fake_build(["A"]), Keyword.put(opts, :channel, "beta"))
      assert beta < DateTime.to_iso8601(future)
    end

    test "an unreadable current manifest stops the publish", %{opts: opts, tmp_dir: tmp_dir} do
      dir = Path.join([tmp_dir, "manifests", "app"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "production.json"), "not json")

      assert MobDeliverServer.publish(TestHelpers.fake_build(["A"]), opts) ==
               {:error, :unreadable_current_manifest}
    end
  end
end
