defmodule PtcLlmHttp.Http.Token do
  @moduledoc false

  # The RFC 9110 section 5.6.2 `token` production, in one place.
  #
  # A field name is a token on both sides of the wire: the same characters
  # that make a header we send well formed make a header we receive well
  # formed. That is one rule, not two that happen to agree, so widening or
  # narrowing it must move both directions at once.
  #
  # Field *values* are deliberately not here. What a response may contain and
  # what a request may send are separate contracts -- a response value admits
  # obs-text, a request value does not -- and each owner states its own.

  @special ~c"!#$%&'*+-.^_`|~"

  @doc "Whether every byte of `value` is a token character."
  @spec token?(binary()) :: boolean()
  def token?(value) when is_binary(value) do
    Enum.all?(:binary.bin_to_list(value), &byte?/1)
  end

  @doc "Whether one byte is a token character."
  @spec byte?(byte()) :: boolean()
  def byte?(byte),
    do: byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in @special
end
