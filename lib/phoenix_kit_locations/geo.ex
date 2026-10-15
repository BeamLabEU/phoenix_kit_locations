defmodule PhoenixKitLocations.Geo do
  @moduledoc """
  Country, subdivision and city lookups behind the location address form.

  A location stores:

    * `country` — the ISO 3166-1 alpha-2 code (`"EE"`),
    * `state` — the subdivision id from `BeamLabCountries.Subdivisions` (`"37"`
      for Harju county, `"NY"` for New York), or free text for a country that
      has no subdivision data,
    * `city` — the city's English name (`"Tallinn"`), or free text for a
      country that has no city data. City data is partial (a country's ten
      largest places plus its capital; every US state and Canadian province
      also has its own list), so the form tells the user to contact support
      for a missing one.

  Everything the form needs is here, so a later move of the city lookup into
  core's `PhoenixKit.Utils.CountryData` is a change to this one file.

  Rows saved before the dropdowns hold whatever was typed (`"Estonia"`,
  `"Harju"`). `normalize_country/1` and `normalize_subdivision/2` map those to
  codes when they can, `normalize_changeset/1` applies that on every write, and
  `legacy_fixes/1` lets the edit form open on the converted values. A value
  that matches nothing is kept, and the form offers it as an extra option
  instead of dropping it.
  """

  use Gettext, backend: PhoenixKitLocations.Gettext

  import Ecto.Changeset

  alias BeamLabCountries.Cities
  alias BeamLabCountries.Subdivisions
  alias PhoenixKit.Utils.CountryData

  # Countries whose city lists are kept per subdivision.
  @city_subdivision_countries ~w(US CA)

  # ── Countries ──

  @doc """
  `{label, code}` pairs for a country `<select>`. A stored value that is not a
  known code (a legacy free-text country) leads the list, so editing a row
  never silently blanks its country.

  Core labels each country with its flag (`"🇪🇪 Estonia"`). A native select
  jumps to an option by the first characters typed, so a flag in front stops
  typing "Est" from finding anything; the labels here start with the name.
  """
  @spec country_options(String.t() | nil) :: [{String.t(), String.t()}]
  def country_options(current) do
    CountryData.countries_for_select()
    |> Enum.map(fn {label, code} -> {strip_flag(label), code} end)
    |> with_current(current)
  end

  defp strip_flag(label) do
    case String.replace(label, ~r/^[^\p{L}\p{N}]+/u, "") do
      "" -> label
      name -> name
    end
  end

  @doc """
  Display name of a stored country: the localized name for a known code, the
  stored text otherwise (a legacy value shows as typed), `nil` when blank.
  """
  @spec country_name(String.t() | nil) :: String.t() | nil
  def country_name(value) do
    case blank_to_nil(value) do
      nil ->
        nil

      value ->
        case country(value) do
          nil -> value
          %{alpha2: code} -> CountryData.get_country_name(code) || value
        end
    end
  end

  @doc """
  The alpha-2 code for a stored or typed country: a code, an alpha-3 code, or a
  name in English, Estonian, Russian or any of the library's alternative names,
  matched case-insensitively. `nil` when nothing matches.
  """
  @spec normalize_country(String.t() | nil) :: String.t() | nil
  def normalize_country(value) do
    case blank_to_nil(value) do
      nil ->
        nil

      value ->
        case country(value) do
          nil -> nil
          %{alpha2: code} -> code
        end
    end
  end

  @doc """
  Lower-cased spellings a stored country may hold for `value`: its code and its
  names for a known country, the trimmed text itself otherwise, `[]` when blank.
  """
  @spec country_aliases(String.t() | nil) :: [String.t()]
  def country_aliases(value) do
    case blank_to_nil(value) do
      nil ->
        []

      value ->
        case country(value) do
          nil ->
            [String.downcase(value)]

          country ->
            Enum.map(
              [country.alpha2, country.alpha3 | country_names(country)],
              &String.downcase/1
            )
        end
    end
  end

  # ── Subdivisions ──

  @doc "Whether the country has subdivision data, so the state can be a dropdown."
  @spec subdivisions?(String.t() | nil) :: boolean()
  def subdivisions?(country_code), do: CountryData.subdivisions?(country_code)

  @doc "`{label, id}` pairs for a state `<select>`, a legacy stored value leading."
  @spec subdivision_options(String.t() | nil, String.t() | nil) :: [{String.t(), String.t()}]
  def subdivision_options(country_code, current) when is_binary(country_code) do
    country_code
    |> CountryData.subdivisions_for_select()
    |> with_current(current)
  end

  def subdivision_options(_country_code, _current), do: []

  @doc """
  The subdivision id for a stored or typed state within a country: an id or a
  name (official or alternative), case-insensitive. `nil` when nothing matches
  or the country has no subdivision data.
  """
  @spec normalize_subdivision(String.t() | nil, String.t() | nil) :: String.t() | nil
  def normalize_subdivision(country_code, value) when is_binary(country_code) do
    with value when is_binary(value) <- blank_to_nil(value),
         needle = String.downcase(value),
         %{id: id} <-
           Enum.find(Subdivisions.all(country_code), fn subdivision ->
             subdivision.id |> to_string() |> String.downcase() == needle or
               Enum.any?(subdivision_names(subdivision), &(String.downcase(&1) == needle))
           end) do
      to_string(id)
    else
      _ -> nil
    end
  end

  def normalize_subdivision(_country_code, _value), do: nil

  @doc ~s[What the country calls its first-level divisions ("State", "County", …), translated.]
  @spec subdivision_label(String.t() | nil) :: String.t()
  def subdivision_label(country_code) do
    country_code |> CountryData.get_subdivision_label() |> translate_subdivision_label()
  end

  @doc ~s["ZIP Code" for the US, "Postal Code" elsewhere.]
  @spec postal_code_label(String.t() | nil) :: String.t()
  def postal_code_label("US"), do: gettext("ZIP Code")
  def postal_code_label(_country_code), do: gettext("Postal Code")

  # ── Cities ──

  @doc """
  Whether the city can be picked from a list for this country and state. The
  US and Canada keep a list per state or province, so a state is needed there
  for a list of its own; without one the country-wide list is used.
  """
  @spec cities?(String.t() | nil, String.t() | nil) :: boolean()
  def cities?(country_code, subdivision), do: cities(country_code, subdivision) != []

  @doc """
  `{label, name}` pairs for a city `<select>`, largest first. The label is the
  name in the viewer's language when the data has one; the value is always the
  English name, which is what gets stored. A legacy stored value leads.
  """
  @spec city_options(String.t() | nil, String.t() | nil, String.t() | nil) ::
          [{String.t(), String.t()}]
  def city_options(country_code, subdivision, current) do
    locale = locale()

    country_code
    |> cities(subdivision)
    |> Enum.map(&{Cities.get_name(&1, locale), &1.name})
    |> Enum.uniq_by(&elem(&1, 1))
    |> with_current(current)
  end

  @doc "Whether a country's cities depend on the chosen state (US and Canada)."
  @spec cities_by_subdivision?(String.t() | nil) :: boolean()
  def cities_by_subdivision?(country_code), do: country_code in @city_subdivision_countries

  defp cities(country_code, subdivision) when is_binary(country_code) do
    cond do
      cities_by_subdivision?(country_code) and is_binary(subdivision) and subdivision != "" ->
        Cities.for_subdivision(country_code, subdivision)

      # Hundreds of places across the country; the state list narrows them.
      cities_by_subdivision?(country_code) ->
        Cities.for_country(country_code)

      # `limit: :all` is everything the library has for the country: the ten
      # largest places and the capital, plus any city it added by request
      # (the default list leaves those out).
      true ->
        Cities.for_country(country_code, limit: :all)
    end
  end

  defp cities(_country_code, _subdivision), do: []

  # ── Normalizing stored values ──

  @doc """
  Converts a typed or legacy `country` / `state` change on a location
  changeset to codes. Only fields being changed are touched, and a value that
  matches nothing is left as it is.
  """
  @spec normalize_changeset(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def normalize_changeset(changeset) do
    changeset
    |> update_country()
    |> update_state()
  end

  defp update_country(changeset) do
    update_change(changeset, :country, fn value -> normalize_country(value) || value end)
  end

  defp update_state(changeset) do
    country_code = changeset |> get_field(:country) |> normalize_country()
    update_change(changeset, :state, &(normalize_subdivision(country_code, &1) || &1))
  end

  @doc """
  The `country` / `state` attrs that would convert a stored legacy location to
  codes, string-keyed and only for fields that change. Pass them to
  `Locations.change_location/2` so the edit form opens on the converted values.
  """
  @spec legacy_fixes(PhoenixKitLocations.Schemas.Location.t()) :: map()
  def legacy_fixes(%{country: country, state: state}) do
    country_code = normalize_country(country)

    %{}
    |> put_if_changed("country", country, country_code)
    |> put_if_changed("state", state, normalize_subdivision(country_code, state))
  end

  defp put_if_changed(attrs, _key, _old, nil), do: attrs
  defp put_if_changed(attrs, _key, same, same), do: attrs
  defp put_if_changed(attrs, key, _old, new), do: Map.put(attrs, key, new)

  # ── Internals ──

  # The country a value names: code, alpha-3 code or a name in English, the
  # module's other languages or the library's alternative names.
  defp country(value) do
    needle = value |> String.trim() |> String.downcase()

    Enum.find(BeamLabCountries.all(), fn country ->
      String.downcase(country.alpha2) == needle or String.downcase(country.alpha3) == needle or
        Enum.any?(country_names(country), &(String.downcase(&1) == needle))
    end)
  end

  defp country_names(country) do
    translated =
      for locale <- ~w(et ru),
          name = BeamLabCountries.Translations.get_name(country.alpha2, locale),
          do: name

    [country.name | List.wrap(country.unofficial_names)] ++ translated
  end

  # Official, alternative and translated names: the dropdown shows a
  # translation (\"Harju\"), the library's own name is \"Harjumaa\".
  defp subdivision_names(subdivision) do
    translated =
      case subdivision do
        %{translations: translations} when is_map(translations) -> Map.values(translations)
        _ -> []
      end

    ([subdivision.name | List.wrap(subdivision.unofficial_names)] ++ translated)
    |> Enum.filter(&is_binary/1)
  end

  # Puts an unlisted stored value first, so a form re-render keeps it selected.
  defp with_current(options, current) do
    current = blank_to_nil(current)

    if is_nil(current) or listed?(options, current),
      do: options,
      else: [{current, current} | options]
  end

  defp listed?(options, value), do: Enum.any?(options, fn {_label, listed} -> listed == value end)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  # The viewer's language as a bare code ("et"), for localized names.
  defp locale do
    Gettext.get_locale() |> String.split(["-", "_"]) |> hd()
  end

  # Literal calls, so `mix gettext.extract` sees every label. An unknown type
  # shows as the library wrote it.
  defp translate_subdivision_label("State"), do: gettext("State")
  defp translate_subdivision_label("Province"), do: gettext("Province")

  defp translate_subdivision_label("Provinces and territories"),
    do: gettext("Province / Territory")

  defp translate_subdivision_label("Region"), do: gettext("Region")
  defp translate_subdivision_label("County"), do: gettext("County")
  defp translate_subdivision_label("District"), do: gettext("District")
  defp translate_subdivision_label("Department"), do: gettext("Department")
  defp translate_subdivision_label("Governorate"), do: gettext("Governorate")
  defp translate_subdivision_label("Municipality"), do: gettext("Municipality")
  defp translate_subdivision_label("Canton"), do: gettext("Canton")
  defp translate_subdivision_label("Oblast"), do: gettext("Oblast")
  defp translate_subdivision_label("Division"), do: gettext("Division")
  defp translate_subdivision_label("Emirate"), do: gettext("Emirate")
  defp translate_subdivision_label("Parish"), do: gettext("Parish")
  defp translate_subdivision_label("Prefecture"), do: gettext("Prefecture")
  defp translate_subdivision_label("Voivodeship"), do: gettext("Voivodeship")
  defp translate_subdivision_label("State/Province"), do: gettext("State / Region")
  defp translate_subdivision_label(other), do: other
end
