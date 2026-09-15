# Dialyzer warning skips (default file consumed by `mix dialyzer`).

[
  # `MapSet.member?/2` is flagged as an opaqueness mismatch on this OTP/
  # Elixir combo whenever an empty `MapSet.new/1` and a populated one meet
  # at a branch (the empty set's internal representation infers as a
  # tuple, the populated one as a map — both are valid `MapSet.t()`, this
  # is a PLT/success-typing artifact, not a real type error). Same false
  # positive catalogue's `media_reorganizer.ex` hits for the same pattern.
  {"lib/phoenix_kit_locations/media_reorganizer.ex", :call_without_opaque}
]
