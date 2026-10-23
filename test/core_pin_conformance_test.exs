defmodule PhoenixKitLocations.CorePinConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the `:phoenix_kit` requirement against being re-narrowed to a single
  core MINOR, and against a local path override reaching a commit.

  The trap is the three-segment form: `~> 2.0.x` expands to
  `>= 2.0.x and < 2.1.0`, so no 2.1 or later core satisfies it. The breakage
  lands on CONSUMERS, never here — a host depending on both this module and a
  newer core minor gets an unsolvable dependency set and `mix deps.get` fails
  outright, with no degraded mode. Nothing else in this repo's own test run
  would notice, which is why the check is a test rather than a convention.

  The floor is `>= 2.63.0 and < 3.0.0`: core 2.63.0 first requires
  beamlab_countries 2.x, whose Cities API the address form uses. The
  committed dependency must resolve from Hex even when this test run uses
  the documented PHOENIX_KIT_PATH override.
  """

  @must_admit ["2.63.0", "2.63.5", "2.64.0", "2.99.4"]
  @must_reject ["1.7.236", "2.0.0", "2.38.0", "2.41.1", "2.62.2", "3.0.0"]

  setup_all do
    # Evaluate the real project without the local override in a separate VM,
    # leaving this run's Mix project and process-wide environment untouched.
    script = """
    Mix.start()
    Code.compile_file("mix.exs")
    Mix.Project.config()[:deps]
    |> :erlang.term_to_binary()
    |> Base.encode64()
    |> IO.write()
    """

    {output, status} =
      System.cmd(System.find_executable("elixir"), ["-e", script],
        env: [{"PHOENIX_KIT_PATH", nil}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    deps = output |> Base.decode64!() |> :erlang.binary_to_term()
    {:ok, dependency: Enum.find(deps, &(elem(&1, 0) == :phoenix_kit))}
  end

  test "the committed :phoenix_kit dependency uses Hex", %{dependency: dependency} do
    assert {_, requirement, opts} = normalize_dependency(dependency)
    assert is_binary(requirement), "the committed dependency needs a published requirement"

    for key <- [:path, :git, :github, :in_umbrella] do
      refute Keyword.has_key?(opts, key),
             "committed :phoenix_kit dependency uses #{key}; Hex packages need Hex dependencies"
    end
  end

  test "the :phoenix_kit requirement admits every core >= 2.63.0 minor and nothing else", %{
    dependency: dependency
  } do
    {_, requirement, _opts} = normalize_dependency(dependency)

    assert match?({:ok, _parsed}, Version.parse_requirement(requirement)),
           "`:phoenix_kit` requirement #{inspect(requirement)} is not a valid requirement"

    for version <- @must_admit do
      assert Version.match?(version, requirement),
             "`:phoenix_kit` requirement #{inspect(requirement)} rejects core #{version}. " <>
               "A pin that excludes a core minor breaks `mix deps.get` for every host " <>
               "running this module alongside that core. Keep the floor patch-precise " <>
               "and the ceiling open (`>= 2.63.0 and < 3.0.0`), never a three-segment `~>`."
    end

    for version <- @must_reject do
      refute Version.match?(version, requirement),
             "`:phoenix_kit` requirement #{inspect(requirement)} admits core #{version}, " <>
               "which is outside the range this module is verified against."
    end
  end

  defp normalize_dependency({app, requirement}) when is_binary(requirement),
    do: {app, requirement, []}

  defp normalize_dependency({app, opts}) when is_list(opts), do: {app, nil, opts}
  defp normalize_dependency({app, requirement, opts}), do: {app, requirement, opts}
end
