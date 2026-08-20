# PtcLlmHttp implementation plan

**Status:** approved project bootstrap plan. Written 2026-08-20 for the empty
`ptc_llm_http` project. The first implementation slice must update this audit
header with the initial commit and the selected OTP compatibility range.

## Goal

Build a small BEAM-native HTTP transport and wire-codec library for bounded LLM
requests. Its first consumer is PtcRunner, where it replaces the direct
`Req.post` routes and, after parity is proven, the OpenAI-compatible part of
ReqLLM.

The project exists separately so transport, TLS, HTTP parsing, streaming, and
provider-codec work can iterate under a focused test suite. PtcRunner's full
quality gates should run only at pinned integration checkpoints rather than
after every parser or codec change.

This project is not a fork or feature clone of ReqLLM. It deliberately owns a
smaller surface:

- one-attempt bounded HTTP/1 transport;
- OpenAI-compatible chat-completion codecs;
- optional Ollama-native codecs after the OpenAI-compatible path is complete;
- text, tool calls, declared structured output, streaming, and reported usage;
- physical outbound-connection admission; and
- typed, bounded transport and wire errors.

It does not own model selection, provider failover, credentials storage,
application policy, provider-task heaps, cumulative call budgets, traces,
pricing, model catalogs, or provider-native APIs.

## Success criteria

The project is successful when:

1. its public API has no dependency on PtcRunner or ReqLLM;
2. every external byte crossing the socket is bounded before accumulation;
3. every request performs at most one DNS/connect/send attempt and uses at
   most one HTTP/1 connection;
4. deadlines and cancellation close the socket and release capacity on every
   exit path;
5. direct calls cannot bypass a configured physical-connection runtime;
6. OpenAI-compatible text, tools, structured output, usage, and text streaming
   pass local wire fixtures and PtcRunner's adapter conformance suite;
7. target, credential, request, response, error, tool-call, and stream state
   inspection cannot disclose secrets, private endpoints, prompts, or model
   output;
8. the warm local gate is small enough for normal per-commit use, with slow
   compatibility and Dialyzer work left to CI or an explicit full gate; and
9. PtcRunner can pin one immutable package revision and remove ReqLLM without
   copying this implementation into its own modules.

## Companion PtcRunner contract

The companion consumer plan is
`ptc_runner/docs/plans/future/reqllm-removal.md`. That plan owns the product
decision to remove ReqLLM, host configuration, model aliases, capacity groups,
failure policy, and the migration of existing installations.

The repository boundary is:

| PtcLlmHttp owns | PtcRunner owns |
| --- | --- |
| Validated HTTP target and wire capabilities | Host document and installation schema |
| Physical global/group connection admission | VM/group/alias logical provider admission |
| Absolute transport deadline | Run and provider deadline selection |
| DNS, TCP, TLS, HTTP/1 framing | Credential resolution and data policy |
| OpenAI-compatible and Ollama codecs | Alias routing and default selection |
| Bounded response/provider error facts | Mapping into `ProviderError` and diagnostics |
| Synchronous streaming with backpressure | Adapter `Enumerable` bridge and Kernel events |
| Provider-reported usage fields | Usage budgets, accounting, and traces |
| No retry and no failover | Explicit workflow/operator failover policy |

No package module imports or returns a `PtcRunner.*` type. The PtcRunner
adapter is intentionally thin and remains in PtcRunner.

## Decisions fixed for V1

- Application and package name: `:ptc_llm_http`; top-level namespace:
  `PtcLlmHttp`.
- License: MIT, matching PtcRunner, unless changed before the first commit.
- Versioning: 0.x with breaking changes allowed. PtcRunner pins an exact tag or
  Git commit; it never follows a moving branch.
- Elixir declaration should initially match PtcRunner's `~> 1.15`. The minimum
  OTP release is not guessed: the transport spike establishes it from the
  required `:socket` and `:ssl` behavior, and CI tests that declared minimum
  plus PtcRunner's current Elixir 1.20.2 / OTP 29.0.3 environment.
- Runtime dependencies stay minimal. `Jason` is allowed for JSON. Req, Finch,
  Mint, an HTTP server, a model database, and a provider SDK are not runtime
  dependencies.
- V1 is HTTP/1.1 only and sends `Connection: close`.
- V1 never follows redirects, decompresses content, uses a proxy, reads proxy
  settings from the environment, retains cookies, or retries.
- HTTPS is required whenever credentials are present. Plain HTTP is admitted
  only for a credential-free literal loopback target explicitly allowed by the
  constructor.
- Streaming is synchronous and callback-driven so consumer backpressure is
  automatic. The package does not create an unbounded message queue or expose
  a socket-owning lazy enumerable.
- Tool calls and structured output use non-streaming calls in V1. Streaming is
  text-only until a separate tool-delta contract is specified and tested.
- Provider failover is never automatic here. A new attempt against another
  model or provider is a new PtcRunner logical call with its own authority,
  capacity, call-budget, usage, and trace record.
- Bedrock SigV4, Anthropic Messages, Google-native APIs, and other
  provider-native transports are separate adapters or packages.

## Protocol evidence and versioning

Implementation decisions use primary sources: RFC 3986 for URI syntax, RFC
9110/9112 for HTTP semantics and HTTP/1.1 framing, the WHATWG server-sent-event
format, official OpenAI-compatible provider documentation, and official Ollama
documentation if its native codec is built. Record the source URL, access date,
and relevant protocol/version in a retained `docs/protocol-evidence.md`.

