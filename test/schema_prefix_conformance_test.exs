defmodule PhoenixKitLocations.SchemaPrefixConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the runtime half of named-schema (`--prefix`) support: every
  table-backed schema must `use PhoenixKit.SchemaPrefix` so its queries
  target the schema core's migrations installed into. A schema missing
  it silently falls back to `search_path` resolution — invisible on
  public installs, broken on prefixed ones.
  """

  test "every table-backed schema uses PhoenixKit.SchemaPrefix" do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.filter(fn path ->
        ast = path |> File.read!() |> Code.string_to_quoted!()

        contains?(ast, fn
          {:schema, _, [table, _]} when is_binary(table) -> true
          _ -> false
        end) and
          not contains?(ast, fn
            {:use, _, [{:__aliases__, _, [:PhoenixKit, :SchemaPrefix]}]} -> true
            _ -> false
          end)
      end)

    assert offenders == [],
           "table-backed schemas missing `use PhoenixKit.SchemaPrefix` " <>
             "(add it right after `use Ecto.Schema`): #{inspect(offenders)}"
  end

  defp contains?(ast, predicate) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, found? -> {node, found? or predicate.(node)} end)

    found?
  end
end
