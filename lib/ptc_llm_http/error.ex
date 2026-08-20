defmodule PtcLlmHttp.Error do
  @moduledoc """
  Closed, redacted failure facts returned by `PtcLlmHttp`.

  Errors contain only package vocabulary. They never retain endpoint values,
  credentials, request or response bodies, provider text, or raw exit reasons.
  `contract/0` is the versioned data projection consumers use for exhaustive
  mapping.
  """

  @enforce_keys [:kind, :phase, :scope, :dispatch]
  defstruct [:kind, :phase, :scope, :dispatch, :http_status, :provider_code]

  @type kind ::
          :invalid_target
          | :invalid_request
          | :invalid_credential
          | :unsupported_capability
          | :capacity_exhausted
          | :runtime_unavailable
          | :deadline_exceeded
          | :resource_limit_exceeded
          | :callback_failed
          | :internal_failure
          | :dns_failure
          | :address_rejected
          | :connect_failure
          | :tls_failure
          | :connection_closed
          | :malformed_http
          | :response_too_large
          | :unsupported_redirect
          | :unsupported_content_encoding
          | :unsupported_transfer_encoding
          | :unsupported_framing
          | :http_status
          | :malformed_provider_response
          | :provider_result_too_large
          | :malformed_stream
          | :stream_too_large
          | :invalid_tool_arguments

  @type phase ::
          :validate
          | :encode
          | :admission
          | :dns
          | :connect
          | :tls
          | :send
          | :receive_head
          | :receive_body
          | :stream
          | :decode

  @type scope :: :request | :credential | :capacity | :transport | :provider | :model
  @type dispatch :: :not_sent | :possibly_sent | :completed

  @opaque t :: %__MODULE__{
            kind: kind(),
            phase: phase(),
            scope: scope(),
            dispatch: dispatch(),
            http_status: nil | 100..599,
            provider_code: nil | atom()
          }

  @kinds [
    :invalid_target,
    :invalid_request,
    :invalid_credential,
    :unsupported_capability,
    :capacity_exhausted,
    :runtime_unavailable,
    :deadline_exceeded,
    :resource_limit_exceeded,
    :callback_failed,
    :internal_failure,
    :dns_failure,
    :address_rejected,
    :connect_failure,
    :tls_failure,
    :connection_closed,
    :malformed_http,
    :response_too_large,
    :unsupported_redirect,
    :unsupported_content_encoding,
    :unsupported_transfer_encoding,
    :unsupported_framing,
    :http_status,
    :malformed_provider_response,
    :provider_result_too_large,
    :malformed_stream,
    :stream_too_large,
    :invalid_tool_arguments
  ]

  @phases [
    :validate,
    :encode,
    :admission,
    :dns,
    :connect,
    :tls,
    :send,
    :receive_head,
    :receive_body,
    :stream,
    :decode
  ]
  @scopes [:request, :credential, :capacity, :transport, :provider, :model]
  @dispatches [:not_sent, :possibly_sent, :completed]

  @entries [
    %{
      id: :base_callback_failed,
      kind: :callback_failed,
      phases: [:stream],
      statuses: [],
      provider_codes: [],
      scopes: [:provider],
      dispatches: [:possibly_sent, :completed]
    },
    %{
      id: :base_capacity_exhausted,
      kind: :capacity_exhausted,
      phases: [:admission],
      statuses: [],
      provider_codes: [],
      scopes: [:capacity],
      dispatches: [:not_sent]
    },
    %{
      id: :base_deadline_exceeded,
      kind: :deadline_exceeded,
      phases: @phases,
      statuses: [],
      provider_codes: [],
      scopes: [:transport],
      dispatches: @dispatches
    },
    %{
      id: :base_internal_failure,
      kind: :internal_failure,
      phases: @phases,
      statuses: [],
      provider_codes: [],
      scopes: [:transport],
      dispatches: @dispatches
    },
    %{
      id: :base_invalid_credential,
      kind: :invalid_credential,
      phases: [:validate],
      statuses: [],
      provider_codes: [],
      scopes: [:credential],
      dispatches: [:not_sent]
    },
    %{
      id: :base_invalid_request,
      kind: :invalid_request,
      phases: [:validate, :encode],
      statuses: [],
      provider_codes: [],
      scopes: [:request],
      dispatches: [:not_sent]
    },
    %{
      id: :base_invalid_target,
      kind: :invalid_target,
      phases: [:validate],
      statuses: [],
      provider_codes: [],
      scopes: [:request],
      dispatches: [:not_sent]
    },
    %{
      id: :base_resource_limit_exceeded,
      kind: :resource_limit_exceeded,
      phases: @phases,
      statuses: [],
      provider_codes: [],
      scopes: [:capacity],
      dispatches: @dispatches
    },
    %{
      id: :base_runtime_unavailable,
      kind: :runtime_unavailable,
      phases: @phases,
      statuses: [],
      provider_codes: [],
      scopes: [:capacity],
      dispatches: @dispatches
    },
    %{
      id: :base_unsupported_capability,
      kind: :unsupported_capability,
      phases: [:validate, :encode],
      statuses: [],
      provider_codes: [],
      scopes: [:request, :model],
      dispatches: [:not_sent]
    }
  ]

  @doc "Returns the versioned, data-only error mapping contract."
  @spec contract() :: map()
  def contract do
    %{
      version: "error-base-v1",
      entries: @entries,
      enums: %{
        kinds: @kinds,
        phases: @phases,
        scopes: @scopes,
        provider_codes: [],
        dispatches: @dispatches
      }
    }
  end

  @doc false
  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_error}
  def new(options) when is_list(options) do
    with {:ok, facts} <- exact_facts(options),
         true <- Enum.count(@entries, &matches?(&1, facts)) == 1 do
      {:ok, struct!(__MODULE__, facts)}
    else
      _invalid -> {:error, :invalid_error}
    end
  end

  def new(_options), do: {:error, :invalid_error}

  @doc false
  @spec build!(kind(), phase(), scope(), dispatch()) :: t()
  def build!(kind, phase, scope, dispatch) do
    {:ok, error} =
      new(
        kind: kind,
        phase: phase,
        scope: scope,
        dispatch: dispatch,
        http_status: nil,
        provider_code: nil
      )

    error
  end

  defp exact_facts(options) do
    keys = [:kind, :phase, :scope, :dispatch, :http_status, :provider_code]

    if Keyword.keyword?(options) and Enum.sort(Keyword.keys(options)) == Enum.sort(keys) do
      {:ok, Map.new(options)}
    else
      {:error, :invalid_error}
    end
  end

  defp matches?(entry, facts) do
    entry.kind == facts.kind and facts.phase in entry.phases and facts.scope in entry.scopes and
      facts.dispatch in entry.dispatches and status_matches?(entry.statuses, facts.http_status) and
      facts.provider_code in [nil | entry.provider_codes]
  end

  defp status_matches?([], nil), do: true
  defp status_matches?(statuses, status), do: status in statuses
end

defimpl Inspect, for: PtcLlmHttp.Error do
  def inspect(_error, _options), do: "#PtcLlmHttp.Error<redacted>"
end