Provider documentation is not treated as proof by itself. Every supported
shape also has an exact local request/response fixture. When a provider changes
wire behavior, add the new fixture and decide whether it is a compatible
extension or a target capability/version change. Do not make domain-blind
parsers permissive to accommodate one undocumented response.

## Repository bootstrap

The first commit creates only project infrastructure and a compiling empty
public namespace:

- initialize Git with default branch `main`;
- `mix new . --sup` semantics, adjusted to the module and application names;
- `mix.exs`, `.formatter.exs`, `.gitignore`, `mix.lock`;
- `README.md`, `CHANGELOG.md`, `LICENSE`, `AGENTS.md`;
- `lib/ptc_llm_http.ex` and `lib/ptc_llm_http/application.ex`;
- `test/test_helper.exs` and one application smoke test;
- `.github/workflows/ci.yml`;
- optional `mise.toml` matching PtcRunner's current development toolchain;
- ExDoc, Credo, Dialyxir, StreamData, and usage-rules tooling only in dev/test;
  and
- repository-owned `mix check` and `mix full_check` aliases or scripts.

The initial `AGENTS.md` records at minimum:

- one module per file;
- no `Process.sleep` in tests;
- owner-process state changes use atomic owner operations;
- bug fixes start with a failing integration or wire test;
- no automatic retries, redirects, decompression, or environment-based proxy;
- target/credential/error structs require redacted `Inspect` before use;
- no public API additions without updating this plan and the API contract;
- fast gates run per commit; the full gate runs before push/release; and
- conventional commit subjects.

Do not copy helpers or implementation modules from PtcRunner or ReqLLM. Wire
fixtures may be derived from published protocols or independently captured
local test traffic, with their origin documented.

## Proposed source layout

```text
lib/
  ptc_llm_http.ex
  ptc_llm_http/application.ex
  ptc_llm_http/runtime.ex
  ptc_llm_http/runtime/admission.ex
  ptc_llm_http/target.ex
  ptc_llm_http/credential.ex
  ptc_llm_http/request.ex
  ptc_llm_http/response.ex
  ptc_llm_http/error.ex
  ptc_llm_http/usage.ex
  ptc_llm_http/tool.ex
  ptc_llm_http/client.ex
  ptc_llm_http/deadline.ex
  ptc_llm_http/transport.ex
  ptc_llm_http/transport/socket_backend.ex
  ptc_llm_http/transport/dns.ex
  ptc_llm_http/transport/tcp.ex
  ptc_llm_http/transport/tls.ex
  ptc_llm_http/http/request.ex
  ptc_llm_http/http/response.ex
  ptc_llm_http/http/parser.ex
  ptc_llm_http/http/chunked.ex
  ptc_llm_http/sse/parser.ex
  ptc_llm_http/codecs/openai.ex
  ptc_llm_http/codecs/ollama.ex
test/
  support/raw_http_server.ex
  support/raw_tls_server.ex
  support/scripted_backend.ex
  fixtures/openai/
  fixtures/ollama/
  ptc_llm_http/
```

This is a responsibility map, not permission to create empty modules. Add a
module only in the slice that exercises it. If two modules would duplicate a
helper, extract one shared owner rather than copy it.

## Public API draft

The API remains small. Constructors validate external values and return typed
errors; external input must not make a public call raise. Programmer misuse of
trusted callbacks may raise after cleanup.

### Runtime

```elixir
{:ok, runtime} =
  PtcLlmHttp.Runtime.start_link(
    max_connections: 8,
    groups: %{"openrouter-account" => 4}
  )
```

The runtime owns only physical HTTP-attempt admission and backend supervision.
It does not own credentials, model aliases, logical provider tasks, or retry
policy.

Required behavior:

- `max_connections` is a VM/runtime-wide ceiling;
- every target names one configured group and its group ceiling narrows the
  global ceiling;
- global and group reservations are atomic;
- admission is non-blocking and occurs immediately before DNS/connect;
- the owner monitors the call process and releases a lease if it dies;
- normal cleanup is idempotent and exactly once;
- runtime-owner death poisons or stops the runtime rather than silently
  resetting capacity under surviving calls; and
- readiness and bounded counter snapshots are available without exposing
  target, endpoint, model, or credential data.

For V1, one admitted attempt equals at most one live outbound connection. If a
future version retains idle sockets or multiplexes HTTP/2 streams, it must add
separately named connection, stream, and request limits instead of changing the
meaning of `max_connections`.

### Target

```elixir
{:ok, target} =
  PtcLlmHttp.Target.new(
    kind: :openai_compat,
    base_url: "https://openrouter.ai/api/v1",
    model: "deepseek/deepseek-v4-flash",
    capacity_group: "openrouter-account",
    max_request_bytes: 1_000_000,
    max_response_bytes: 1_000_000,
    tools: true,
    streaming: true,
    structured_output: :json_schema,
    cache_mode: :unsupported,
    usage_guarantees: %{tokens: true, cost: false}
  )
```

The final constructor may use nested option structs, but it preserves these
facts. It validates and canonicalizes once so request execution never parses a
combined selector string.

Target invariants:

