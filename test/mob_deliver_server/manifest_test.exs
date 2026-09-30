defmodule MobDeliverServer.ManifestTest do
  use ExUnit.Case, async: true

  alias MobDeliverServer.Manifest
  alias MobDeliverServer.TestHelpers

  describe "signing_payload/1" do
    test "reproduces the client's golden vector byte for byte" do
      fields = %{
        "signature" => "ignored",
        "z" => [%{"b" => 1, "a" => "é/\"\\\n"}],
        "a" => %{"y" => true, "x" => nil}
      }

      assert Manifest.signing_payload(fields) ==
               ~S({"a":{"x":null,"y":true},"z":[{"a":"é/\"\\\n","b":1}]})
    end

    test "sorts keys by byte order in maps too large to iterate sorted" do
      keys = for i <- 1..40, do: "MyApp.Screen#{i}"
      modules = Map.new(keys, &{&1, 0})

      expected =
        "{\"modules\":{" <>
          (keys |> Enum.sort() |> Enum.map_join(",", &~s("#{&1}":0))) <> "}}"

      assert Manifest.signing_payload(%{"modules" => modules}) == expected
    end

    test "escapes exactly the control characters, quote and backslash" do
      controls = List.to_string(Enum.to_list(0..0x1F))

      assert Manifest.signing_payload(%{"s" => controls <> "\x7f/é\u2028\"\\"}) ==
               ~S({"s":"\u0000\u0001\u0002\u0003\u0004\u0005\u0006\u0007\b\t\n\u000B\f\r\u000E\u000F\u0010\u0011\u0012\u0013\u0014\u0015\u0016\u0017\u0018\u0019\u001A\u001B\u001C\u001D\u001E\u001F) <>
                 "\x7f/é\u2028" <> ~S(\"\\"})
    end

    test "refuses values v1 doesn't define" do
      assert_raise ArgumentError, fn -> Manifest.signing_payload(%{"n" => 1.5}) end
      assert_raise ArgumentError, fn -> Manifest.signing_payload(%{"n" => %{a: 1}}) end
      assert_raise ArgumentError, fn -> Manifest.signing_payload(%{"n" => <<0xFF>>}) end
    end
  end

  describe "sign/2" do
    test "signs the canonical payload with the key's Ed25519 key" do
      {private, public} = TestHelpers.keypair()
      fields = %{"manifest_version" => 1, "app" => "com.example.app", "modules" => %{}}

      body = Manifest.sign(fields, private)
      {:ok, decoded} = JSON.decode(body)
      "ed25519:" <> encoded = decoded["signature"]

      assert Map.delete(decoded, "signature") == fields

      assert :crypto.verify(
               :eddsa,
               :none,
               Manifest.signing_payload(fields),
               Base.decode64!(encoded),
               [
                 public,
                 :ed25519
               ]
             )
    end

    test "a changed field no longer verifies" do
      {private, public} = TestHelpers.keypair()
      {:ok, decoded} = JSON.decode(Manifest.sign(%{"app" => "a", "channel" => "beta"}, private))
      "ed25519:" <> encoded = decoded["signature"]
      tampered = %{decoded | "channel" => "production"}

      refute :crypto.verify(
               :eddsa,
               :none,
               Manifest.signing_payload(tampered),
               Base.decode64!(encoded),
               [
                 public,
                 :ed25519
               ]
             )
    end
  end

  describe "keys" do
    test "the key file round-trips and yields the client's key form" do
      private = Manifest.generate_private_key()
      {:ok, seed} = Manifest.decode_private_key(private <> "\n")
      {public, ^seed} = :crypto.generate_key(:eddsa, :ed25519, seed)

      assert Manifest.encode_private_key(seed) == private
      assert Manifest.public_key_string(private) == "ed25519:" <> Base.encode64(public)
    end

    test "malformed keys are rejected" do
      assert Manifest.decode_private_key("ed25519:" <> Base.encode64(<<0::256>>)) ==
               {:error, :malformed_key}

      assert Manifest.decode_private_key("ed25519-private:" <> Base.encode64(<<0::248>>)) ==
               {:error, :malformed_key}

      assert_raise ArgumentError, fn -> Manifest.sign(%{}, "nope") end
    end
  end
end
