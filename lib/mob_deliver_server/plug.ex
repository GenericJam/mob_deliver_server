defmodule MobDeliverServer.Plug do
  @moduledoc """
  Serves wire format v1 from a `MobDeliverServer.Storage`:

    * `POST /manifest` — body `{"app": ..., "channel": ...}` → `200` with
      the signed manifest body as published (`Content-Type:
      application/vnd.mob-deliver.v1+json`, `Cache-Control: no-cache`),
      `404` when nothing is published for that app + channel, `400` on a
      malformed request, `413` when the body exceeds `:max_body_bytes`.
    * `GET /beam/:sha256` → `200` with the raw `.beam` (`Content-Type:
      application/vnd.mob-deliver.beam`, strong `ETag` = the SHA,
      `Cache-Control: public, max-age=31536000, immutable`), `304` on a
      matching `If-None-Match`, `404` when unknown, `400` when `:sha256`
      isn't 64 lowercase hex — rejected before storage is touched.

  Mount it in a Phoenix router (no Phoenix dependency — any Plug router
  works):

      forward "/deliver", MobDeliverServer.Plug,
        storage: {MobDeliverServer.Storage.FS, root: "priv/mob_deliver"}

  and point the client's `:endpoint` at `https://example.com/deliver`.

  ## Options

    * `:storage` (required) — `{module, config}`;
    * `:max_body_bytes` — cap on the `POST /manifest` body (default
      8192).

  A Phoenix endpoint's `Plug.Parsers` usually decodes the JSON request
  body before the router forwards here; the plug then reads
  `conn.body_params` and the endpoint's parser limits apply instead of
  `:max_body_bytes`.
  """

  @behaviour Plug

  import Plug.Conn

  alias MobDeliverServer.Storage

  require Logger

  @manifest_type "application/vnd.mob-deliver.v1+json"
  @beam_type "application/vnd.mob-deliver.beam"
  @default_max_body 8_192

  @impl true
  def init(opts) do
    {module, config} = Keyword.fetch!(opts, :storage)

    %{
      storage: {module, config},
      max_body_bytes: Keyword.get(opts, :max_body_bytes, @default_max_body)
    }
  end

  @impl true
  def call(%Plug.Conn{path_info: ["manifest"], method: "POST"} = conn, opts),
    do: manifest(conn, opts)

  def call(%Plug.Conn{path_info: ["beam", sha], method: "GET"} = conn, opts),
    do: beam(conn, sha, opts)

  def call(%Plug.Conn{path_info: ["manifest"]} = conn, _opts),
    do: method_not_allowed(conn, "POST")

  def call(%Plug.Conn{path_info: ["beam", _]} = conn, _opts), do: method_not_allowed(conn, "GET")
  def call(conn, _opts), do: conn |> send_resp(404, "") |> halt()

  defp manifest(conn, %{storage: {module, config}} = opts) do
    with {:ok, conn, params} <- request_params(conn, opts),
         {:ok, app, channel} <- app_and_channel(conn, params) do
      case module.get_manifest(config, app, channel) do
        {:ok, body} ->
          conn
          |> put_resp_content_type(@manifest_type, nil)
          |> put_resp_header("cache-control", "no-cache")
          |> send_resp(200, body)
          |> halt()

        {:error, reason} ->
          storage_error(conn, reason, "manifest #{app}/#{channel}")
      end
    else
      {:error, conn, status} -> conn |> send_resp(status, "") |> halt()
    end
  end

  defp request_params(%Plug.Conn{body_params: %{"app" => _} = params} = conn, _opts),
    do: {:ok, conn, params}

  defp request_params(conn, %{max_body_bytes: max}) do
    case read_body(conn, length: max, read_length: max) do
      {:ok, body, conn} -> decode(conn, body)
      {:more, _partial, conn} -> {:error, conn, 413}
      {:error, _reason} -> {:error, conn, 400}
    end
  end

  defp decode(conn, body) do
    case JSON.decode(body) do
      {:ok, params} when is_map(params) -> {:ok, conn, params}
      _ -> {:error, conn, 400}
    end
  end

  defp app_and_channel(conn, %{"app" => app, "channel" => channel}) do
    if Storage.valid_name?(app) and Storage.valid_name?(channel),
      do: {:ok, app, channel},
      else: {:error, conn, 400}
  end

  defp app_and_channel(conn, _params), do: {:error, conn, 400}

  defp beam(conn, sha, %{storage: {module, config}}) do
    cond do
      not Storage.valid_sha?(sha) ->
        conn |> send_resp(400, "") |> halt()

      etag_matches?(conn, sha) ->
        conn |> put_beam_headers(sha) |> send_resp(304, "") |> halt()

      true ->
        case module.get_blob(config, sha) do
          {:ok, beam} ->
            conn
            |> put_beam_headers(sha)
            |> put_resp_content_type(@beam_type, nil)
            |> send_resp(200, beam)
            |> halt()

          {:error, reason} ->
            storage_error(conn, reason, "beam #{sha}")
        end
    end
  end

  defp put_beam_headers(conn, sha) do
    conn
    |> put_resp_header("etag", ~s("#{sha}"))
    |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
  end

  defp etag_matches?(conn, sha) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(&1 in ["*", ~s("#{sha}"), ~s(W/"#{sha}")]))
  end

  defp storage_error(conn, :not_found, _what), do: conn |> send_resp(404, "") |> halt()

  defp storage_error(conn, reason, what) do
    Logger.error("mob_deliver_server: reading #{what} failed: #{inspect(reason)}")
    conn |> send_resp(500, "") |> halt()
  end

  defp method_not_allowed(conn, allow),
    do: conn |> put_resp_header("allow", allow) |> send_resp(405, "") |> halt()
end