- closed kind: initially `:openai_compat`, later `:ollama`;
- absolute `http` or `https` base URL with nonempty host;
- no userinfo, query, or fragment;
- an ASCII DNS name or IPv4/IPv6 literal with no IPv6 zone identifier;
- a validated port and bounded path;
- raw path split only on literal `/`, percent-decoded within segments exactly
  once, with invalid triplets and decoded slash, backslash, NUL, or controls
  rejected;
- decoded `.` and `..` segments rejected rather than normalized;
- empty path segments retained and fixed operation segments appended by the
  codec;
- bounded model and capacity-group identifiers;
- exact capability modes and usage guarantees;
- positive request/response byte ceilings within package maxima; and
- fully redacted `Inspect`, no `Enumerable`, and no JSON encoder.

The target contains no resolved credential bytes. It may retain private
endpoint/model configuration internally, but no error or metadata projection
returns them.

### Credential

```elixir
{:ok, credential} = PtcLlmHttp.Credential.bearer(secret_bytes)
```

V1 supports `:none` and bearer authorization. The value is opaque, has redacted
`Inspect`, validates the final header-value grammar before any connection, and
is not stored in the runtime or target. It exists only for the duration of one
call. The BEAM cannot guarantee memory zeroization; the contract minimizes
copies and lifetime instead of claiming it.

Arbitrary authorization headers are not accepted. Non-secret static target
headers may be added only if a real endpoint requires them; their constructor
must reject reserved names including authorization, proxy-authorization, host,
connection, content-length, content-type, transfer-encoding, and cookies.

### Request

`PtcLlmHttp.Request.new/1` accepts a provider-neutral request containing:

- optional system text;
- ordered messages with roles `system`, `user`, `assistant`, and `tool`;
- assistant tool calls and subsequent `tool_call_id` messages;
- optional tool definitions;
- optional JSON Schema request;
- boolean cache policy interpreted through the target's closed cache mode;
- optional `max_tokens`, `temperature`, and `seed`; and
- no model, URL, headers, credentials, retry, redirect, or transport options.

The constructor enforces exact keys, types, item counts, string/JSON byte caps,
tool-name and tool-ID bounds, and the message ordering facts the wire codec
needs. Request `Inspect` is redacted because prompts and tool arguments may be
private. JSON encoding occurs before admission where possible and is rejected
if the encoded request exceeds the target cap.

### Call and streaming

```elixir
{:ok, response} =
  PtcLlmHttp.call(runtime, target, request,
    credential: credential,
    deadline: absolute_monotonic_deadline
  )

{:ok, response} =
  PtcLlmHttp.stream(runtime, target, request, on_chunk,
    credential: credential,
    deadline: absolute_monotonic_deadline
  )
```

There is no call without a runtime and no relative timeout in the low-level
API. The consumer computes one absolute monotonic deadline. Every phase reads
the remaining time from it; no phase resets the budget.

`PtcLlmHttp.Deadline` is an opaque millisecond-based value constructed from an
absolute `System.monotonic_time(:millisecond)` deadline. Public APIs do not mix
native units, wall-clock timestamps, and durations. Numeric phase durations in
metadata are integer milliseconds.

`stream/5` calls `on_chunk` synchronously. Slow callback execution therefore
applies backpressure to socket reads and still consumes the same total
deadline. Callback raise/throw/exit closes transport state and releases the
lease before propagating the callback failure. A PtcRunner adapter may bridge
this API into its current Enumerable contract, but that bridge stays outside
this package.

### Response, stream chunks, and usage

A successful non-stream response contains only normalized data:

- content string, which may be empty;
- zero or more normalized tool calls `%{id:, name:, args:}`;
- provider-reported usage fields; and
- bounded numeric transport metadata such as status, encoded request bytes,
  response bytes, and phase durations.

Response, tool-call, usage, and stream-chunk values are opaque or have redacted
`Inspect` implementations and no automatic JSON encoder. Content and argument
access is explicit because those values may be private even after successful
normalization.

The package never calculates price. A cost value is present only when the
response reports it and the codec has an exact documented field mapping.
Missing optional usage remains absent rather than becoming zero. Missing usage
promised by `usage_guarantees` is an invalid-provider-response error.

Text stream chunks are `%{delta: binary()}` and the final return carries the
complete normalized usage. The package need not retain the full generated text
when the consumer callback owns accumulation. Cumulative wire and decoded-text
caps still apply.

### Error

All expected target, capacity, transport, HTTP, protocol, and provider-response
failures return `%PtcLlmHttp.Error{}`. The closed initial taxonomy distinguishes:

- invalid target/request/credential;
- unsupported declared capability;
- capacity exhausted or runtime unavailable;
- deadline exceeded, with phase;
- DNS failure or address-set rejection;
- connection refused or other connect failure;
- TLS verification/handshake failure;
- connection closed during send/receive;
- malformed or oversized HTTP response;
- unsupported redirect, content encoding, transfer encoding, or framing;
- HTTP status response;
- malformed provider JSON or result shape; and
- malformed/oversized SSE or tool-call arguments.

The error carries stable facts, not a retry/failover decision: kind, phase,
optional HTTP status, optional bounded provider error code, and a conservative
scope such as transport, provider, model, or request only when the wire proves
it. PtcRunner decides retryability and failover.

