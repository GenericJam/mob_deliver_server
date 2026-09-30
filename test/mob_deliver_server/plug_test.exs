defmodule MobDeliverServer.PlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias MobDeliverServer.RecordingStorage
  alias MobDeliverServer.Storage.FS
  alias MobDeliverServer.TestHelpers

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    {private, _public} = TestHelpers.keypair()
    build = TestHelpers.fake_build(["MyApp.HomeScreen"])
    storage = {FS, root: tmp_dir}

    {:ok, %{body: body}} =
      MobDeliverServer.publish(build,
        app: "com.example.app",
        channel: "production",
        private_key: private,
        storage: storage
      )

    {sha, beam} = build["MyApp.HomeScreen"]
    %{opts: MobDeliverServer.Plug.init(storage: storage), body: body, sha: sha, beam: beam}
  end

  defp post_manifest(opts, payload) do
    :post
    |> conn("/manifest", payload)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/vnd.mob-deliver.v1+json")
    |> MobDeliverServer.Plug.call(opts)
  end

  describe "POST /manifest" do
    test "returns the published body for the app and channel", %{opts: opts, body: body} do
      conn = post_manifest(opts, ~s({"app":"com.example.app","channel":"production"}))

      assert conn.status == 200
      assert conn.resp_body == body
      assert get_resp_header(conn, "content-type") == ["application/vnd.mob-deliver.v1+json"]
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
    end

    test "uses params a Plug.Parsers upstream already decoded", %{opts: opts, body: body} do
      conn =
        :post
        |> conn("/manifest", %{"app" => "com.example.app", "channel" => "production"})
        |> MobDeliverServer.Plug.call(opts)

      assert {conn.status, conn.resp_body} == {200, body}
    end

    test "404s when nothing is published for that app + channel", %{opts: opts} do
      assert post_manifest(opts, ~s({"app":"com.example.app","channel":"beta"})).status == 404
      assert post_manifest(opts, ~s({"app":"com.other","channel":"production"})).status == 404
    end

    test "400s malformed requests without touching storage" do
      opts = MobDeliverServer.Plug.init(storage: {RecordingStorage, pid: self(), blobs: %{}})

      for payload <- [
            "not json",
            "[]",
            ~s({"app":"a"}),
            ~s({"app":"../x","channel":"p"}),
            ~s({"app":1,"channel":"p"})
          ] do
        assert post_manifest(opts, payload).status == 400
      end

      refute_received {:storage, _}
    end

    test "413s bodies over :max_body_bytes", %{opts: opts} do
      opts = %{opts | max_body_bytes: 16}

      assert post_manifest(opts, ~s({"app":"com.example.app","channel":"production"})).status ==
               413
    end
  end

  describe "GET /beam/:sha256" do
    test "serves the blob as an immutable, strongly tagged resource", %{
      opts: opts,
      sha: sha,
      beam: beam
    } do
      conn = :get |> conn("/beam/" <> sha) |> MobDeliverServer.Plug.call(opts)

      assert {conn.status, conn.resp_body} == {200, beam}
      assert get_resp_header(conn, "content-type") == ["application/vnd.mob-deliver.beam"]
      assert get_resp_header(conn, "etag") == [~s("#{sha}")]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    end

    test "304s a matching If-None-Match", %{opts: opts, sha: sha} do
      conn =
        :get
        |> conn("/beam/" <> sha)
        |> put_req_header("if-none-match", ~s("other", "#{sha}"))
        |> MobDeliverServer.Plug.call(opts)

      assert {conn.status, conn.resp_body} == {304, ""}
    end

    test "404s an unknown SHA", %{opts: opts} do
      assert (:get
              |> conn("/beam/" <> String.duplicate("0", 64))
              |> MobDeliverServer.Plug.call(opts)).status == 404
    end

    test "400s anything but 64 lowercase hex without touching storage" do
      opts = MobDeliverServer.Plug.init(storage: {RecordingStorage, pid: self(), blobs: %{}})

      for sha <- [
            String.duplicate("A", 64),
            String.duplicate("a", 63),
            String.duplicate("g", 64),
            "..%2F..%2Fetc%2Fpasswd"
          ] do
        assert (:get |> conn("/beam/" <> sha) |> MobDeliverServer.Plug.call(opts)).status == 400
      end

      refute_received {:storage, _}
    end
  end

  test "unknown routes 404 and wrong methods 405", %{opts: opts, sha: sha} do
    assert (:get |> conn("/other") |> MobDeliverServer.Plug.call(opts)).status == 404

    conn = :get |> conn("/manifest") |> MobDeliverServer.Plug.call(opts)
    assert {conn.status, get_resp_header(conn, "allow")} == {405, ["POST"]}

    assert (:delete |> conn("/beam/" <> sha) |> MobDeliverServer.Plug.call(opts)).status == 405
  end
end
