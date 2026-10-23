defmodule PhoenixKitLocations.TestConfigTest do
  use ExUnit.Case, async: false

  @env_keys ~w(PGDATABASE PGPOOL MIX_TEST_PARTITION)

  setup do
    previous = Map.new(@env_keys, &{&1, System.get_env(&1)})
    Enum.each(@env_keys, &System.delete_env/1)

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)
  end

  test "unset, empty and whitespace database names use the partitioned default" do
    System.put_env("MIX_TEST_PARTITION", "3")

    for value <- [nil, "", " \t "] do
      if value, do: System.put_env("PGDATABASE", value), else: System.delete_env("PGDATABASE")
      assert repo_config()[:database] == "phoenix_kit_locations_test3"
    end
  end

  test "an explicit database is trimmed and replaces the entire partitioned name" do
    System.put_env("MIX_TEST_PARTITION", "3")
    System.put_env("PGDATABASE", " locations_review_test ")
    assert repo_config()[:database] == "locations_review_test"
  end

  test "unset, empty and whitespace pool sizes use the default" do
    for value <- [nil, "", " \t "] do
      if value, do: System.put_env("PGPOOL", value), else: System.delete_env("PGPOOL")
      assert repo_config()[:pool_size] == System.schedulers_online() * 2
    end
  end

  test "a positive pool size is trimmed and parsed completely" do
    System.put_env("PGPOOL", " 8 ")
    assert repo_config()[:pool_size] == 8

    for value <- ["0", "-1", "8x", "1.5"] do
      System.put_env("PGPOOL", value)
      assert_raise RuntimeError, ~r/PGPOOL must be a positive integer/, &repo_config/0
    end
  end

  defp repo_config do
    "config/test.exs"
    |> Config.Reader.read!(env: :test)
    |> get_in([:phoenix_kit_locations, PhoenixKitLocations.Test.Repo])
  end
end
