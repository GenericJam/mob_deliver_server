defmodule MobDeliverServer.InteropTest do
  # The wire contract, checked against the real client: what this server
  # publishes and serves, mob_deliver (a test-only dep) verifies and fetches.
  # Not async: builds toggle a global compiler option.
  use ExUnit.Case, async: false

  alias MobDeliver.Client
  alias MobDeliverServer.Storage.FS
  alias MobDeliverServer.TestHelpers

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    names = for i <- 1..40, do: TestHelpers.unique_module("Interop.Screen#{i}_")

    sources =
      Map.new(names, fn name ->
        {"#{name}.ex", "defmodule #{name} do\n  def id, do: #{inspect(name)}\nend\n"}
      end)

    mobile = TestHelpers.write_sources(Path.join(tmp_dir, "mobile"), sources)
    {:ok, build} = MobDeliverServer.build(mobile)

    private = MobDeliverServer.Manifest.generate_private_key()
    storage = {FS, root: Path.join(tmp_dir, "store")}

    {:ok, published} =
      MobDeliverServer.publish(build,
        app: "com.example.app",
        channel: "production",
        private_key: private,
        min_app_version: "1.4.0",
        force_update_after: ~U[2026-10-19 00:00:00Z],
        storage: storage
      )

    # Mounted under /deliver the way Phoenix's `forward` does it.
    plug_opts = MobDeliverServer.Plug.init(storage: storage)

    mounted = fn %Plug.Conn{path_info: ["deliver" | rest]} = conn ->
      Plug.forward(conn, rest, MobDeliverServer.Plug, plug_opts)
    end

    client_opts = [
      endpoint: "https://deliver.example/deliver/",
      app: "com.example.app",
      channel: :production,
      trusted_publish_key: MobDeliverServer.Manifest.public_key_string(private),
      req_options: [plug: mounted]
    ]

    %{build: build, published: published, client_opts: client_opts, storage: storage}
  end

  test "a published 40-module manifest verifies with MobDeliver.Manifest.verify/3", ctx do
    trusted = ctx.client_opts[:trusted_publish_key]

    assert {:ok, manifest} =
             MobDeliver.Manifest.verify(ctx.published.body, trusted,
               app: "com.example.app",
               channel: "production"
             )

    assert map_size(manifest.modules) == 40
    assert manifest.modules == Map.new(ctx.build, fn {key, {sha, _beam}} -> {key, sha} end)
    assert manifest.min_app_version == "1.4.0"
    assert manifest.force_update_after == ~U[2026-10-19 00:00:00Z]
  end

  test "both sides compute the same signing payload", ctx do
    {:ok, fields} = JSON.decode(ctx.published.body)

    tricky =
      Map.put(fields, "x", %{
        "s" => List.to_string(Enum.to_list(0..0x1F)) <> "é/\"\\",
        "l" => [-1, true, nil]
      })

    assert MobDeliverServer.Manifest.signing_payload(tricky) ==
             MobDeliver.Manifest.signing_payload(tricky)
  end

  test "the client fetches the manifest and every BEAM through the plug", ctx do
    assert {:ok, manifest, body} = Client.fetch_manifest(ctx.client_opts)
    assert body == ctx.published.body

    for {key, sha} <- manifest.modules do
      {^sha, beam} = ctx.build[key]
      assert Client.fetch_beam(sha, ctx.client_opts) == {:ok, beam}
    end

    [{key, sha} | _] = Enum.to_list(manifest.modules)
    {:ok, beam} = Client.fetch_beam(sha, ctx.client_opts)
    module = MobDeliver.Manifest.key_module(key)
    {:module, ^module} = :code.load_binary(module, ~c"delivered", beam)
    assert module.id() == key
  end

  test "the client works with the plug given as Req's {plug, opts}", ctx do
    opts =
      Keyword.merge(ctx.client_opts,
        endpoint: "https://deliver.example",
        req_options: [plug: {MobDeliverServer.Plug, storage: ctx.storage}]
      )

    assert {:ok, _manifest, body} = Client.fetch_manifest(opts)
    assert body == ctx.published.body
  end

  test "the client rejects what the server says isn't there", ctx do
    assert Client.fetch_manifest(Keyword.put(ctx.client_opts, :channel, "beta")) ==
             {:error, {:http_status, 404}}

    assert Client.fetch_beam(String.duplicate("0", 64), ctx.client_opts) ==
             {:error, {:http_status, 404}}

    other_key =
      MobDeliverServer.Manifest.public_key_string(
        MobDeliverServer.Manifest.generate_private_key()
      )

    assert Client.fetch_manifest(Keyword.put(ctx.client_opts, :trusted_publish_key, other_key)) ==
             {:error, :invalid_signature}
  end
end
