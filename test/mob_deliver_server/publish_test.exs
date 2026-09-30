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
end
