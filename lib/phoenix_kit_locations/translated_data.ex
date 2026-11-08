defmodule PhoenixKitLocations.TranslatedData do
  @moduledoc """
  Keeps a record's `data` JSONB whole where two writers share it.

  Core's `MultilangForm` stores translations there: `"_primary_language"`
  names the main language and each language has a map of `_`-prefixed
  fields (`%{"_primary_language" => "en-US", "en-US" => %{"_name" => …},
  "fr-FR" => %{"_name" => …}}`). This module also keeps the attachment
  pointers there, top-level (`files_folder_uuid`, `featured_image_uuid`,
  see `PhoenixKitLocations.Attachments`). Three rules follow:

    * **The main-language entry mirrors the columns.** `name`,
      `description` (and a location's `public_notes`) are the main-language
      values; readers (`Spaces.translated_name/2`, `PlacePicker`) resolve a
      language as main entry ⊕ that language's overrides, so a stale main
      entry shows an old name. Only the form writes that entry, while a
      tree rename, a host's `update_location/3` or a save with multilingual
      content off change the column alone. `normalize_changeset/2` copies
      the columns into it on every write (a blank column drops the key,
      which core never stores as an override either).

    * **Pointers live top-level only.** Core's first translation of a row
      whose `data` has no multilang shape yet moves every existing key into
      the main-language entry (`Multilang.put_language_data/3`'s flat-data
      migration), pointers included, while `Attachments` writes them
      top-level again. The copies are dropped, never hoisted: a featured
      image removed since is absent top-level but still in the copy.

    * **A save with multilingual content off keeps `data`.** Core's
      `merge_translatable_params/4` then leaves `params` without `"data"`,
      and `Attachments.inject_attachment_data/3` builds one from the
      pointers alone, so a cast would replace the stored map and lose every
      translation entered while it was on. `merge_form_params/4` starts
      from the changeset's `data` instead (never a client-sent one).
  """

  import Ecto.Changeset

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitWeb.Components.MultilangForm

  @primary_language_key "_primary_language"
  @pointer_keys ~w(files_folder_uuid featured_image_uuid)

  @doc """
  Applies the first two rules to a schema changeset whose `data` has the
  multilang shape; `fields` are the translatable columns. Anything else
  passes through.
  """
  @spec normalize_changeset(Ecto.Changeset.t(), [atom()]) :: Ecto.Changeset.t()
  def normalize_changeset(%Ecto.Changeset{} = changeset, fields) do
    data = get_field(changeset, :data)

    if Multilang.multilang_data?(data) do
      normalized =
        data
        |> drop_entry_pointers()
        |> mirror_primary_entry(changeset, fields)

      if normalized == data, do: changeset, else: put_change(changeset, :data, normalized)
    else
      changeset
    end
  end

  @doc """
  `MultilangForm.merge_translatable_params/4`, plus the third rule: with
  multilingual content off, `"data"` is the changeset's own, so the save
  keeps the stored translations. Takes the same options (`:changeset` is
  required).
  """
  @spec merge_form_params(map(), Phoenix.LiveView.Socket.t(), [String.t()], keyword()) :: map()
  def merge_form_params(params, socket, fields, opts) do
    params = MultilangForm.merge_translatable_params(params, socket, fields, opts)

    if socket.assigns[:multilang_enabled] do
      params
    else
      Map.put(params, "data", get_field(Keyword.fetch!(opts, :changeset), :data) || %{})
    end
  end

  defp drop_entry_pointers(data) do
    Map.new(data, fn
      {key, %{} = entry} when key != @primary_language_key ->
        {key, Map.drop(entry, @pointer_keys)}

      other ->
        other
    end)
  end

  defp mirror_primary_entry(%{@primary_language_key => primary} = data, changeset, fields)
       when is_binary(primary) and primary != "" do
    entry =
      case Map.get(data, primary) do
        %{} = entry -> entry
        _ -> %{}
      end

    entry =
      Enum.reduce(fields, entry, fn field, acc ->
        keys = entry_keys(acc, field)

        case get_field(changeset, field) do
          value when is_binary(value) and value != "" ->
            Enum.reduce(keys, acc, &Map.put(&2, &1, value))

          _ ->
            Map.drop(acc, keys)
        end
      end)

    Map.put(data, primary, entry)
  end

  defp mirror_primary_entry(data, _changeset, _fields), do: data

  # The keys the entry already holds the field under, in its own shape:
  # core's form writes `"_name"`, a bulk or AI translation `"name"`. Adding
  # `"_name"` beside a bare `"name"` would shadow every language's bare
  # override in the merged read. Neither present: core's `"_name"`.
  defp entry_keys(entry, field) do
    case Enum.filter(["_#{field}", "#{field}"], &Map.has_key?(entry, &1)) do
      [] -> ["_#{field}"]
      keys -> keys
    end
  end
end
