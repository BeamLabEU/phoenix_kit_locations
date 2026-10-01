defmodule PhoenixKitLocations.GettextCatalogTest do
  @moduledoc """
  Every user-facing string goes through `PhoenixKitLocations.Gettext`, and
  the et and ru catalogues translate all of it.

  Strings used to sit on core's `PhoenixKitWeb.Gettext`, whose catalogue
  never held them, so whole pages rendered English in every locale while
  each count said the module was complete.
  """

  use ExUnit.Case, async: true

  @lib Path.expand("../lib", __DIR__)
  @gettext Path.expand("../priv/gettext", __DIR__)

  test "no module translates through core's backend" do
    offenders =
      Path.wildcard(Path.join(@lib, "**/*.ex"))
      |> Enum.filter(&(File.read!(&1) =~ ~r/backend:\s*PhoenixKitWeb\.Gettext/))
      |> Enum.map(&Path.relative_to(&1, @lib))

    assert offenders == [],
           "on core's Gettext backend (its catalogue lacks these strings): #{inspect(offenders)}"
  end

  for locale <- ~w(et ru) do
    test "#{locale} translates every msgid in the template, with no fuzzy guesses" do
      template_ids = msgids(Expo.PO.parse_file!(Path.join(@gettext, "default.pot")))
      po = Expo.PO.parse_file!(Path.join(@gettext, "#{unquote(locale)}/LC_MESSAGES/default.po"))

      translated =
        for %Expo.Message.Singular{} = m <- po.messages,
            IO.iodata_to_binary(m.msgstr) != "",
            "fuzzy" not in List.flatten(m.flags),
            into: MapSet.new(),
            do: IO.iodata_to_binary(m.msgid)

      missing = template_ids |> MapSet.difference(translated) |> Enum.sort()
      assert missing == [], "untranslated or fuzzy in #{unquote(locale)}: #{inspect(missing)}"
    end
  end

  test "a page string resolves in Estonian through the module's backend" do
    assert Gettext.with_locale(PhoenixKitLocations.Gettext, "et", fn ->
             PhoenixKitLocations.Errors.message(:location_not_found)
           end) == "Asukohta ei leitud."
  end

  defp msgids(%Expo.Messages{messages: messages}) do
    for %Expo.Message.Singular{} = m <- messages, into: MapSet.new() do
      IO.iodata_to_binary(m.msgid)
    end
  end
end
