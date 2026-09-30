defmodule MobDeliverServer.Manifest do
  @moduledoc """
  Publisher side of wire format v1: canonical signing payload, Ed25519
  signing, and key handling.

  The contract lives in mob_deliver's
  `decisions/2026-09-19-scope-and-wire-format.md` ("Manifest signing").
  This is an independent implementation of it — the server never depends
  on the client library at runtime — pinned to the client by a golden
  vector test and by interop tests against `MobDeliver.Manifest.verify/3`.

  ## Canonical JSON

  The signature covers every top-level field except `"signature"`,
  encoded as:

    * object keys sorted by UTF-8 byte order, at every depth (sorted
      explicitly: maps with more than 32 keys don't iterate in order);
    * no whitespace between tokens;
    * strings escape only `"`, `\\`, and U+0000–U+001F (`\\b \\t \\n \\f \\r`
      short forms, otherwise `\\u00XX` uppercase hex); non-ASCII is raw
      UTF-8, `/` is not escaped;
    * integers in plain decimal; `true`, `false`, `null`;
    * no floats — v1 defines none, so encoding one raises.

  ## Keys

    * private key file: `"ed25519-private:" <> base64(32-byte seed)`;
    * public key, as the client's `config :mob_deliver,
      trusted_publish_key:` expects: `"ed25519:" <> base64(32-byte public key)`.
  """

  @private_prefix "ed25519-private:"

  @typedoc "Manifest fields with string keys, as they appear in the JSON body."
  @type fields :: %{String.t() => term()}

  @typedoc "Private key in key-file form: `\"ed25519-private:\" <> base64(seed)`."
  @type private_key :: String.t()

  @doc "Generates a new private key in key-file form."
  @spec generate_private_key() :: private_key()
  def generate_private_key do
    {_public, seed} = :crypto.generate_key(:eddsa, :ed25519)
    encode_private_key(seed)
  end

  @doc "Encodes a raw 32-byte Ed25519 seed in key-file form."
  @spec encode_private_key(<<_::256>>) :: private_key()
  def encode_private_key(<<_::binary-size(32)>> = seed),
    do: @private_prefix <> Base.encode64(seed)

  @doc """
  Decodes a key-file string (surrounding whitespace, e.g. the file's
  trailing newline, is ignored) to the raw 32-byte seed.
  """
  @spec decode_private_key(String.t()) :: {:ok, <<_::256>>} | {:error, :malformed_key}
  def decode_private_key(key) when is_binary(key) do
    with @private_prefix <> encoded <- String.trim(key),
         {:ok, <<_::binary-size(32)>> = seed} <- Base.decode64(encoded) do
      {:ok, seed}
    else
      _ -> {:error, :malformed_key}
    end
  end

  @doc """
  The client's trusted-key form (`"ed25519:" <> base64(public key)`) for a
  private key in key-file form. Raises `ArgumentError` on a malformed key.
  """
  @spec public_key_string(private_key()) :: String.t()
  def public_key_string(private_key) do
    {public, _seed} = :crypto.generate_key(:eddsa, :ed25519, seed!(private_key))
    "ed25519:" <> Base.encode64(public)
  end

  @doc """
  Signs `fields` and returns the manifest response body: the fields plus
  `"signature"`, encoded canonically. Any `"signature"` already in
  `fields` is replaced. Raises `ArgumentError` on a malformed key or a
  value canonical JSON can't encode.
  """
  @spec sign(fields(), private_key()) :: binary()
  def sign(fields, private_key) when is_map(fields) do
    signature =
      :crypto.sign(:eddsa, :none, signing_payload(fields), [seed!(private_key), :ed25519])

    fields
    |> Map.put("signature", "ed25519:" <> Base.encode64(signature))
    |> canonical()
    |> IO.iodata_to_binary()
  end

  @doc """
  The exact bytes the signature covers: `fields` minus `"signature"`,
  canonically encoded (see the moduledoc).
  """
  @spec signing_payload(fields()) :: binary()
  def signing_payload(fields) when is_map(fields) do
    fields |> Map.delete("signature") |> canonical() |> IO.iodata_to_binary()
  end

  defp seed!(private_key) do
    case decode_private_key(private_key) do
      {:ok, seed} -> seed
      {:error, :malformed_key} -> raise ArgumentError, "malformed Ed25519 private key"
    end
  end

  defp canonical(map) when is_map(map) do
    entries =
      map
      |> Enum.map(fn
        {key, value} when is_binary(key) -> {key, value}
        {key, _} -> raise ArgumentError, "object keys must be strings, got: #{inspect(key)}"
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_intersperse(?,, fn {key, value} -> [string(key), ?:, canonical(value)] end)

    [?{, entries, ?}]
  end

  defp canonical(list) when is_list(list),
    do: [?[, Enum.map_intersperse(list, ?,, &canonical/1), ?]]

  defp canonical(string) when is_binary(string), do: string(string)
  defp canonical(integer) when is_integer(integer), do: Integer.to_string(integer)
  defp canonical(true), do: "true"
  defp canonical(false), do: "false"
  defp canonical(nil), do: "null"

  defp canonical(other),
    do: raise(ArgumentError, "canonical JSON can't encode #{inspect(other)}")

  defp string(string) do
    if String.valid?(string) do
      [?", escape(string, []), ?"]
    else
      raise ArgumentError, "strings must be valid UTF-8, got: #{inspect(string)}"
    end
  end

  defp escape(<<>>, acc), do: Enum.reverse(acc)
  defp escape(<<?", rest::binary>>, acc), do: escape(rest, ["\\\"" | acc])
  defp escape(<<?\\, rest::binary>>, acc), do: escape(rest, ["\\\\" | acc])
  defp escape(<<?\b, rest::binary>>, acc), do: escape(rest, ["\\b" | acc])
  defp escape(<<?\t, rest::binary>>, acc), do: escape(rest, ["\\t" | acc])
  defp escape(<<?\n, rest::binary>>, acc), do: escape(rest, ["\\n" | acc])
  defp escape(<<?\f, rest::binary>>, acc), do: escape(rest, ["\\f" | acc])
  defp escape(<<?\r, rest::binary>>, acc), do: escape(rest, ["\\r" | acc])

  defp escape(<<byte, rest::binary>>, acc) when byte < 0x20,
    do: escape(rest, ["\\u00" <> Base.encode16(<<byte>>) | acc])

  defp escape(<<byte, rest::binary>>, acc), do: escape(rest, [byte | acc])
end
