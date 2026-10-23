defmodule PhoenixKitLocations.TestBootstrapTest do
  use ExUnit.Case, async: false

  @tag :integration
  test "a migration error fails test startup instead of excluding integration tests" do
    script = """
    Code.compiler_options(ignore_module_conflict: true)
    defmodule PhoenixKit.Migration do
      def ensure_current(_repo, _opts), do: raise("migration regression under review")
    end
    Code.require_file("test/test_helper.exs")
    """

    {output, status} =
      System.cmd(System.find_executable("mix"), ["run", "--no-compile", "-e", script],
        env: [{"MIX_ENV", "test"}, {"PGPOOL", "2"}],
        stderr_to_stdout: true
      )

    assert output =~ "migration regression under review"
    refute status == 0, "migration failure was silently skipped:\n#{output}"
    refute output =~ "integration tests will be excluded"
  end

  test "an unavailable database still permits unit tests" do
    missing_database = "locations_missing_#{System.os_time(:microsecond)}"

    {output, status} =
      System.cmd(
        System.find_executable("mix"),
        ["test", "--no-compile", "test/errors_test.exs"],
        env: [{"PGDATABASE", missing_database}, {"PGPOOL", "2"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "integration tests will be excluded"
    assert output =~ "0 failures"
  end
end
