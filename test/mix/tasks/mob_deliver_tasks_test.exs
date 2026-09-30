defmodule Mix.Tasks.MobDeliverTasksTest do
  # Not async: swaps the global Mix shell and reads the process environment.
  use ExUnit.Case, async: false

  import Bitwise

  alias MobDeliverServer.Manifest
  alias MobDeliverServer.TestHelpers

  @moduletag :tmp_dir

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  describe "mob_deliver.gen.key" do
    test "writes a 0600 key file and prints its public key", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "keys", "signing.key"])

      Mix.Tasks.MobDeliver.Gen.Key.run(["--out", path])

      key = File.read!(path)
      assert {:ok, _seed} = Manifest.decode_private_key(key)
      assert (File.stat!(path).mode &&& 0o777) == 0o600
      assert_received {:mix_shell, :info, [message]}

      assert message =~
               ~s(config :mob_deliver, trusted_publish_key: "#{Manifest.public_key_string(key)}")
    end

    test "refuses to overwrite an existing file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "signing.key")
      File.write!(path, "precious")

      error = assert_raise Mix.Error, fn -> Mix.Tasks.MobDeliver.Gen.Key.run(["--out", path]) end
      assert error.message =~ "already exists"
      assert File.read!(path) == "precious"
    end
  end

  describe "mob_deliver.publish" do
    test "compiles mobile/, signs, and writes the store", %{tmp_dir: tmp_dir} do
      {private, _public} = TestHelpers.keypair()
      key_file = Path.join(tmp_dir, "signing.key")
      File.write!(key_file, private <> "\n")
      name = TestHelpers.unique_module("Demo.Published")

      mobile =
        TestHelpers.write_sources(Path.join(tmp_dir, "mobile"), %{
          "p.ex" => "defmodule #{name}, do: def(x, do: 1)\n"
        })

      out = Path.join(tmp_dir, "store")

      Mix.Tasks.MobDeliver.Publish.run(
        ~w(--app com.example.app --channel beta --mobile-dir #{mobile} --key-file #{key_file} --out #{out} --min-app-version 1.2.0)
      )

      {:ok, fields} =
        out |> Path.join("manifests/com.example.app/beta.json") |> File.read!() |> JSON.decode()

      assert %{"min_app_version" => "1.2.0", "modules" => %{^name => "sha256:" <> sha}} = fields
      assert File.exists?(Path.join([out, "beam", sha]))
    end

    test "fails loudly without a signing key", %{tmp_dir: tmp_dir} do
      previous = System.get_env("MOB_DELIVER_SIGNING_KEY")
      System.delete_env("MOB_DELIVER_SIGNING_KEY")
      on_exit(fn -> previous && System.put_env("MOB_DELIVER_SIGNING_KEY", previous) end)

      error =
        assert_raise Mix.Error, fn ->
          Mix.Tasks.MobDeliver.Publish.run(~w(--app a --mobile-dir #{tmp_dir}))
        end

      assert error.message =~ "MOB_DELIVER_SIGNING_KEY"
    end
  end
end
