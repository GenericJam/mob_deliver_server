defmodule Mix.Tasks.MobDeliver.Gen.Key do
  @shortdoc "Generates an Ed25519 manifest signing key"

  @moduledoc """
  Generates the Ed25519 key that signs mob_deliver manifests.

      mix mob_deliver.gen.key [--out mob_deliver_signing.key]

  Writes the private key (`ed25519-private:<base64 seed>`) to `--out`
  (default `mob_deliver_signing.key`) with mode `0600`, and prints the
  public key for the mob app's config:

      config :mob_deliver, trusted_publish_key: "ed25519:..."

  Refuses to overwrite an existing file — replacing a signing key strands
  every installed app that trusts the old one. Keep the private key out of
  version control; in CI, pass its contents via `MOB_DELIVER_SIGNING_KEY`.
  """

  use Mix.Task

  alias MobDeliverServer.Manifest

  @default_out "mob_deliver_signing.key"

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [out: :string])
    path = Keyword.get(opts, :out, @default_out)
    private_key = Manifest.generate_private_key()

    case write_private(path, private_key <> "\n") do
      :ok ->
        Mix.shell().info("""
        Wrote the private signing key to #{path} (mode 0600). Keep it out of version control.

        Add the public key to the mob app's config:

            config :mob_deliver, trusted_publish_key: "#{Manifest.public_key_string(private_key)}"
        """)

      {:error, :eexist} ->
        Mix.raise("#{path} already exists; refusing to overwrite a signing key")

      {:error, reason} ->
        Mix.raise("could not write #{path}: #{:file.format_error(reason)}")
    end
  end

  # The key is written inside a fresh 0700 directory (nobody else can open
  # the file while it's being filled), then hard-linked into place: `ln`
  # fails if the target exists, so a key is never overwritten, even racing
  # another writer.
  defp write_private(path, contents) do
    dir = Path.dirname(path)
    staging = Path.join(dir, ".mob_deliver_key-" <> MobDeliverServer.random_suffix())
    staged = Path.join(staging, "key")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.mkdir(staging) do
      try do
        with :ok <- File.chmod(staging, 0o700),
             :ok <- File.write(staged, contents, [:exclusive]),
             :ok <- File.chmod(staged, 0o600),
             do: File.ln(staged, path)
      after
        File.rm_rf(staging)
      end
    end
  end
end
