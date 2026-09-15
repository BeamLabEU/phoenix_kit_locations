defmodule PhoenixKitLocations.DataCase do
  @moduledoc """
  Test case for tests requiring database access.
  Uses SQL Sandbox for test isolation.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      alias PhoenixKitLocations.Test.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PhoenixKitLocations.ActivityLogAssertions
      import PhoenixKitLocations.DataCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitLocations.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  Inserts a real `phoenix_kit_users` row, so `owner_uuid` foreign keys are
  satisfied. Goes through the schema rather than `Auth.register_user/1`, which
  needs core's rate-limiter process (not started in this suite) and a bcrypt
  round per call.
  """
  def fixture_user(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      email: "owner-#{n}@example.com",
      username: "owner_#{n}",
      hashed_password: "$2b$12$notarealhashjustenoughtosatisfythecolumn",
      is_active: true
    }

    TestRepo.insert!(struct(PhoenixKit.Users.Auth.User, Map.merge(defaults, attrs)))
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