`Inspect` is redacted. Public safe details are fixed package vocabulary.
Provider error text, if retained for private operator evidence, is separately
bounded, invalid-UTF-8 rejecting, inaccessible through ordinary `Inspect`, and
never includes raw headers, request/response bodies, endpoint, model, or
credential. If that separation cannot be made mechanically reliable, discard
provider text and return only status/code.

## Initial limit catalog

Slice 0 centralizes every cap in one internal catalog and exposes the target-
narrowable subset through constructors. These are the starting V1 values; a
different value must be justified and changed before dependent fixtures are
approved.

| Limit | Initial hard maximum |
| --- | ---: |
| Base URL / origin-form target | 8,192 bytes |
| Model identifier | 256 bytes |
| Capacity-group identifier | 128 bytes |
| Encoded request body | 1,048,576 bytes |
| Identity response payload | 1,048,576 bytes |
| Status/header line | 16,384 bytes |
| Aggregate response head | 65,536 bytes |
| Response header fields | 128 |
| Informational responses | 8 |
| Chunk-size line including extensions | 1,024 bytes |
| Aggregate trailers / trailer fields | 16,384 bytes / 64 |
| Socket read quantum | 16,384 bytes |
| SSE event / event count | 262,144 bytes / 10,000 |
| Messages / declared tools / returned tool calls | 1,024 / 128 / 128 |
| Tool name / tool-call ID | 128 / 256 bytes |
| JSON nesting / visited containers and scalar values | 64 / 100,000 |
| DNS addresses retained from one resolution | 8 |
| Non-secret static target headers | 32 |

Per-target request/response caps may only narrow the hard maximum. Individual
prompt, content, schema, tool, argument, and error fields also need caps so one
field cannot consume an aggregate through an implementation accident. JSON is
validated after decode for depth, node count, expected object shape, and
bounded strings; the provider worker's heap ceiling remains an independent
consumer defense.

Cap-plus-one reads are allowed only to prove overflow and the extra byte is not
retained in a result. Limit names and units appear in error facts and module
documentation; unnamed literals in parser/codec code are forbidden.

## Deadline, cancellation, and ownership

One call process owns one transport attempt and one capacity lease. The
ownership chain is runtime admission owner → monitored call process → DNS
worker/socket/helper. Required properties:

- expiration is checked before encoding, admission, DNS, connect, TLS, send,
  every receive, every callback, and final decode;
- admission is fail-fast, so it does not add a hidden queue timeout;
- DNS runs in a monitored cancellable worker because system resolution may
  block;
- DNS returns a bounded address count; the call makes one connect attempt to
  one selected address in V1, not a hidden sequence of retries;
- caller death closes the socket/helper and admission monitoring restores the
  slot;
- explicit cancellation uses process ownership, not a mutable global flag;
- normal completion closes the connection before releasing capacity;
- early stream halt, callback failure, malformed input, provider failure, and
  every exception path have deterministic cleanup; and
- tests use monitors and controlled fixtures, never sleeps.

Address selection must be deterministic and documented. If dual-stack
fallback is desired later, it is multiple attempts and requires an explicit
attempt budget; it is not smuggled into DNS/connect behavior.

## Transport spike: the first technical gate

Before implementing the HTTP parser, prove the socket backend contract with a
disposable spike and tests. The backend operation is conceptually:

```elixir
recv_up_to(socket, positive_max_bytes, absolute_deadline)
```

It must:

- return promptly after one or more bytes are available;
- never return more than the requested maximum;
- preserve unread bytes for later calls;
- distinguish timeout, closure, and transport error;
- be cancellable by owner death; and
- behave the same for TCP and verified TLS.

Plain TCP should evaluate OTP `:socket` nowait/select operation. TLS must test
the actual supported `:ssl` API rather than assume that an exact positive-size
read or a zero-length read has the needed cap and promptness semantics.

The spike matrix includes:

- one byte delivered while the caller asks for 4 KiB;
- a 64 KiB write while the caller asks for 1 KiB;
- a payload split across many TLS records;
- deadline before first byte and between chunks;
- peer close before and after partial data;
- caller death during DNS, TCP connect, TLS handshake, and receive; and
- repeated reads proving no loss or duplication.

If OTP TLS cannot satisfy both prompt partial delivery and the exact maximum,
stop the pure-Elixir transport slice and choose explicitly between:

1. a small repository-owned capped, length-framed port helper; or
2. revising the package security/streaming contract with PtcRunner maintainers.

Do not silently use `recv(..., 0)`, an exact-size blocking read, Mint/Finch, or
an unbounded helper. A port helper expands the project scope: it requires
frame-size validation before BEAM allocation, stderr capture, process-group
cleanup, checksum/release packaging, and Linux/macOS x64/arm64 CI.

## TLS and trust

HTTPS requires:

- certificate-chain and hostname verification;
- SNI using the original validated hostname;
- ALPN restricted to `http/1.1`;
- no insecure verification option;
- no credential-bearing plaintext fallback;
- a documented packaged trust source that works in a standalone release; and
- no secret-bearing debug logging from `:ssl` options or errors.

The trust-source spike compares OTP/platform CA access and a small CA bundle
dependency. Prefer in-memory CA data. If a file path is necessary, package and
verify it as a release asset and test a release without development files.
Target-specific custom CAs are deferred until a real deployment needs them;
they require an explicit opaque trust input, not ambient environment lookup.

