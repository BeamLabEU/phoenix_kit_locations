# Dialyzer warning skips (default file consumed by `mix dialyzer`).
#
# Gettext 1.0 + Expo 1.1 generate a `Gettext.Plural.plural/2` call against
# Expo's *opaque* `PluralForms` struct inside the generated backend (`use
# Gettext.Backend`), which Dialyzer reports as `call_without_opaque` at
# `gettext.ex:1` once the catalogue holds a plural message (the delete-subtree
# warning's `ngettext`). An upstream false positive in code this module does
# not author, scoped to the backend module and that one warning type so real
# issues elsewhere still surface; the other `phoenix_kit_*` packages with their
# own backend carry the same skip.
[
  {"lib/phoenix_kit_locations/gettext.ex", :call_without_opaque}
]
