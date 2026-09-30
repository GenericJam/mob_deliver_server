defmodule MobDeliverServer.MixProject do
  use Mix.Project

  @version "0.1.0-dev"
  @source_url "https://github.com/GenericJam/mob_deliver_server"

  def project do
    [
      app: :mob_deliver_server,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs(),
      name: "MobDeliverServer"
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp description do
    "Reference server for mob_deliver: compile a Phoenix project's mobile/ " <>
      "tree into content-addressed BEAMs, sign the manifest, and serve " <>
      "wire format v1 (POST /manifest, GET /beam/:sha256) from a Plug."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "mob_deliver" => "https://github.com/GenericJam/mob_deliver"
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md"
      ]
    ]
  end

  defp deps do
    [
      # The only runtime dep: MobDeliverServer.Plug. No Phoenix — the plug
      # mounts under any Plug router, Phoenix's `forward` included.
      {:plug, "~> 1.14"},
      # Interop tests only: the real client verifies and fetches what this
      # server publishes. Never a runtime dep (AGENTS.md rule 1), and
      # `runtime: false` so its application (on-device store, poller) never
      # starts in the test VM.
      {:mob_deliver, path: "../mob_deliver", only: :test, runtime: false},
      # Code quality — Credo + ex_slop (AI-pattern checks) + jump_credo_checks,
      # mirroring mob_deliver's gate.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1.0", only: [:dev, :test], runtime: false},
      # Docs.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