## Request serialization

The serializer owns three separate grammars:

1. a closed HTTP method enum;
2. an origin-form request target assembled from already validated path
   segments and encoded exactly once; and
3. HTTP token header names plus visible-ASCII values.

It must:

- reject raw space, control bytes, fragment delimiters, invalid percent
  triplets, CR/LF, NUL, obs-fold, and non-ASCII header bytes;
- allow ordinary spaces in valid values such as `Authorization: Bearer ...`;
- reject a credential that cannot be serialized safely;
- set `Host`, `Content-Type`, `Accept`, `Accept-Encoding: identity`,
  `Connection: close`, bounded `User-Agent`, and exact `Content-Length` itself;
- prevent callers from overriding framing or authorization headers;
- enforce field count, field-size, aggregate-header, target, and request-body
  ceilings before send;
- send the head and body under the same absolute deadline; and
- report partial-send closure without retrying.

Golden wire tests cover IPv4, bracketed IPv6, default/non-default ports, base
paths, empty segments, `%20` without `%2520`, bearer authorization, and every
rejected injection form.

## HTTP response parser

The parser is incremental and consumes only `recv_up_to` chunks. It never
accumulates an unbounded line or body while looking for a delimiter.

Required bounds:

- status-line bytes;
- each header, chunk-size, and trailer line;
- aggregate response-head and trailer bytes;
- header/trailer field counts;
- informational-response count;
- chunk-extension bytes;
- encoded identity payload bytes;
- per-stream event bytes;
- cumulative decoded content/tool-argument bytes; and
- JSON document bytes before decoding.

Required behavior:

- accept one final HTTP/1.1 response after a bounded number of `1xx` responses;
- require strict CRLF framing and validate header names case-insensitively;
- accept one valid `Content-Length` or ordinary chunked framing;
- reject conflicting/duplicate length, ambiguous transfer encoding,
  close-delimited bodies, compression, upgrade, and unsupported status/framing;
- request no more than the lesser of parser need, fixed read quantum, and
  remaining cap plus one;
- detect cap-plus-one overflow before retaining the excess;
- carry bounded partial status/header/chunk/trailer state across reads;
- reject forbidden trailers and malformed chunk terminators; and
- close immediately after the complete response or any error.

The final response must carry the content type required by the selected codec:
JSON for ordinary responses and `text/event-stream` for streaming. Media type
and parameter parsing is bounded and case-insensitive where the standards
require it; a surprising HTML/text error body is not passed to the JSON codec.

Raw fixture tests must cover coalesced head/body, every delimiter split across
reads, an announced large chunk delivered by many small writes, a short
keep-alive content-length response, final short chunk, repeated `1xx`, duplicate
length, invalid chunk sizes, unterminated lines, oversized trailers, early
close, and a flooding peer.

## JSON and provider codecs

### OpenAI-compatible request

The codec builds `/chat/completions` requests from the validated target and
request. It owns:

- model insertion from the target, never request data;
- system and ordered message conversion;
- atom/string role conversion;
- assistant `tool_calls` encoding;
- tool-result `tool_call_id` encoding;
- tool-definition schema validation;
- JSON encoding of internal tool argument maps;
- `n: 1` or an equivalent single-choice invariant;
- declared `max_tokens`, temperature, and seed;
- `stream` selection;
- declared structured-output translation; and
- target-declared cache translation.

Unknown arbitrary provider parameters are not accepted in V1. Add a closed
option only with a provider fixture and a PtcRunner installation need.

### OpenAI-compatible response

Non-stream responses require a valid JSON object, nonempty choices, and one
usable assistant message. The codec:

- normalizes content and tool calls;
- verifies every returned tool name was declared by the request;
- boundedly decodes each `function.arguments` string as a JSON object;
- rejects missing, null, malformed, oversized, array/scalar arguments with
  closed errors;
- bounds tool-call count, IDs, names, and retained argument data;
- extracts token/cache/cost usage only from documented response fields;
- validates promised usage guarantees; and
- returns bounded HTTP/provider error facts without leaking the raw body.

Fixtures cover text-only, empty content with tools, parallel tool calls,
assistant tool-call replay, subsequent tool messages, malformed choices,
unknown tools, every arguments failure, absent/null usage, promised-usage
failure, and provider error shapes.

### Structured output

Target mode is one of `:json_schema`, `:json_object`, or `:unsupported`.
Requests fail before connection when the requested schema is incompatible with
the declared mode. Prompt-and-parse is not a fallback. Successful structured
content remains JSON text at this package boundary unless a later public API
adds a separately bounded decoded-object response.

### Cache policy

Cache translation is closed and target-declared. Start with `:unsupported`.
Add an OpenAI-compatible ephemeral-content mode only after a local fixture
proves exact request bytes for a supported endpoint. `cache: true` against an
unsupported target fails before connection; it is never silently ignored.

### Streaming and SSE

The SSE parser handles bounded UTF-8 `text/event-stream` data under the HTTP
body cap. It supports comments, blank-line event termination, and documented
multi-line `data` joining. It rejects oversized fields/events, invalid UTF-8,
unsupported retry/id semantics if present, and trailing partial events.

The OpenAI stream codec:

