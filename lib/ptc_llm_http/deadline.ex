defmodule PtcLlmHttp.Deadline do
  @moduledoc """
  An absolute deadline on the monotonic millisecond clock.

  The low-level API has no relative timeout. Every phase derives its remaining
  time from this one value, so no phase resets the operation budget.
  """

  alias PtcLlmHttp.Error

  @enforce_keys [:monotonic_millisecond]
  defstruct [:monotonic_millisecond]

  @opaque t :: %__MODULE__{monotonic_millisecond: integer()}

  @doc "Constructs a deadline from an absolute `System.monotonic_time/1` value."
  @spec new(integer()) :: {:ok, t()} | {:error, Error.t()}
  def new(monotonic_millisecond) when is_integer(monotonic_millisecond),
    do: {:ok, %__MODULE__{monotonic_millisecond: monotonic_millisecond}}

  def new(_value),
    do: {:error, Error.build!(:invalid_request, :validate, :request, :not_sent)}

  @doc "Returns positive milliseconds remaining, or the closed deadline error."
  @spec remaining(t()) :: {:ok, pos_integer()} | {:error, Error.t()}
  def remaining(%__MODULE__{monotonic_millisecond: deadline}) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> {:ok, remaining}
      _elapsed -> {:error, Error.build!(:deadline_exceeded, :validate, :transport, :not_sent)}
    end
  end

  @doc false
  @spec monotonic_millisecond(t()) :: integer()
  def monotonic_millisecond(%__MODULE__{monotonic_millisecond: value}), do: value

  @doc false
  @spec validate(term()) :: {:ok, t()} | :error
  def validate(%__MODULE__{monotonic_millisecond: value} = deadline) when is_integer(value),
    do: {:ok, deadline}

  def validate(_value), do: :error
end

defimpl Inspect, for: PtcLlmHttp.Deadline do
  def inspect(_deadline, _options), do: "#PtcLlmHttp.Deadline<redacted>"
end
