defmodule PtcLlmHttp do
  @moduledoc """
  Bounded HTTP transport and wire codecs for LLM requests.

  This package owns one narrow job: turn a validated request into at most one
  outbound HTTP/1.1 attempt, read a bounded response, and normalize it through
  an OpenAI-compatible codec. Everything about *which* model to call, *whether*
  to call it again, and *what the answer means* belongs to the consumer.

  ## Scope

  Owned here:

    * one-attempt bounded HTTP/1 transport (DNS, TCP, TLS, framing);
    * OpenAI-compatible chat-completion request and response codecs;
    * text, tool calls, declared structured output, streaming, reported usage;
    * physical outbound-connection admission; and
    * typed, bounded transport and wire errors.

  Deliberately not owned here: model selection, provider failover, credential
  storage, application policy, call budgets, traces, pricing, model catalogs,
  and provider-native APIs.

  ## Fixed transport behavior

    * HTTP/1.1 only, sending `Connection: close`;
    * no retries, no redirects, no decompression, no cookies;
    * no proxy, and no endpoint or credential lookup from the environment;
    * HTTPS whenever a credential is present, and plain HTTP only for a
      credential-free literal loopback target that the constructor allows; and
    * every external byte is bounded before it is accumulated.

  ## Status

  Pre-alpha. Bounded OpenAI-compatible text, tool, structured-output, and
  synchronous text-streaming calls are available.
  """

  alias PtcLlmHttp.Codecs.{OpenAI, OpenAIStream}

  alias PtcLlmHttp.{
    Credential,
    Deadline,
    Error,
    ProcessBudget,
    Request,
    Response,
    StreamComplete,
    StreamHalt,
    Target,
    Transport
  }

  @doc """
  Performs one bounded non-streaming OpenAI-compatible attempt.

  The options are exact and required: a call-local credential, one absolute
  deadline, and one aggregate attempt process budget. The function never
  retries or follows redirects.
  """
  @spec call(pid(), Target.t(), Request.t(), keyword()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def call(runtime, target, request, options) when is_pid(runtime) and is_list(options) do
    with {:ok, credential, deadline, budget} <- call_options(options),
         {:ok, _remaining} <- Deadline.remaining(deadline),
         {:ok, body} <- OpenAI.encode(target, request) do
      decode_context = OpenAI.decode_context(request)

      decoder = fn response ->
        OpenAI.decode(target, decode_context, byte_size(body), response)
      end

      Transport.request(
        runtime,
        target,
        credential,
        ["chat", "completions"],
        body,
        budget,
        deadline,
        decoder: decoder
      )
    else
      :error -> invalid_request()
      {:error, error} -> call_error(error)
    end
  rescue
    _external_input -> invalid_request()
  end

  def call(_runtime, _target, _request, _options), do: invalid_request()

  @doc """
  Performs one bounded OpenAI-compatible text-streaming attempt.

  The callback executes synchronously in the attempt's monitored callback
  process and must return `:cont` or `:halt`. No socket bytes are read while a
  callback invocation is outstanding.
  """
  @spec stream(pid(), Target.t(), Request.t(), (map() -> :cont | :halt), keyword()) ::
          {:ok, StreamComplete.t()}
          | {:halted, StreamHalt.t()}
          | {:error, Error.t()}
  def stream(runtime, target, request, on_chunk, options)
      when is_pid(runtime) and is_function(on_chunk, 1) and is_list(options) do
    with {:ok, credential, deadline, budget} <- call_options(options),
         {:ok, _remaining} <- Deadline.remaining(deadline),
         {:ok, body} <- OpenAI.encode_stream(target, request) do
      decode_context = OpenAI.decode_context(request)

      decoder = fn response ->
        OpenAI.decode(target, decode_context, byte_size(body), response)
      end

      target_options = Target.codec_options(target)

      streamer = %{
        state: OpenAIStream.new(target_options.usage_guarantees),
        consume: fn state, bytes, callback_role ->
          OpenAIStream.feed(state, bytes, callback_role, on_chunk)
        end,
        complete: fn state, facts -> stream_complete(state, facts, byte_size(body)) end,
        halt: fn state, facts -> stream_halt(state, facts, byte_size(body)) end
      }

      Transport.request(
        runtime,
        target,
        credential,
        ["chat", "completions"],
        body,
        budget,
        deadline,
        decoder: decoder,
        streamer: streamer
      )
    else
      :error -> invalid_request()
      {:error, error} -> call_error(error)
    end
  rescue
    _external_input -> invalid_request()
  end

  def stream(_runtime, _target, _request, _on_chunk, _options), do: invalid_request()

  defp stream_complete(state, facts, encoded_request_bytes) do
    case OpenAIStream.finish(state) do
      {:ok, state} ->
        stream = OpenAIStream.facts(state)

        {:ok,
         {:ok,
          StreamComplete.new(
            stream.usage,
            stream.delivered_bytes,
            stream.delivered_chunks,
            stream_metadata(facts, encoded_request_bytes)
          )}}

      {:halt, state} ->
        {:ok, stream_halt(state, facts, encoded_request_bytes)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stream_halt(state, facts, encoded_request_bytes) do
    stream = OpenAIStream.facts(state)

    {:halted,
     StreamHalt.new(
       stream.usage,
       stream.delivered_bytes,
       stream.delivered_chunks,
       stream_metadata(facts, encoded_request_bytes)
     )}
  end

  defp stream_metadata(facts, encoded_request_bytes) do
    %{
      status: facts.status,
      encoded_request_bytes: encoded_request_bytes,
      response_bytes: facts.wire_bytes,
      informational_responses: facts.informational_responses,
      trailer_fields: facts.trailer_fields
    }
  end

  defp call_options(options) do
    keys = [:credential, :deadline, :process_budget]

    if Keyword.keyword?(options) and Enum.sort(Keyword.keys(options)) == keys do
      credential = Keyword.fetch!(options, :credential)
      deadline = Keyword.fetch!(options, :deadline)
      budget = Keyword.fetch!(options, :process_budget)

      with {:ok, credential} <- Credential.validate(credential),
           {:ok, deadline} <- Deadline.validate(deadline),
           {:ok, budget} <- ProcessBudget.validate(budget) do
        {:ok, credential, deadline, budget}
      else
        _invalid -> :error
      end
    else
      :error
    end
  end

  defp invalid_request,
    do: {:error, Error.build!(:invalid_request, :validate, :request, :not_sent)}

  defp call_error(error) do
    case Error.validate(error) do
      {:ok, error} -> {:error, error}
      :error -> invalid_request()
    end
  end
end
