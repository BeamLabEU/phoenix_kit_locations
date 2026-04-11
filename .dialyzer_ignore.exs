[
  # css_sources/0 callback: @callback spec says [atom()] and all PhoenixKit modules
  # return atoms, but Dialyzer infers [binary()] from the CSS compiler's to_string/1 usage.
  # False positive — upstream PhoenixKit behaviour PLT inference issue.
  {"lib/phoenix_kit_locations.ex", :callback_type_mismatch}
]