- accepts documented JSON data events and the terminal `[DONE]` marker;
- emits text deltas synchronously;
- rejects tool-call deltas in V1 rather than silently dropping them;
- requires a closed terminal state;
- extracts final usage when the target guarantees it; and
- enforces cumulative decoded-text and event-count limits.

Tests cover one large HTTP chunk containing many events, one event split across
many small writes, comments/heartbeats, multi-line data, invalid JSON, missing
`[DONE]`, usage before/after completion as supported by fixtures, early
consumer cancellation, slow consumer backpressure, and flood overflow.

### Ollama

Ollama is a later independent slice. Prefer its chat API rather than flattening
messages into a prompt. Define its target path, message/tool/schema mapping,
usage fields, and stream framing from official protocol evidence. If Ollama's
OpenAI-compatible endpoint provides the required parity, it may use the
OpenAI-compatible target instead and the native codec can be omitted.

## Observability

The package does not emit model prompts, endpoint values, credentials,
headers, bodies, or provider text through Logger or telemetry.

Successful and failed calls return bounded numeric facts sufficient for the
consumer to record safe metrics:

- queue/admission outcome (V1 has no wait duration beyond local call time);
- DNS, connect, TLS, time-to-first-byte, and total duration;
- encoded request and received payload bytes;
- HTTP status when present;
- stream event/chunk counts; and
- capacity snapshot identifiers only if they are explicitly safe labels.

Telemetry is deferred unless PtcRunner needs it. Returning metadata avoids a
runtime dependency and lets the consumer attach its own run/alias identity.
If telemetry is later added, event names and metadata receive the same
redaction tests as `Inspect`.

## Test strategy

No correctness test uses a public network or credentials. Raw local TCP/TLS
fixtures script exact bytes and lifecycle events. Property tests use fixed
case counts in CI and deterministic seeds in reproduction output.

### Test layers

| Layer | Purpose |
| --- | --- |
| Constructor tests | Exact keys/types, caps, URL policy, capabilities, redaction |
| Pure parser tests | Every fragmentation boundary and malformed framing state |
| Property tests | Fragmentation equivalence, cap preservation, serializer/parser invariants |
| Scripted-backend tests | Deadline, cancellation, partial reads/writes, cleanup |
| Raw TCP/TLS integration | Actual OTP socket semantics and one-connection behavior |
| Codec fixtures | Exact OpenAI/Ollama request and normalized response behavior |
| Concurrency tests | Global/group admission, atomic refusal, crash recovery, owner death |
| Release smoke | TLS trust and application startup in an assembled minimal release |
| PtcRunner contract tests | Thin adapter mapping, routing, limits, errors, traces, gateway cancellation |

### Security regression matrix

- target URL userinfo/query/fragment and plaintext-credential rejection;
- path double encoding, decoded separator, control, and traversal-shaped input;
- header name/value injection and reserved-header override;
- target, credential, request, error, and stream-state `Inspect` sentinels;
- response-head, body, SSE, JSON, tool-count, and argument caps;
- redirect, compression, ambiguous length, and close-delimited rejection;
- TLS hostname, chain, SNI, ALPN, expired/untrusted certificate failures;
- caller death during every external blocking phase;
- slot release after success, every error, callback failure, timeout, kill, and
  runtime-owner failure;
- no retry after partial send, timeout, 429, 5xx, refusal, or close; and
- no environment proxy, credential, or endpoint lookup.

### Test quality rules

- Reproduce bugs with a failing wire/integration test before the fix.
- Prefer parser fragmentation tables and property tests to assertions that
  mirror implementation branches.
- Use monitors, barriers, held sockets, and messages; never `Process.sleep`.
- Deterministically assert connection/attempt counts at the fixture server.
- Any live provider check is an optional consumer E2E test, not package CI.
- Run the exact failing seed and case after any load-sensitive failure.

### Resource and soak checks

An explicit, non-default soak gate repeats successful, failed, cancelled, and
malformed calls against local fixtures while sampling process count, runtime
admission, open ports, and memory. It proves no monotonic socket/process/lease
growth and reports its sampling method. A small benchmark records request
encoding, parser throughput under fragmentation, TLS handshake cost, and
connection-close overhead; benchmarks inform later decisions but do not weaken
bounds or authorize pooling.

## Fast development and CI gates

The project is intended to remove routine work from PtcRunner's eight-minute
push path. Its own gates must stay proportionate.

### Per-commit local gate: `mix check`

- dependency lock check;
- formatting check;
- compilation with warnings as errors;
- Credo on changed production code or the full small tree;
- unit, parser, codec, and local integration tests excluding explicitly tagged
  compatibility/release tests; and
- generated-fixture staleness check if generators are introduced.

Target: comfortably under one minute warm on the maintainer machine. Do not
weaken property counts or correctness coverage to hit the target; split a
genuinely expensive platform/release check into `full_check` with its reason
documented.

### Before push/release: `mix full_check`

- everything in `mix check`;
- Dialyzer;
- minimum/current Elixir-OTP compatibility matrix locally where available;
- raw TLS and minimal-release smoke;
- docs with warnings as errors;
- dependency/license audit; and
- package build plus contents inspection.

The Git pre-push hook should run the fast deterministic gate and may leave the
platform matrix/Dialyzer to GitHub Actions if their local cost defeats the
project's purpose. A release always requires the complete CI result.

### GitHub Actions

