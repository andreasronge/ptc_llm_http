defmodule PtcLlmHttp.Http.Response do
  @moduledoc false

  @enforce_keys [
    :status,
    :body,
    :content_type,
    :wire_bytes,
    :informational_responses,
    :trailer_fields
  ]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            status: 100..599,
            body: binary(),
            content_type: nil | binary(),
            wire_bytes: non_neg_integer(),
            informational_responses: non_neg_integer(),
            trailer_fields: non_neg_integer()
          }

  @doc false
  def body(%__MODULE__{body: body}), do: body

  @doc false
  def facts(%__MODULE__{} = response) do
    %{
      status: response.status,
      content_type: response.content_type,
      wire_bytes: response.wire_bytes,
      informational_responses: response.informational_responses,
      trailer_fields: response.trailer_fields
    }
  end
end

defimpl Inspect, for: PtcLlmHttp.Http.Response do
  def inspect(_response, _options), do: "#PtcLlmHttp.Http.Response<redacted>"
end
