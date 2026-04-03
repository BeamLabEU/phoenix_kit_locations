# Check if the test database exists
db_name =
  Application.get_env(:phoenix_kit_locations, PhoenixKitLocations.Test.Repo)[:database] ||
    "phoenix_kit_locations_test"

db_check =
  case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
    {output, 0} ->
      exists =
        output
        |> String.split("\n")
        |> Enum.any?(fn line ->
          line |> String.split("|") |> List.first("") |> String.trim() == db_name
        end)

      if exists, do: :exists, else: :not_found

    _ ->
      :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n⚠  Test database "#{db_name}" not found — integration tests will be excluded.
       Run `mix test.setup` to create the test database.
    """)

    false
  else
    try do
      {:ok, _} = PhoenixKitLocations.Test.Repo.start_link()

      Ecto.Adapters.SQL.Sandbox.mode(PhoenixKitLocations.Test.Repo, :manual)
      true
    rescue
      e ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Run `mix test.setup` to create the test database.
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Run `mix test.setup` to create the test database.
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_locations, :test_repo_available, repo_available)

# Exclude integration tests when DB is not available
exclude = if repo_available, do: [], else: [:integration]

ExUnit.start(exclude: exclude)