Use independent jobs with cancellation for superseded PR runs:

- format/compile/Credo/unit/property tests on Linux current toolchain;
- minimum supported Elixir/OTP compatibility;
- macOS current toolchain for socket/TLS behavior;
- Dialyzer with cache;
- minimal release/package verification; and
- optional native-helper platform matrix only if the TLS spike requires it.

Pin action versions and toolchains. Cache by OS/architecture/OTP/Elixir and
`mix.lock`. Do not run PtcRunner's full suite from every package PR; the
consumer repository owns its pinned-dependency integration gate.

## Parallel-agent workflow

- Each agent works in its own Git worktree and runs focused tests while
  iterating.
- Do not share a writable `_build` or project Dialyzer PLT between concurrent
  worktrees; shared immutable dependency/PLT caches are allowed only with
  race-safe tooling.
- Assign files/slices so two agents do not edit the same parser owner.
- Serialize `mix full_check`, release builds, and PtcRunner integration gates
  on the machine instead of running several CPU-saturating copies at once.
- One integration owner batches package commits into a pinned revision and
  performs the PtcRunner dependency update.
- Review concurrency and transport changes using a fault matrix: owner death,
  callback death, timeout, peer close, parser rejection, and cleanup.

## PtcRunner integration workflow

### Development override

PtcRunner may add a dev/test-only `PTC_LLM_HTTP_PATH` dependency override using
the same pattern it already uses for `PTC_EX_DNA_PATH`. Published and
production builds always resolve the pinned Git/Hex dependency. The override
must stay set consistently for every Mix command in that build and must never
affect the lock used by releases.

Do not add this project as a nested Git repository inside PtcRunner. That would
keep its changes in PtcRunner's path classifier and preserve the slow push
problem this extraction is intended to solve.

### Thin adapter responsibilities

The PtcRunner adapter:

- compiles its tagged host target into `PtcLlmHttp.Target`;
- resolves one credential lease and constructs the opaque credential value;
- supplies the absolute provider/run deadline;
- acquires PtcRunner's logical VM/group/alias provider admission;
- calls the package runtime for physical connection admission and transport;
- maps normalized response/tool/usage data into `PtcRunner.LLM` values;
- maps `%PtcLlmHttp.Error{}` facts into bounded `ProviderError` and private
  inspection evidence;
- bridges synchronous stream callbacks into the existing adapter streaming
  contract without an unbounded mailbox; and
- records alias, installation revision, logical call budget, and safe transport
  metadata in PtcRunner-owned traces.

The adapter does not rebuild HTTP requests, parse provider JSON, retry, or
special-case raw provider bodies. If it needs to do so, the package boundary is
wrong or incomplete.

### Integration checkpoints

1. Pin the bootstrap package and prove compile/application startup only.
2. Integrate target construction and redaction without selecting the new
   adapter.
3. Run an OpenAI-compatible local fixture through the full Kernel requester.
4. Run adapter parity fixtures for text, errors, tools, structured output,
   usage, and streaming.
5. Run concurrent command/host/gateway tests proving logical and physical
   capacity interact without pool starvation or leaks.
6. Run supported live E2E against one OpenAI-compatible endpoint.
7. Make the new adapter selectable while ReqLLM remains available.
8. Cut over shipped examples/defaults, then remove ReqLLM under the companion
   plan.

Update the package pin only at these coherent checkpoints. Root `mix.exs`,
`mix.lock`, dependency source, and release changes receive PtcRunner's normal
full compile/precommit/push verification.

## Delivery slices

### Slice 0 — bootstrap and contract freeze

- Create the repository infrastructure and public module skeleton.
- Record supported Elixir/OTP candidates.
- Finalize opaque types and error vocabulary without implementing HTTP.
- Add redaction and constructor contract tests first.
- Establish `mix check`, `mix full_check`, CI, and package contents.

Exit: a tagged `0.0.1`-style development checkpoint can be pinned by
PtcRunner, but performs no network request.

### Slice 1 — socket/TLS feasibility spike

- Implement disposable TCP/TLS `recv_up_to` probes and the full spike matrix.
- Decide pure OTP versus capped port helper.
- Fix the minimum OTP and release trust-source strategy.
- Delete disposable probe code that is not part of the selected backend; keep
  the conformance tests.

Exit: backend feasibility is proven on Linux and macOS, or the project stops
with a documented blocker before building on an unsafe primitive.

### Slice 2 — target, credential, deadline, and admission runtime

- Implement opaque constructors and redacted inspection.
- Implement absolute deadlines.
- Implement atomic global/group physical admission and fail-stop ownership.
- Prove release on every lifecycle path using a scripted backend.

Exit: no HTTP parsing yet, but one attempt can be safely admitted, cancelled,
and cleaned up.

### Slice 3 — bounded HTTP/1 core

- Implement DNS, TCP/TLS connect, request serialization, send, incremental
  response parser, content-length, and chunked framing.
- Add raw TCP/TLS fixtures and property-based fragmentation tests.
- Enforce single connection/attempt, no redirects/compression/retries.

Exit: arbitrary bounded JSON echo requests work against local fixtures without
provider semantics.

### Slice 4 — OpenAI-compatible text and errors

- Implement target operation paths, message request codec, text response,
  provider error facts, and usage extraction.
- Add exact wire fixtures and local integration.
- Integrate PtcRunner text calls at a pinned package revision.

