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

  Pre-alpha. The bounded HTTP/1 core is exercised internally against raw local
  fixtures. Provider-neutral request/response codecs and the public call API
  have not landed yet.
  """
end
