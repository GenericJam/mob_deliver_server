defmodule MobDeliverServer.BuildTest do
  # Not async: the location test changes the VM's working directory, and
  # builds toggle the global :ignore_module_conflict compiler option.
  use ExUnit.Case, async: false

  alias MobDeliverServer.TestHelpers

  @moduletag :tmp_dir

  defp screen_source(name) do
    """
    defmodule #{name} do
      @moduledoc "A delivered screen."
      Module.register_attribute(__MODULE__, :delivery, persist: true)
      @delivery :expansion
      def render(assigns), do: {:text, Map.get(assigns, :title, "hi")}
    end
    """
  end

  test "keys modules inspect-style and returns loadable, hashed BEAMs", %{tmp_dir: tmp_dir} do
    elixir = TestHelpers.unique_module("Demo.HomeScreen")
    erlang = TestHelpers.unique_module("demo_erl_")

    dir =
      TestHelpers.write_sources(Path.join(tmp_dir, "mobile"), %{
        "home_screen.ex" => screen_source(elixir),
        "nested/erl.ex" => "defmodule :#{erlang} do\n  def id, do: :erl\nend\n"
      })

    assert {:ok, build} = MobDeliverServer.build(dir)
    assert Enum.sort(Map.keys(build)) == Enum.sort([elixir, ":" <> erlang])

    {sha, beam} = build[elixir]
    module = Module.concat([elixir])
    assert sha == Base.encode16(:crypto.hash(:sha256, beam), case: :lower)
    refute :code.is_loaded(module)

    {:module, ^module} = :code.load_binary(module, ~c"delivered", beam)
    assert module.render(%{title: "ok"}) == {:text, "ok"}
    assert module.module_info(:attributes)[:delivery] == [:expansion]
  end

  test "the same source compiles to the same SHA", %{tmp_dir: tmp_dir} do
    name = TestHelpers.unique_module("Demo.Stable")

    dir =
      TestHelpers.write_sources(Path.join(tmp_dir, "mobile"), %{"s.ex" => screen_source(name)})

    {:ok, first} = MobDeliverServer.build(dir)
    {:ok, second} = MobDeliverServer.build(dir)

    assert first == second
  end

  test "the SHA doesn't depend on where the checkout lives", %{tmp_dir: tmp_dir} do
    name = TestHelpers.unique_module("Demo.Moved")

    build_in = fn checkout ->
      TestHelpers.write_sources(Path.join([tmp_dir, checkout, "mobile"]), %{
        "s.ex" => screen_source(name)
      })

      File.cd!(Path.join(tmp_dir, checkout), fn -> MobDeliverServer.build("mobile") end)
    end

    {:ok, here} = build_in.("a")
    {:ok, there} = build_in.("somewhere/much/deeper")

    assert here == there
  end

  test "compile errors and empty trees are errors", %{tmp_dir: tmp_dir} do
    broken =
      TestHelpers.write_sources(Path.join(tmp_dir, "broken"), %{
        "b.ex" => "defmodule Broken do\n  def x, do: undefined_fun()\nend\n"
      })

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert {:error, {:compile_failed, [_ | _]}} = MobDeliverServer.build(broken)
    end)

    assert MobDeliverServer.build(Path.join(tmp_dir, "missing")) ==
             {:error, {:no_sources, Path.join(tmp_dir, "missing")}}
  end
end