Exit: text parity is independently releasable while ReqLLM remains selected for
other capability modes.

### Slice 5 — tools and structured output

- Implement tool definitions, assistant/tool messages, parallel tool calls,
  bounded argument decoding, and declared structured-output modes.
- Add all closed malformed/null/oversized outcomes.
- Run PtcRunner tool-loop and schema parity fixtures.

Exit: non-streaming Kernel capability parity for supported targets.

### Slice 6 — streaming

- Implement bounded SSE parsing and synchronous text-delta callbacks.
- Prove backpressure, cancellation, early halt, terminal usage, and cumulative
  caps.
- Add the PtcRunner Enumerable bridge and gateway disconnect tests in the
  consumer repository.

Exit: text streaming parity without tool-delta support.

### Slice 7 — cache mode, observability, and hardening

- Add only the cache translation proven by a real supported endpoint.
- Finalize safe numeric metadata and private error-evidence access.
- Run fuzz/property expansion, TLS release smoke, dependency audit, docs, and
  independent security review.

Exit: release candidate for PtcRunner cutover.

### Slice 8 — Ollama, if still required

- Decide native chat codec versus the OpenAI-compatible Ollama endpoint from
  current protocol evidence.
- Implement only missing behavior and reuse the transport/parser.
- Prove credential-free loopback policy and parity fixtures.

Exit: current PtcRunner Ollama use is migrated without prompt flattening.

### Slice 9 — stable integration release

- Publish or tag the exact package revision.
- Pin it in PtcRunner and run the root full gate, release verification, focused
  independent review, and live supported E2E.
- Document supported/unsupported providers and the failover implication:
  native Bedrock requires another adapter or an OpenAI-compatible gateway.
- Begin ReqLLM deletion only after the companion plan's cutover criteria pass.

## Acceptance matrix

- Target and credential rejection occurs before DNS/connect.
- One call opens at most one socket and produces at most one HTTP request.
- Global/group saturation is atomic, fail-fast, and observable.
- Success, every error, timeout, cancellation, callback failure, caller death,
  and runtime-owner failure release or poison capacity exactly as specified.
- TCP and TLS `recv_up_to` satisfy prompt partial delivery and exact caps.
- Request targets and headers are injection-safe and encoded exactly once.
- Status, headers, chunk framing, trailers, SSE, body, JSON, tool arguments,
  and decoded text remain within independent caps under arbitrary
  fragmentation.
- Redirects, compression, ambiguous framing, close-delimited bodies, proxy
  environment, and transparent retries are impossible in V1.
- Text, tools, structured output, streaming, and usage match the documented
  normalized contract on supported OpenAI-compatible fixtures.
- No ordinary inspection/log/telemetry path discloses target, model, prompt,
  tool arguments, credential, header, body, or provider text.
- The package builds and its TLS trust works in a minimal release.
- Minimum and current supported Elixir/OTP jobs pass.
- PtcRunner integration contains transport mapping, not a second HTTP/parser
  implementation.
- Routine package pushes do not run PtcRunner's full gate; pinned integration
  updates do.

## Risks and stop conditions

### TLS bounded-read feasibility

This is the primary technical stop condition. Do not build a streaming parser
on an API that can either block for the requested maximum or deliver an
unbounded record.

### Scope creep into ReqLLM

Reject model catalogs, pricing inference, prompt frameworks, arbitrary
provider options, native provider protocols, retries, and failover. When a
feature request is provider-specific, prefer a separate adapter or an explicit
target capability backed by fixtures.

### Cross-repository drift

Keep the package API independent, pin exact versions, and run PtcRunner
contract tests at each checkpoint. Do not duplicate codec logic in the thin
adapter to avoid waiting for a package release.

### Security vocabulary drift

Provider messages and exceptions are not safe diagnostics by default. Add new
public error facts only when they are bounded, stable, and proven not to carry
request/endpoint/credential data.

### Performance regression from connection close

V1 deliberately trades connection reuse for exact ownership and simple bounds.
Measure DNS/TLS latency and CPU during integration. A future pool requires a
new ownership, idle-connection, per-origin, and shutdown design; performance
measurements do not authorize silently enabling Finch or keep-alive.

## Non-goals

- a drop-in ReqLLM API;
- native Bedrock, Anthropic, Google, or other provider SDK behavior;
- model discovery, model aliases, pricing, tokenization, or capability
  detection;
- credential lookup from files, environment variables, metadata services, or
  cloud identity chains;
- logical provider-task admission, per-alias call quotas, cost budgets, or
  workflow limits;
- provider failover, circuit breakers, retries, or fallback prompts;
- an incoming HTTP/MCP server;
- HTTP proxying, cookies, redirects, compression, WebSockets, HTTP/2, or HTTP/3;
- embeddings unless PtcRunner first defines a provider-neutral embedding
  contract in a separate plan; and
- supporting arbitrary custom adapter terms or arbitrary headers/options.

## Plan maintenance

At the end of every slice:

- update this plan's status and any changed decision;
- move durable public behavior into module docs and README guides;
- record verification commands and measured gate times;
- update the PtcRunner companion plan when the integration boundary changes;
- remove completed disposable spike notes once their retained contract is
  documented; and
- do not retain this plan after all approved work is complete—Git history is
  the implementation record.
