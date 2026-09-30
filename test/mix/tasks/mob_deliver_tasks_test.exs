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

    test "refuses a key the project's trusted_publish_key doesn't match unless --force",
         %{tmp_dir: tmp_dir} do
      {private, _public} = TestHelpers.keypair()
      {other, _} = TestHelpers.keypair()
      key_file = Path.join(tmp_dir, "signing.key")
      File.write!(key_file, private <> "\n")
      name = TestHelpers.unique_module("Demo.Keyed")

      mobile =
        TestHelpers.write_sources(Path.join(tmp_dir, "mobile"), %{
          "k.ex" => "defmodule #{name}, do: def(x, do: 1)\n"
        })

      out = Path.join(tmp_dir, "store")
      args = ~w(--app a --mobile-dir #{mobile} --key-file #{key_file} --out #{out})
      put_trusted_key(Manifest.public_key_string(other))

      error = assert_raise Mix.Error, fn -> Mix.Tasks.MobDeliver.Publish.run(args) end
      assert error.message =~ Manifest.public_key_string(private)
      assert error.message =~ "--force"
      refute File.exists?(out)

      Mix.Tasks.MobDeliver.Publish.run(args ++ ["--force"])
      assert_received {:mix_shell, :error, ["warning: " <> _]}
      assert File.exists?(Path.join(out, "manifests/a/production.json"))

      # A matching key publishes quietly.
      put_trusted_key(Manifest.public_key_string(private))
      Mix.Tasks.MobDeliver.Publish.run(args)
      refute_received {:mix_shell, :error, _}
    end

    test "rejects forced-update flags the client can't use, with the flag named",
         %{tmp_dir: tmp_dir} do
      {private, _public} = TestHelpers.keypair()
      key_file = Path.join(tmp_dir, "signing.key")
      File.write!(key_file, private)
      base = ~w(--app a --mobile-dir #{tmp_dir} --key-file #{key_file})

      for {flags, expected} <- [
            {~w(--min-app-version 1.4-beta), "--min-app-version must be dotted numeric"},
            {~w(--min-app-version 1.4 --force-update-after soon), "--force-update-after must be"},
            {~w(--force-update-after 2026-10-19T00:00:00Z), "needs --min-app-version"}
          ] do
        error = assert_raise Mix.Error, fn -> Mix.Tasks.MobDeliver.Publish.run(base ++ flags) end
        assert error.message =~ expected
      end
    end
  end

  describe "mob_deliver.prune" do
    test "deletes unreferenced old blobs, and only reports with --dry-run", %{tmp_dir: tmp_dir} do
      {private, _public} = TestHelpers.keypair()
      storage = {MobDeliverServer.Storage.FS, root: tmp_dir}
      old = TestHelpers.fake_build(["Old"])

      {:ok, _} =
        MobDeliverServer.publish(old,
          app: "a",
          channel: "c",
          private_key: private,
          storage: storage
        )

      {:ok, _} =
        MobDeliverServer.publish(TestHelpers.fake_build(["New"]),
          app: "a",
          channel: "c",
          private_key: private,
          storage: storage
        )

      {old_sha, _} = old["Old"]
      age(Path.join([tmp_dir, "beam", old_sha]), 3 * 86_400)

      for path <- Path.wildcard(Path.join(tmp_dir, "replaced/**/*.json")),
          do: age(path, 3 * 86_400)

      Mix.Tasks.MobDeliver.Prune.run(~w(--out #{tmp_dir} --older-than 2d --dry-run))
      assert_received {:mix_shell, :info, ["  " <> ^old_sha]}
      assert_received {:mix_shell, :info, ["Would delete 1 blob(s)" <> _]}
      assert File.exists?(Path.join([tmp_dir, "beam", old_sha]))

      Mix.Tasks.MobDeliver.Prune.run(~w(--out #{tmp_dir} --older-than 4d))
      assert_received {:mix_shell, :info, ["Deleted 0 blob(s)" <> _]}

      Mix.Tasks.MobDeliver.Prune.run(~w(--out #{tmp_dir} --older-than 2d))
      assert_received {:mix_shell, :info, ["Deleted 1 blob(s)" <> _]}
      refute File.exists?(Path.join([tmp_dir, "beam", old_sha]))
    end

    test "rejects a grace period without a unit", %{tmp_dir: tmp_dir} do
      error =
        assert_raise Mix.Error, fn ->
          Mix.Tasks.MobDeliver.Prune.run(~w(--out #{tmp_dir} --older-than 7))
        end

      assert error.message =~ "--older-than"
    end
  end

  defp put_trusted_key(key) do
    previous = Application.fetch_env(:mob_deliver, :trusted_publish_key)
    Application.put_env(:mob_deliver, :trusted_publish_key, key)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mob_deliver, :trusted_publish_key, value)
        :error -> Application.delete_env(:mob_deliver, :trusted_publish_key)
      end
    end)
  end

  defp age(path, seconds) do
    %{mtime: mtime} = File.stat!(path, time: :posix)
    File.touch!(path, mtime - seconds)
  end
end
