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

  @doc """
  Whether `value` is a token: one or more token characters and nothing else.

  The empty string is not a token. The production is `1*tchar`, and a caller
  that reaches for the rule by name should get the rule, not a spelling of it
  that leans on the caller to reject `""` separately.
  """
  @spec token?(binary()) :: boolean()
  def token?(<<>>), do: false

  def token?(value) when is_binary(value) do
    Enum.all?(:binary.bin_to_list(value), &byte?/1)
  end

  @doc "Whether one byte is a token character."
  @spec byte?(byte()) :: boolean()
  def byte?(byte),
    do: byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in @special
end
