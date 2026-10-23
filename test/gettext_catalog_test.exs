defmodule PhoenixKitLocations.GettextCatalogTest do
  @moduledoc """
  Every user-facing string goes through `PhoenixKitLocations.Gettext`, and
  the et and ru catalogues translate all of it.

  Strings used to sit on core's `PhoenixKitWeb.Gettext`, whose catalogue
  never held them, so whole pages rendered English in every locale while
  each count said the module was complete.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Dashboard.Tab

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

  # Core's `Tab.localized_label/1` looks the label up at runtime, so a tab
  # without the backend renders its English msgid in every locale and nothing
  # warns; the extractor never sees that lookup either.
  test "every admin tab names the module's backend and its label translates in ru and et" do
    for tab <- PhoenixKitLocations.admin_tabs() do
      assert tab.gettext_backend == PhoenixKitLocations.Gettext,
             "#{tab.id} has no gettext_backend"

      assert tab.gettext_domain == "default", "#{tab.id} has no gettext_domain"

      for locale <- ~w(et ru) do
        translated =
          Gettext.with_locale(PhoenixKitLocations.Gettext, locale, fn ->
            Tab.localized_label(tab)
          end)

        refute translated == tab.label,
               "tab #{tab.id} label #{inspect(tab.label)} is not translated in #{locale}"
      end
    end
  end

  test "runtime tab labels survive extraction without source call sites" do
    labels = PhoenixKitLocations.admin_tabs() |> Enum.map(& &1.label) |> Enum.uniq()

    for path <- Path.wildcard(Path.join(@gettext, "**/*.{pot,po}")) do
      messages = Expo.PO.parse_file!(path).messages

      for label <- labels do
        message = Enum.find(messages, &(IO.iodata_to_binary(&1.msgid) == label))
        assert message, "#{inspect(label)} is missing from #{path}"

        refute "elixir-autogen" in List.flatten(message.flags),
               "#{inspect(label)} in #{path} must survive without an extractor-visible call site"
      end
    end
  end

  defp msgids(%Expo.Messages{messages: messages}) do
    for %Expo.Message.Singular{} = m <- messages, into: MapSet.new() do
      IO.iodata_to_binary(m.msgid)
    end
  end
end
