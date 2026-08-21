# PtcLlmHttp implementation plan

**Status:** active implementation plan; cross-project review incorporated
2026-08-20. Slice 0 infrastructure and the reserved public namespace landed in
`bae77e0` with follow-up CI/tooling commits through `cebdd8f`. Slice 1 passed
the socket/TLS feasibility gate: the backend is pure OTP and the trust source
is OTP's in-memory platform store. The package and its only consumer now use
Elixir 1.20 / OTP 29 as their supported baseline. Slices 2 through 5 added the
validated call contracts, fail-stop admission runtime, bounded HTTP/1 core,
and independently usable OpenAI-compatible text, tool, strict structured-
output, and synchronous text-streaming calls. Slice 6 is complete in this
package; its PtcRunner integration remains a separate pinned checkpoint.

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

It does not own model selection, client-initiated provider failover,
credentials storage, application policy, provider-task heaps, cumulative call
budgets, traces, pricing, model catalogs, or provider-native APIs.

“Provider-task heaps” above means PtcRunner's logical callback-worker policy.
The package still owns non-disableable process-heap ceilings for every process
it starts; otherwise transport and decode work would escape the caller's bound.

## Success criteria

The project is successful when:

1. its public API has no dependency on PtcRunner or ReqLLM;
2. every external byte crossing the socket is bounded before accumulation,
   including a verified TLS-handshake/certificate-chain bound or an explicit
   stop at the transport spike;
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
   Dialyzer and release work left to CI or an explicit full gate; and
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
| Physical runtime/group attempt admission using consumer-supplied ceilings | The immutable VM/group capacity configuration and alias logical admission |
| Absolute transport deadline | Run and provider deadline selection |
| DNS, TCP, TLS, HTTP/1 framing | Credential resolution and data policy |
| OpenAI-compatible and Ollama codecs | Alias routing and default selection |
| Bounded response/provider error facts | Mapping into `ProviderError` and diagnostics |
| Synchronous callback streaming with backpressure and early halt | Direct callback consumption and Kernel events |
| Provider-reported usage fields | Usage budgets, accounting, and traces |
| No client-initiated retry or failover; declared upstream-routing wire controls | Explicit workflow/operator failover policy and gateway data-policy acceptance |

No package module imports or returns a `PtcRunner.*` type. The PtcRunner
adapter is intentionally thin and remains in PtcRunner.

## Decisions fixed for V1

- Application and package name: `:ptc_llm_http`; top-level namespace:
  `PtcLlmHttp`.
- License: MIT, matching PtcRunner, as landed in the bootstrap.
- Versioning: 0.x with breaking changes allowed. PtcRunner may pin an exact tag
  or Git commit during pre-release integration and never follows a moving
  branch. Its published production package requires a published Hex version of
  `ptc_llm_http`.
- The package and its only consumer share one supported baseline: Elixir
  `~> 1.20` and Erlang/OTP 29 or later, enforced in `mix.exs`. The transport
  spike's OTP 26/27 measurements remain retained evidence, not a compatibility
  promise. CI runs the supported toolchain on Linux and macOS.
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
- Client-initiated provider failover is never automatic here. A new package
  call against another target is a new PtcRunner logical call with its own
  authority, capacity, call-budget, usage, and trace record. A gateway may
  route among upstream providers inside the one request; the target declares
  that behavior as opaque unless a codec-backed single-provider control is
  encoded and fixture-tested.
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
  ptc_llm_http/runtime/root.ex
  ptc_llm_http/runtime/guardian.ex
  ptc_llm_http/runtime/generation.ex
  ptc_llm_http/runtime/generation_supervisor.ex
  ptc_llm_http/runtime/admission.ex
  ptc_llm_http/runtime/attempt_supervisor.ex
  ptc_llm_http/runtime/attempt_tree.ex
  ptc_llm_http/runtime/coordinator.ex
  ptc_llm_http/runtime/role.ex
  ptc_llm_http/runtime/attempt_relay.ex
  ptc_llm_http/target.ex
  ptc_llm_http/connect_policy.ex
  ptc_llm_http/credential.ex
  ptc_llm_http/limits.ex
  ptc_llm_http/process_budget.ex
  ptc_llm_http/resource_contract.ex
  ptc_llm_http/request.ex
  ptc_llm_http/response.ex
  ptc_llm_http/stream_complete.ex
  ptc_llm_http/stream_halt.ex
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
    max_concurrency: 8,
    groups: %{"openrouter-account" => 4}
  )

true = PtcLlmHttp.Runtime.ready?(runtime)

{:ok, %{in_use: 0, limit: 8, groups: groups}} =
  PtcLlmHttp.Runtime.snapshot(runtime)
```

The package exposes one data-only `PtcLlmHttp.ResourceContract.current/0`
projection containing the resource-contract version, inclusive process-budget
minimum/maximum, the hostname-lookup aggregate, process-partition version, and
runtime-control formula version. It exposes no role names, percentages, process
IDs, or mutable counters. A pinned consumer uses this projection at
build/integration validation instead of copying the numeric range as an
independent source of truth; the detailed internal catalog remains
package-owned.

The public runtime handle names a `:rest_for_one` `RuntimeRoot` with this exact
child order: a permanent `RuntimeGuardian`, then a permanent
`GenerationSupervisor`. The guardian owns the opaque current generation,
registered attempt/role monitors, terminal-cause facts, and the bounded teardown
protocol. `GenerationSupervisor` has at most one temporary outer-generation
child. That child is a fail-stop `:one_for_all` boundary containing one
generation admission owner and one attempt supervisor, both `restart:
:transient`, with restart intensity zero. The boundary owns only physical
HTTP-attempt admission and backend supervision. It does not own credentials,
model aliases, logical provider tasks, or retry policy.

Required behavior:

- `max_concurrency` is a runtime-wide ceiling in `1..1_024` and the runtime has
  at most 256 configured groups;
- every target names one configured group and its group ceiling narrows the
  global ceiling;
- global and group reservations are atomic;
- admission is non-blocking and occurs immediately before DNS/connect;
- every admitted attempt is one fail-stop supervised ownership subtree below
  the attempt supervisor;
- before any target/request/credential is delivered, every attempt tree and its
  fixed role PIDs are atomically registered with the surviving guardian;
- the guardian monitors the registered tree/roles and authorizes the admission
  owner to release a lease only after that whole subtree is `DOWN`;
- normal cleanup is idempotent and exactly once;
- runtime-owner death poisons or stops the runtime rather than silently
  resetting capacity under surviving calls; and
- readiness and bounded counter snapshots are available without exposing
  target, endpoint, model, or credential data.

Shared runtime control memory is bounded separately from each attempt envelope.
The internal catalog grants one aggregate control heap of
`160_000 + 2_560 * max_concurrency + 512 * group_count` words. Its versioned
partition covers every long-lived package control process: 10% runtime root,
25% guardian, 10% generation supervisor, 10% outer-generation supervisor, 30%
admission state, and 15% attempt-supervisor state. At most one process occupies
each role, so the shares sum rather than multiply; integer remainder goes to the
guardian. Each process sets its derived heap flag at startup.
The guardian and admission slots retain only counters, monitor refs, closed
phase/cause atoms, delivery acknowledgements, and opaque bootstrap IDs;
target/request/credential/result values never enter shared control state.
Exceeding any control-process heap bound poisons the runtime generation rather
than resetting counters. This bounded runtime overhead is reported independently
from per-call process budgets and included in PtcRunner's host memory
calculation.

The package intentionally permits independent runtimes for independent
consumers; it does not claim to discover or enforce a VM singleton. PtcRunner
constructs exactly one runtime generation from its immutable host
`llm_capacity` configuration and passes the same global/group values to its
logical owner. PtcRunner exposes no separately configurable physical ceiling.
Starting a second package runtime creates an independent capacity domain and is
not a way to join or extend the first.

Generation failure is fail-stop, but teardown authority does not die with its
admission owner. Before an attempt may receive private payload or connect, its
tree and every fixed role complete a guardian registration handshake. On
admission-owner, attempt-supervisor, or outer-generation failure, the surviving
guardian immediately fences that generation, records `runtime_shutdown`, and
starts one generation-wide cleanup cutoff. It signals every registered tree
concurrently, brutally kills survivors at 900 milliseconds, and spends the
remaining 100 milliseconds consuming their `DOWN` messages. It never releases
the dead generation's counters in place. Only after all registered old-generation
trees/roles and the outer generation are `DOWN` may it explicitly start and
publish a replacement with a new identity; otherwise the runtime remains
poisoned and returns `runtime_unavailable`.

If the guardian itself dies, `RuntimeRoot`'s `:rest_for_one` ordering terminates
the later `GenerationSupervisor` before either child restarts. The generation
child specification has the same single 1,000-millisecond aggregate shutdown
cutoff and brutal-kill fallback, and no package process may detach from that
supervision tree. `RuntimeRoot` observes the old generation supervisor `DOWN`
before starting the replacement guardian, so loss of the old monitor registry
cannot publish capacity over surviving descendants. A stale owner or generation
identity cannot admit or release against the replacement. Tests cover guardian,
admission-owner, attempt-supervisor, and outer-generation death before and after
DNS, connect, partial send, blocked callback, result handoff, and partial
receive.

For V1, one admitted attempt equals at most one live outbound connection. If a
future version retains idle sockets or multiplexes HTTP/2 streams, it must add
separately named connection, stream, and request limits instead of changing the
meaning of `max_concurrency`.

### Target

```elixir
{:ok, target} =
  PtcLlmHttp.Target.new(
    kind: :openai_compat,
    base_url: "https://openrouter.ai/api/v1",
    model: "deepseek/deepseek-v4-flash",
    capacity_group: "openrouter-account",
    connect_policy: :public,
    max_encoded_request_bytes: 1_000_000,
    max_wire_response_bytes: 1_000_000,
    tools: true,
    streaming: true,
    structured_output: :json_schema,
    cache_mode: :unsupported,
    upstream_routing: :opaque,
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
- an HTTPS target uses a DNS hostname; V1 rejects HTTPS IP literals rather than
  implement a separate no-SNI/IP-address-SAN verification path;
- bounded model and capacity-group identifiers;
- one closed connect-address policy compiled into the target;
- exact capability modes, upstream-routing guarantee, and usage guarantees;
- one closed codec/error-contract version used for provider-code recognition;
- positive encoded-request and wire-response byte ceilings within package
  maxima; and
- fully redacted `Inspect`, no `Enumerable`, and no JSON encoder.

The target contains no resolved credential bytes. It may retain private
endpoint/model configuration internally, but no error or metadata projection
returns them.

#### Connect-address authority

V1 connect policy is either `:public`, `:literal_loopback`, or
`{:allow_cidrs, cidrs}`. `:public` admits only globally routable unicast IPv4 or
IPv6 addresses. It rejects unspecified, loopback, RFC1918/ULA, carrier-grade
NAT, link-local, multicast, documentation/benchmark/reserved ranges,
IPv4-mapped bypass forms, and platform metadata-service ranges. The exact IANA
special-purpose tables and update date are retained protocol evidence, not
implicit library behavior. `:literal_loopback` is valid only for a
credential-free literal loopback HTTP target. `allow_cidrs` is an explicit
bounded list of canonical CIDRs and is the only way to authorize an internal
HTTPS service; there is no `:any` policy.

The target constructor validates literal hosts against the policy. For a DNS
host, the cancellable resolver returns at most the catalog limit and every
returned address must satisfy the compiled policy; a mixed allowed/disallowed
answer is rejected rather than filtered. The attempt deterministically selects
one approved address, pins that exact address for its single connect, and does
not resolve again. For HTTPS, HTTP `Host`, TLS SNI, and certificate hostname
verification continue to use the original validated DNS hostname. The only V1
literal-host path is credential-free loopback HTTP. Tests cover DNS rebinding,
mixed answers, IPv4-mapped IPv6, metadata/link-local destinations, HTTPS IP-
literal rejection, policy CIDR edges, and a resolver answer changed after
selection.

### Credential

```elixir
{:ok, credential} = PtcLlmHttp.Credential.bearer(secret_bytes)

credential_free = PtcLlmHttp.Credential.none()
```

V1 supports `:none` and bearer authorization. The value is opaque, has redacted
`Inspect`, validates the final header-value grammar before any connection, and
is at most the bearer-byte maximum in the limit catalog. It is not stored in the
runtime or target and exists only for the duration of one call. The BEAM cannot
guarantee memory zeroization; the contract minimizes copies and lifetime
instead of claiming it.

PtcRunner's longer-lived installation/capability closure must therefore hold an
opaque credential-vault lease rather than secret bytes. Its run-owned vault may
retain the one phase-8 resolution for the run, but each invocation retrieves a
bounded value through the lease, constructs this package credential, and drops
the call-local value after cleanup. That consumer refactor is a prerequisite to
integration; the package never accepts the vault or performs credential lookup.

Arbitrary authorization headers are not accepted. Non-secret static target
headers may be added only if a real endpoint requires them; their constructor
must reject reserved names including authorization, proxy-authorization, host,
connection, content-length, content-type, transfer-encoding, and cookies.

### Request

The Slice 4 text surface is exact:

```elixir
{:ok, request} =
  PtcLlmHttp.Request.new(
    system: "Answer briefly.",
    messages: [
      %{role: :user, content: "Hello"},
      %{role: :assistant, content: "Hi"},
      %{role: :user, content: "Continue"}
    ],
    max_tokens: 512,
    temperature: 0.2,
    seed: 7,
    cache: false
  )
```

Only `messages` is required. The other keys default to `nil`, except `cache`,
which defaults to `false`. Unknown or duplicate keys are rejected. Slice 4
accepts nonempty UTF-8 `system`, `user`, and `assistant` text only; tool
definitions, assistant tool calls, tool results, and structured-output keys are
added with their complete validation contract in Slice 5 rather than accepted
early in a partially checked form.

`max_tokens` is a positive integer and `seed` is a signed integer; both are
bounded to the signed 64-bit range before encoding. Temperature is numeric in
the closed interval from zero through two. These local numeric ceilings keep
JSON sizing bounded independently of provider behavior.

The completed request constructor through Slice 5 adds this exact surface:

```elixir
{:ok, request} =
  PtcLlmHttp.Request.new(
    messages: [
      %{role: :user, content: "Use the tool"},
      %{
        role: :assistant,
        content: nil,
        tool_calls: [%{id: "call_1", name: "weather", args: %{"city" => "Stockholm"}}]
      },
      %{role: :tool, tool_call_id: "call_1", content: "12 C"}
    ],
    tools: [
      %{
        name: "weather",
        description: "Look up weather",
        parameters: %{
          "type" => "object",
          "properties" => %{"city" => %{"type" => "string"}},
          "required" => ["city"],
          "additionalProperties" => false
        }
      }
    ],
    response_schema: %{
      name: "weather_result",
      schema: %{
        "type" => "object",
        "properties" => %{"summary" => %{"type" => "string"}},
        "required" => ["summary"],
        "additionalProperties" => false
      }
    }
  )
```

`tools` defaults to `[]` and `response_schema` defaults to `nil`.
`response_schema: :json_object` selects the older JSON-object mode only when
the target declares that mode. A schema map selects strict JSON Schema mode.
Together with the Slice 4 fields, the constructor represents a
provider-neutral request containing:

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

The package can represent a request without `max_tokens`, because it does not
own product policy. The PtcRunner integration must never do so: it supplies an
installed positive ceiling or its retained 4,096-token default before calling
this constructor. Exact request fixtures prove the explicit field reaches every
supported codec. A wire-response byte cap is not treated as a generation or
cost limit.

### Call and streaming

```elixir
{:ok, process_budget} =
  PtcLlmHttp.ProcessBudget.new(
    total_heap_words: 4_000_000
  )

{:ok, absolute_deadline} =
  PtcLlmHttp.Deadline.new(System.monotonic_time(:millisecond) + 30_000)

{:ok, response} =
  PtcLlmHttp.call(runtime, target, request,
    credential: credential,
    deadline: absolute_deadline,
    process_budget: process_budget
  )

{:ok, completion} =
  PtcLlmHttp.stream(runtime, target, request, on_chunk,
    credential: credential,
    deadline: absolute_deadline,
    process_budget: process_budget
  )
```

There is no call without a runtime and no relative timeout in the low-level
API. The consumer computes one absolute monotonic deadline. Every phase reads
the remaining time from it; no phase resets the budget.

`process_budget` is required. Its closed public constructor accepts only one
aggregate `total_heap_words` value in the versioned inclusive package range
`100_000..2_073_600_000`. Both endpoints are durable package contract data, not
consumer assumptions. Hostname targets that use the system resolver and, for
HTTPS, the platform trust store need at least the published hostname aggregate
of `4_000_000` words; smaller legal aggregates remain valid for IP-literal
targets and injected-resolver tests. The package—not its consumers—versions
and derives every internal role ceiling. Callers cannot name package roles,
control their ratios, or disable the bound. A future range or partition change
requires a new resource-contract version and an explicit consumer integration
checkpoint.

`PtcLlmHttp.Deadline` is an opaque millisecond-based value constructed from an
absolute `System.monotonic_time(:millisecond)` deadline. Public APIs do not mix
native units, wall-clock timestamps, and durations. Numeric phase durations in
metadata are integer milliseconds.

`stream/5` delivers one chunk at a time through a monitored callback worker and
does not read the next socket bytes until that worker answers, so delivery is
synchronous and backpressured without blocking the attempt's deadline owner.
The callback returns `:cont` or `:halt`; any other return is callback misuse. A
slow or stuck callback still consumes the same total deadline: the attempt
coordinator remains able to stop the attempt tree when the deadline expires.
That tree kills the callback worker, closes the socket helper, and reaches
`DOWN` before admission is released or callback raise/throw/exit is reported to
the caller.

Neither repository builds an `Enumerable` bridge or producer mailbox.

The closed public return unions are distinct:

```elixir
PtcLlmHttp.call(...) ::
  {:ok, %PtcLlmHttp.Response{}} | {:error, %PtcLlmHttp.Error{}}

PtcLlmHttp.stream(...) ::
  {:ok, %PtcLlmHttp.StreamComplete{}}
  | {:halted, %PtcLlmHttp.StreamHalt{reason: :consumer_halted}}
  | {:error, %PtcLlmHttp.Error{}}
```

Once an attempt tree exists, every value-bearing member of these unions—not
only `%Response{}`—uses the caller-retained terminal handoff defined in the
resource section. That includes `%StreamComplete{}`, `%StreamHalt{}`, and every
classified `%Error{}` with its exact bounded status/code/scope/dispatch facts.
Validation, target, credential, deadline, runtime, or capacity errors returned
before an attempt is registered have no tree to drain and return directly.

`StreamHalt` contains only delivered decoded-byte/chunk counts, bounded
transport metadata, and usage already observed before the halt; it never
reconstructs partial content. `usage_complete?` is always `false`, and absent
terminal usage stays absent. Because the consumer deliberately prevented the
terminal event, `usage_guarantees` are not evaluated as a provider-protocol
failure for this outcome. The attempt is nevertheless dispatched and the
consumer's logical call remains charged. PtcRunner's adapter immediately maps
the package struct into its own provider-neutral tagged halt value. Its
run-backed `RunState` or bound direct-accounting owner charges any reported
usage and records a host accounting failure (not a `ProviderError`) when an
installed token/cost ceiling required authoritative terminal usage; an ambient
direct call without one of those owners is not retained.

### Response, stream completion/chunks, and usage

A successful non-stream `%Response{}` contains only normalized data:

- content string, which may be empty;
- zero or more normalized redacted `%PtcLlmHttp.ToolCall{}` values whose
  explicit `id/1`, `name/1`, and `arguments/1` accessors return the bounded
  provider ID, declared name, and decoded argument object;
- provider-reported usage fields; and
- bounded numeric transport metadata such as status, encoded request bytes,
  response bytes, and phase durations.

Response, tool-call, usage, and stream-chunk values are opaque or have redacted
`Inspect` implementations and no automatic JSON encoder. Content and argument
access is explicit because those values may be private even after successful
normalization.

For non-streaming calls, the explicit accessors are `Response.content/1`,
`Response.tool_calls/1`, `Response.usage/1`, `Response.metadata/1`, the three
`ToolCall` accessors above, and `Usage.facts/1`. Metadata contains only status,
encoded JSON request bytes, identity response-body bytes, informational-response
count, and trailer-field count. It contains no endpoint, model, headers, prompt,
output, provider message, or raw error data.

The package never calculates price. A cost value is present only when the
response reports it and the codec has an exact documented field mapping.
Missing optional usage remains absent rather than becoming zero. Missing usage
promised by `usage_guarantees` is an invalid-provider-response error.

Text stream chunks are `%{delta: binary()}`. `%StreamComplete{}` carries only
complete normalized usage, delivered decoded-byte/chunk counts, and bounded
transport metadata; it has no `content` field. The package never accumulates the
full generated text. A consumer that needs full content owns a separately
bounded accumulator, while cumulative package wire and decoded-text caps still
apply before every callback.

The completed public accessors are `StreamComplete.usage/1`,
`StreamComplete.delivered/1`, `StreamComplete.metadata/1`,
`StreamHalt.reason/1`, `StreamHalt.usage/1`,
`StreamHalt.usage_complete?/1`, `StreamHalt.delivered/1`, and
`StreamHalt.metadata/1`. `delivered/1` returns only `%{bytes:, chunks:}`. Both
terminal structs have redacted inspection and no `Enumerable` or JSON encoder.

### Error

All expected target, capacity, transport, HTTP, protocol, and provider-response
failures return `%PtcLlmHttp.Error{}`. The closed initial `kind` enum is:

```elixir
:invalid_target | :invalid_request | :invalid_credential |
:unsupported_capability | :capacity_exhausted | :runtime_unavailable |
:deadline_exceeded | :resource_limit_exceeded | :callback_failed |
:internal_failure | :dns_failure |
:address_rejected | :connect_failure |
:tls_failure | :connection_closed | :malformed_http | :response_too_large |
:unsupported_redirect | :unsupported_content_encoding |
:unsupported_transfer_encoding | :unsupported_framing | :http_status |
:malformed_provider_response | :provider_result_too_large | :model_refusal |
:malformed_stream | :stream_too_large | :invalid_tool_arguments
```

The closed `phase` enum is `:validate | :encode | :admission | :dns |
:connect | :tls | :send | :receive_head | :receive_body | :stream |
:decode`. Kinds that cannot occur in a phase are rejected by the error
constructor. `scope` is also closed:
`:request | :credential | :capacity | :transport | :provider | :model`.
Provider error codes exposed publicly are atoms from a closed, codec/version-
specific enum or `nil`; unknown raw codes are discarded and take the default
status mapping. No arbitrary string or open-ended scope crosses the boundary.

Slice 2 published the non-wire entries as `error-base-v1`; Slice 4 completed
the initial HTTP/OpenAI-compatible entries as `error-openai-v1`. Slice 5 adds
the model-scoped structured-output refusal entry as `error-openai-v2`.
`PtcLlmHttp.Error.contract/0` returns that version plus a bounded sorted list of
disjoint contract entries. Each entry has a stable ID and enumerates its exact
kind, allowed phases, HTTP status list/ranges, provider-code atoms, scopes, and
dispatch states. It also returns the full kind/phase/scope/code enums. Every
constructible error matches exactly one entry. Adding or changing any enum,
status partition, provider-specific refinement, or entry is a versioned cross-
repository contract change and must update PtcRunner's generated exhaustive
mapping test in the same integration checkpoint.

The first documented provider-code enum contains
`:credit_balance_exhausted`, `:organization_spend_limit_exceeded`,
`:organization_usage_limit_exceeded`, and `:project_spend_limit_exceeded`.
Unknown strings and provider error text are discarded; status-only
classification remains available.

The error carries stable facts, not a retry/failover decision: kind, phase,
optional HTTP status, optional closed provider error code, one required closed
scope, and dispatch state
`:not_sent | :possibly_sent | :completed`. `:not_sent` is used only when the
wire proves request bytes could not reach the peer; ambiguity after send begins
is `:possibly_sent`. PtcRunner decides retryability, `ProviderError` provenance,
quota policy, and failover from this closed evidence.

Those instance facts are read through `Error.facts/1`, matching the explicit
accessor pattern used by `Usage.facts/1`. The returned map is exactly
`%{kind:, phase:, scope:, dispatch:, http_status:, provider_code:}` and never
includes provider text, request or response bodies, endpoint, model, headers,
credential material, or a raw cause. `t` remains opaque; consumers must not
read struct keys. `contract/0` remains the versioned enumeration of
constructible combinations; `facts/1` is the instance projection of one
validated error.

`Inspect` is redacted. Public safe details are fixed package vocabulary. V1
discards provider error text before constructing the result and returns only
status, a bounded documented provider code, scope, phase, and dispatch state.
There is no private-evidence capsule or alternate error tuple, so the closed
return union above is complete. PtcRunner private inspection may record those
same safe facts with its own trace correlation, but it never receives raw
provider text, headers, request/response bodies, endpoint, model, or credential.

## Initial limit catalog

Slice 2 creates one internal catalog before any constructor is usable; later
slices add parser/codec caps to that same owner. The target-narrowable subset is
exposed through constructors. These are the starting V1 values; a
different value must be justified and changed before dependent fixtures are
approved.

| Limit | Initial hard maximum |
| --- | ---: |
| Base URL / origin-form target | 8,192 bytes |
| Model identifier | 256 bytes |
| Capacity-group identifier | 128 bytes |
| Runtime concurrency / configured groups | 1,024 / 256 |
| Shared runtime-control heap | `160,000 + 2,560 × concurrency + 512 × groups` BEAM heap words |
| Internal runtime-control partition | root 10%, guardian 25%, generation supervisor 10%, outer generation 10%, admission 30%, attempt supervisor 15% |
| Bearer credential bytes | 16,376 bytes |
| Encoded request body (`max_encoded_request_bytes`) | 1,048,576 bytes |
| Request header name / value | 128 / 16,384 bytes |
| Total request header fields | 64 |
| Aggregate encoded request head | 65,536 bytes |
| Identity wire response payload (`max_wire_response_bytes`) | 1,048,576 bytes |
| Status/header line | 16,384 bytes |
| Aggregate response head | 65,536 bytes |
| Response header fields | 128 |
| Informational responses | 8 |
| Chunk-size line including extensions | 1,024 bytes |
| Aggregate trailers / trailer fields | 16,384 bytes / 64 |
| Socket read quantum | 16,384 bytes |
| SSE event / event count | 262,144 bytes / 10,000 |
| Cumulative decoded stream text | 262,144 bytes |
| Messages / declared tools / returned tool calls | 1,024 / 128 / 128 |
| Tool name / tool-call ID | 64 / 256 bytes |
| Tool description / one and cumulative returned argument JSON | 16,384 / 262,144 bytes |
| Structured-output name / schema property name / enum values | 64 bytes / 128 bytes / 128 per enum |
| Aggregate schema properties / nesting / strings / enum values | 5,000 / 10 / 120,000 characters / 1,000 |
| JSON nesting / visited containers and scalar values | 64 / 100,000 |
| DNS addresses retained from one resolution | 8 |
| Explicit connect-policy CIDRs | 32 |
| Non-secret static target headers | 32 |
| Aggregate package process budget per attempt | 100,000–2,073,600,000 BEAM heap words |
| Hostname-lookup aggregate | 4,000,000 BEAM heap words |
| Internal process-partition version | `process-v2` |
| Attempt-tree supervisor role | 5% of aggregate heap words |
| Coordinator role | 5% of aggregate heap words |
| Sequential encode/decode role | 40% of aggregate heap words |
| Callback role | 15% of aggregate heap words |
| DNS role | 5% of aggregate heap words, and at least 2,000,000 words once the aggregate is at least the hostname budget |
| Socket/TLS role | 20% of aggregate heap words |
| Result/cause relay role | 10% of aggregate heap words |
| Aggregate attempt cleanup cutoff | 1,000 milliseconds |

When the DNS floor binds, the non-DNS roles keep those relative weights of
`(aggregate − 2,000,000)` rather than of the full aggregate. Codec still
receives the integer remainder of that leftover.

Per-target request/response caps may only narrow the hard maximum. Individual
prompt, content, schema, tool, argument, and error fields also need caps so one
field cannot consume an aggregate through an implementation accident. JSON is
validated after decode for depth, node count, expected object shape, and
bounded strings. These post-decode checks are semantic bounds, not protection
against allocation during decode.

`process-v2` is package-owned and sums to exactly 100%. Integer rounding assigns
the remainder to the codec role. From the hostname aggregate of 4,000,000 words
upward, the DNS role receives `max(5%, 2,000,000)` words so a cold system
`getaddrs` plus platform `cacerts_get` survives on the supported OTP/OS matrix;
the other roles keep their relative weights inside the leftover. That floor is
the intended memory/security tradeoff: extra DNS room is taken from the other
attempt roles rather than by multiplying every ceiling tenfold. At 1,024-way
concurrency the hostname aggregate therefore exposes at most 4,096,000,000
attempt-heap words plus the separate runtime-control heap. Below the hostname
aggregate the original percentages remain, which is enough for IP-literal and
injected-resolver calls and too small for a cold HTTPS hostname attempt.

At most one process in each role may be live; encode and decode reuse the
sequential codec role. Every package-owned attempt supervisor, coordinator,
encode/decode, callback, DNS, socket/TLS, and result/cause relay process sets
`max_heap_size` with `kill: true` and `error_logger: false` before external data
or caller code. The partition sum and one-live-process-per-role invariant make
the total possible per-attempt package heap no greater than the caller's
aggregate. Independently applying the aggregate to several processes is
forbidden. Changing roles or percentages is a versioned package resource-
contract change; PtcRunner depends only on aggregate semantics and rejects an
unknown partition version at an integration checkpoint.

Each admitted attempt is a temporary fail-stop `AttemptTree` supervisor with a
coordinator and its role children. The tree is `restart: :temporary` below the
attempt supervisor; its role children are `restart: :transient` under
`:one_for_all` with restart intensity zero. Unexpected normal role exit is
normalized to abnormal. No response, tool argument, content chunk, terminal
error fact set, or provider payload crosses the guardian or admission owner.
Every value-bearing terminal outcome after tree registration uses one two-phase
handoff. The result/cause relay constructs the already bounded `%Response{}`,
`%StreamComplete{}`, `%StreamHalt{}`, or `%Error{}` candidate and sends it
directly to the authorized calling process under a one-time delivery reference.
The caller retains it in its own bounded process and acknowledges only that
reference. The relay then reports only the opaque reference and closed precedence
category to the guardian. The caller returns nothing until the guardian has
stopped the whole attempt tree and observed every registered `DOWN`. For a live
generation the guardian must then obtain the admission owner's atomic lease-
release acknowledgement before sending an opaque terminal decision. If that
owner is dead, `runtime_shutdown` wins, its counters are fenced rather than
released for reuse, and the guardian may send only the discard/replacement
decision after teardown.

If the candidate's category wins final arbitration, the guardian commits its
delivery reference and the caller returns the exact retained value. If a higher-
precedence cause wins, the guardian sends only `discard` plus the winning closed
kind/phase/dispatch atoms; the caller discards the candidate and constructs the
corresponding bounded replacement outcome. Exact HTTP status, provider code,
scope, usage, counts, and metadata are never reconstructed: a classified
candidate containing those facts either commits unchanged or is discarded.
If caller, guardian, admission owner, or generation dies before commit, the
uncommitted candidate is discarded and its value is not published. Thus the
relay may die with the tree without losing a committed terminal value, and no
role independently exits and leaves siblings alive. Supervisor child
specifications retain only an
opaque attempt ID, generation, aggregate budget, and one-time bootstrap key;
the caller sends target/request/credential payload directly to the coordinator
after startup, so no supervisor or child specification retains those values.
The socket is owned by the socket/TLS child, so coordinator, caller, or helper
death cannot leave a live socket outside the tree. The guardian monitors the
tree and each fixed role for bounded cause/lifecycle facts. The admission owner
changes counters only on the guardian's opaque release command and never releases
capacity until every role and the tree supervisor are `DOWN`.

The surviving guardian is the single atomic terminal-outcome and cleanup owner.
Its bounded ledger contains the opaque attempt/role monitor refs, current closed
phase, dispatch state, delivery reference/acknowledgement, closed candidate
category, and a set of closed cause atoms only. It never contains the candidate
value or any of its exact status/code/scope/usage/metadata facts. External
initiators record their cause before stopping the tree; a role
returning a classified error or callback misuse sends the atom and waits for
guardian acknowledgement; an
uninitiated `:killed` role `DOWN` means `:resource_limit`; another abnormal
callback-role death discards its raw reason and means `:callback_misuse`; any
other unexplained role death means `:internal_failure`. Admission-owner or
generation death records `runtime_shutdown` before the guardian begins fallback
teardown. A delivered candidate records its category before planned tree stop;
monitor `DOWN`s caused by a recorded planned stop do not manufacture an error.
Once all registered role monitors and the tree are `DOWN`, the guardian freezes
one outcome using this precedence:
`runtime_shutdown`, `caller_cancelled`, `deadline_exceeded`, `consumer_halted`,
`callback_misuse`, `resource_limit`, classified
transport/HTTP/protocol/provider cause, then
`internal_failure`, then acknowledged `success`. `consumer_halted` represents a
delivered `StreamHalt`, a classified package cause represents a delivered
`%Error{}`, and success represents a delivered `%Response{}` or
`%StreamComplete{}`. Thus a higher-precedence event racing any candidate handoff
wins, and simultaneous deadline/heap/caller-death races have one deterministic
result rather than mailbox-order classification.

The frozen outcome has one closed public projection: an acknowledged candidate
whose category wins receives the opaque commit that lets the caller return its
retained terminal value; runtime
shutdown returns `runtime_unavailable`; a dead/cancelled caller receives no
reply; deadline
returns `deadline_exceeded`; consumer halt returns `StreamHalt`; callback misuse
returns `callback_failed`; heap death returns `resource_limit_exceeded`;
classified package causes retain their committed contract entry; and an
unexplained death returns `internal_failure`. No raw exit or callback reason
crosses the boundary.

Cleanup has one package-hard 1,000-millisecond cutoff anchored when the first
terminal outcome/cause is recorded; it is separate from and never extends the operation
deadline. The guardian signals all registered roles concurrently, permits at most
900 milliseconds of cooperative cleanup, then brutally kills every survivor and
uses the final fixed 100 milliseconds only to consume their monitor `DOWN`
messages. It never grants a timeout per child. If any registered role/tree has
not reported `DOWN` at the total cutoff, the physical runtime is poisoned and
its generation is terminated; its admission counters are never released for
reuse in place. Tests force every role over its heap bound before/after send,
hold every cleanup callback, and race deadline/heap/caller/admission-owner death.
They prove the selected cause and either complete tree `DOWN`, opaque result
commit, and capacity release in that order or fail-stop runtime teardown at the
one cutoff. The TLS spike
separately remains responsible for native/off-heap handshake and certificate
allocations that BEAM process heap limits do not bound.

Cap-plus-one reads are allowed only to prove overflow and the extra byte is not
retained in a result. Limit names and units appear in error facts and module
documentation; unnamed literals in parser/codec code are forbidden.

These limits measure serialized/wire bytes only. PtcRunner separately enforces
retained BEAM-term request/result limits before and after the package call; the
integration must not reuse one field name for both units.

## Deadline, cancellation, and ownership

One supervised `AttemptTree` owns one transport attempt and one capacity lease.
The ownership chain is the stable runtime guardian → fail-stop outer generation
with admission owner plus sibling attempt supervisor → per-attempt fail-stop tree
→ coordinator plus supervised callback/DNS/socket/codec roles. The coordinator,
never callback code, owns the authoritative operation-deadline timer; the
guardian owns terminal cause and aggregate cleanup, while the tree owns reverse
death propagation. Required properties:

- expiration is checked before encoding, admission, DNS, connect, TLS, send,
  every receive, every callback, and final decode;
- admission is fail-fast, so it does not add a hidden queue timeout;
- DNS runs in a monitored cancellable worker because system resolution may
  block;
- DNS returns a bounded address count; the call makes one connect attempt to
  one policy-approved pinned address in V1, not a hidden sequence of retries;
- caller death closes the socket/helper and guardian monitoring authorizes slot
  release only after full teardown;
- explicit cancellation uses process ownership, not a mutable global flag;
- normal completion closes the connection before releasing capacity;
- early stream halt, callback failure, malformed input, provider failure, and
  every exception path have deterministic cleanup;
- a callback that never returns is killed at the absolute deadline while the
  independently owned socket is closed; and
- tests use monitors and controlled fixtures, never sleeps.

The attempt coordinator monitors the calling process. Once it receives the opaque
call-local credential, package cleanup no longer depends on caller code: caller
`DOWN` stops the attempt tree, closing the socket and dropping every credential/
authorization-buffer copy with its owning child before physical lease release.
Credentials are never copied into the runtime/admission owner. Tests kill the
caller before admission, during encode/TLS/send/receive, and in a blocked
callback and prove every tree child `DOWN` before capacity release. This is a
bounded-lifetime/no-retention contract, not a BEAM zeroization claim.

Address selection must be deterministic and documented. If dual-stack
fallback is desired later, it is multiple attempts and requires an explicit
attempt budget; it is not smuggled into DNS/connect behavior.

## Transport spike: passed

The backend contract is settled and its record lives in
`docs/transport-backend.md`: pure OTP `:gen_tcp` and `:ssl` in passive mode,
with `recv_up_to/3` built from a capped `recv(socket, 0, timeout)` rather than
an exact-size or uncapped read, and no port helper. The conformance suite in
`test/ptc_llm_http/transport/` runs the whole spike matrix against scripted
local TCP and TLS peers on every commit, and on Linux, macOS, and the minimum
OTP in CI.

The stop condition it existed to test — an API that can only block for the
requested maximum or deliver an unbounded record — did not fire. Handshake
input is bounded by `max_handshake_size` and `depth`; application data by the
pinned `buffer` and passive-mode flow control.

## TLS and trust

HTTPS requires:

- certificate-chain and hostname verification;
- a DNS hostname, with SNI and certificate verification using that original
  validated name; HTTPS IP literals are rejected in V1;
- ALPN restricted to `http/1.1`;
- no insecure verification option;
- no credential-bearing plaintext fallback;
- a documented packaged trust source that works in a standalone release; and
- no secret-bearing debug logging from `:ssl` options or errors.

The trust source is settled: `:public_key.cacerts_get/0`, the platform store
OTP holds in memory. No CA bundle is packaged and no CA dependency is added; a
host without usable trust material fails the connection with a typed
`:no_trust_store` rather than falling back. The release smoke proves it is
reachable inside an assembled release. Callers may pass their own DER
authorities; target-specific custom CAs are deferred until a real deployment
needs them, and will require an explicit opaque trust input rather than an
ambient environment lookup.

The system-store lookup runs in the registered bounded DNS role before the
socket role begins. It creates no package helper process, so deadline and caller
cancellation tear it down with the attempt tree before capacity is released.

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
- target-declared cache translation and upstream-routing control.

Unknown arbitrary provider parameters are not accepted in V1. Add a closed
option only with a provider fixture and a PtcRunner installation need.

### Upstream routing

The package guarantees one client request, not one gateway-internal provider
attempt. Every gateway target declares `upstream_routing: :opaque` unless its
codec has a closed, documented, fixture-backed single-provider control. For
OpenRouter, disabling provider fallbacks may be added as such a target
capability only after exact request fixtures prove the supported wire shape.
The package never infers a routing guarantee from the model identifier.

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
the declared mode. Prompt-and-parse is not a fallback. V1 admits a documented
closed JSON Schema dialect rather than accepting arbitrary keywords it cannot
enforce. The codec validates the supplied schema before admission, boundedly
decodes successful structured content, requires an object, and validates that
object against the exact admitted schema. Unsupported schema keywords and
response mismatches are closed errors. The normalized response retains
canonical JSON text for compatibility, but that text is produced only from the
already bounded and validated object; the PtcRunner adapter does not parse raw
provider JSON or perform a second schema interpretation.

The V1 admitted dialect is a strict subset of JSON Schema Draft 2020-12. Every
schema node requires one string `type`. Supported types are `object`, `array`,
`string`, `number`, `integer`, `boolean`, and `null`; supported optional
keywords are `description` and a bounded scalar `enum`. Objects require
`properties`, require every declared property exactly once through `required`,
and require `additionalProperties: false`. Arrays require one `items` schema.
All other keywords, boolean schemas, union types, references, composition,
formats, patterns, cardinality constraints, and tuple arrays are rejected
before admission. Tool parameters and structured output use this same dialect.
Structured output requires an object root. Returned values are checked against
the exact normalized schema, including recursively rejecting missing or
additional object members.

### Cache policy

Cache translation is closed and target-declared. Start with `:unsupported`.
Add an OpenAI-compatible ephemeral-content mode only after a local fixture
proves exact request bytes for a supported endpoint. `cache: true` against an
unsupported target fails before connection; it is never silently ignored.
Before PtcRunner cutover, every retained cache-enabled target must either have
that exact supported mode or be rejected by PtcRunner's installation migration.
Cache is therefore a release checkpoint, not merely optional post-parity
hardening.

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
- extracts final usage when the target guarantees it, accepting both the
  documented OpenAI terminal usage chunk (`choices: []`) and OpenRouter's
  narrowly bounded repeated empty index-zero finish choice with the same
  already observed finish reason; the usage event is not delivered to the
  callback and does not count toward delivered bytes/chunks; and
- enforces cumulative decoded-text and event-count limits.

Tests cover one large HTTP chunk containing many events, one event split across
many small writes, comments/heartbeats, multi-line data, invalid JSON, missing
`[DONE]`, both empty-choice and OpenRouter repeated-finish terminal usage,
post-finish content/tool/index/reason/usage/`[DONE]` rejections, usage
before/after completion as supported by fixtures, early consumer cancellation,
slow consumer backpressure, and flood overflow.

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
| Concurrency tests | Runtime/group admission, atomic refusal, crash recovery, owner death |
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
- admission-owner death during each external phase and both sides of every
  terminal-value handoff, proving guardian cleanup and no candidate in shared
  state;
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
- an ExDNA type-I/type-II duplication ratchet over `lib/` and `test/`;
- unit, parser, codec, and local integration tests excluding explicitly tagged
  release tests; and
- generated-fixture staleness check if generators are introduced.

Target: comfortably under one minute warm on the maintainer machine. Do not
weaken property counts or correctness coverage to hit the target; split a
genuinely expensive platform/release check into `full_check` with its reason
documented.

### Before push/release: `mix full_check`

- everything in `mix check`;
- Dialyzer;
- supported Elixir/OTP toolchain checks;
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
- supported Elixir/OTP tests on Linux;
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
the same pattern it already uses for `PTC_EX_DNA_PATH`. Pre-release integration
may resolve an exact Git commit. Published and production PtcRunner builds must
resolve a published Hex requirement. The override must stay set consistently
for every Mix command in that build and must never affect the lock used by
releases.

Do not add this project as a nested Git repository inside PtcRunner. That would
keep its changes in PtcRunner's path classifier and preserve the slow push
problem this extraction is intended to solve.

### Thin adapter responsibilities

The PtcRunner adapter:

- receives an already canonical `PtcLlmHttp.Target` wrapped by the tagged host
  target; PtcRunner validates host structure but does not duplicate HTTP
  URL/path canonicalization;
- redeems one caller-bound credential-vault lease under the absolute deadline;
  the PtcRunner vault monitors this adapter worker and atomically revokes on
  explicit release or `DOWN`, while the package attempt independently monitors
  the adapter and owns cleanup of its credential copy;
- receives the contextual requester's already-anchored absolute provider/run
  deadline, cancellation identity, and authorized private-inspection sink;
- passes the package share of PtcRunner's generated aggregate provider-process
  budget; the package alone derives its versioned internal partition and clamps
  every per-attempt process;
- receives an already-held PtcRunner logical VM/group/alias lease acquired by
  the host-owned routing layer above adapter selection; this HTTP adapter does
  not own or bypass logical admission;
- calls the generation-bound package runtime handle atomically returned with
  the already-held logical lease; target/capability closures never retain a
  runtime PID or rebind across PtcRunner host generations;
- maps normalized response/tool/usage data into `PtcRunner.LLM` values;
- maps package stream completion into a provider-neutral Runner completion with
  no content field; a PtcRunner-owned wrapper accumulates chunks under the
  retained-result limit only for callers that explicitly request full content;
- maps `%PtcLlmHttp.Error{}` facts into bounded `ProviderError` and the same
  closed safe facts in authorized private inspection;
- invokes synchronous stream callbacks directly under the revised private
  adapter behavior, including the exact tagged early-halt outcome; and
- records alias, installation revision, logical call budget, and safe transport
  metadata in PtcRunner-owned traces.

The adapter does not rebuild HTTP requests, parse provider JSON, retry, or
special-case raw provider bodies. If it needs to do so, the package boundary is
wrong or incomplete.

### Integration checkpoints

1. Pin the bootstrap package and prove compile/application startup only.
2. Land PtcRunner's contextual requester, run-owned credential vault and
   per-invocation lease redemption, schema pass-through, callback stream
   behavior, positive output-token default, closed error mapping, and singleton
   runtime lifecycle while ReqLLM remains selected for command-owned use;
   host-owned transitional ReqLLM targets are rejected because their live Finch
   pool cannot be safely reconfigured or attested.
3. Integrate target construction and redaction without selecting the new
   adapter.
4. Run an OpenAI-compatible local fixture through the full Kernel requester.
5. Run adapter parity fixtures for text, errors, tools, structured output,
   usage, and streaming.
6. Run concurrent command/host/gateway tests proving logical and physical
   capacity interact without pool starvation or leaks.
7. Prove every retained cache-enabled installation has a supported translation
   or a closed migration rejection, and document opaque versus controlled
   gateway upstream routing.
8. Run supported live E2E against one OpenAI-compatible endpoint.
9. Make the new adapter selectable while ReqLLM remains available only in the
   explicitly bounded command-owned transition.
10. Publish the required Hex version, cut over shipped examples/defaults, then
   remove ReqLLM under the companion
   plan.

Update the package pin only at these coherent checkpoints. Root `mix.exs`,
`mix.lock`, dependency source, and release changes receive PtcRunner's normal
full compile/precommit/push verification.

## Delivery slices

### Slice 0 — repository bootstrap — complete

Completed by `bae77e0` and follow-up infrastructure commits through `cebdd8f`.
The public namespace remains pre-alpha and cannot perform a network request.

- Created the repository infrastructure, public module skeleton, application
  smoke, license, instructions, and retained protocol-evidence document.
- Recorded supported Elixir/OTP candidates without claiming a minimum OTP.
- Established the repository-owned fast/full gates, CI, hooks, and package/
  release verification infrastructure.

Exit met at `cebdd8f`: the bootstrap can be pinned by PtcRunner and performs no
network request. Opaque runtime/target/credential/deadline types plus their
constructor/redaction tests belong to Slice 2. The base closed error type and
runtime/resource contract entries also belong to Slice 2; Slice 4 completes and
versions the HTTP/provider partitions.

### Slice 1 — socket/TLS feasibility spike — complete

- Selected the pure-OTP backend: `PtcLlmHttp.Transport.SocketBackend` with
  `Tcp` and `Tls` implementations, passive mode, one arrival cap of 16 KiB, and
  no port helper. Probe code for the rejected shapes was never committed.
- Landed one conformance suite covering the full spike matrix — prompt partial
  delivery, exact caps, leftover preservation, deadlines before and between
  chunks, peer close either side of data, owner death, one connection per
  attempt, flow control, and read/write fragmentation as a property — run
  against scripted local TCP and TLS peers.
- Proved the handshake bounds against generated chains: `depth` rejects an
  over-long chain, and `max(16 KiB, max_handshake_size)` rejects a 200 KiB
  certificate while admitting a 20 KiB one.
- Established OTP 26 as the technical feasibility floor and selected
  `:public_key.cacerts_get/0` as the trust source. The retained transport record
  documents those measurements; the later package support policy intentionally
  standardizes on OTP 29.
- Deferred per-role heap ceilings to Slice 2 with the measurements and the two
  hazards that make them a runtime-wide decision rather than a socket option.
- Left one residual for Slice 2: closing a TLS socket does not wait for the
  peer, but it is a call into the `:ssl` connection process and inherits that
  call's five-second ceiling. No peer that reaches it was found. A teardown
  budget that does not depend on `:ssl` answering belongs with the slice that
  owns attempt processes, where killing the owner already closes the socket
  immediately.

Exit met: the backend contract held on macOS locally and on the spike's Linux/
OTP matrix. Current CI exercises the supported OTP 29 baseline on Linux and
macOS. No public API and no HTTP request exists yet; the backends are internal
and carry redacted `Inspect` implementations.

### Slice 2 — target, credential, deadline, and admission runtime — complete

- Added opaque target, credential, deadline, process-budget, and error values
  with sentinel redaction tests and exact external-input validation.
- Published the data-only `resource-v1` and `error-base-v1` contracts, with the
  package-owned `process-v1` and `runtime-control-v1` partitions. `resource-v2`
  and `process-v2` later added the hostname aggregate and DNS-role floor.
- Added the internal named limit catalog, current IANA-derived connect policy,
  literal-loopback restriction, bounded RFC 6750 bearer grammar, and exact URL
  path decoding rules.
- Added the `:rest_for_one` runtime root, stable guardian, temporary fail-stop
  generation, atomic global/group admission owner, dynamic attempt supervisor,
  and fixed-role `:one_for_all` attempt trees.
- Made admission provisionally monitor the caller and own tree startup until
  guardian registration atomically adopts the lease; caller death in that
  pre-registration window kills the payload-free tree and releases capacity.
- Added caller-retained two-phase terminal handoff, aggregate 900/100 millisecond
  concurrent cleanup, per-process heap ceilings, phase/dispatch tracking,
  closed resource-limit classification, and generation fencing/replacement.
- Proved readiness/snapshots, atomic refusal, success/classified-error release,
  delayed deadline arbitration, caller and runtime-owner death, every fixed
  role's and the attempt supervisor tree's heap death before/after dispatch,
  terminal-candidate precedence, admission-owner death before/after terminal
  handoff, guardian/attempt-supervisor/outer-generation death, no payload in
  shared control state, and replacement without stale capacity through the
  scripted backend.

Exit met: no HTTP parsing yet, but one internal attempt can be safely admitted,
cancelled, classified, and cleaned up before its physical lease is released.

### Slice 3 — bounded HTTP/1 core — complete

- Added bounded DNS resolution in the dedicated attempt role, rejected empty,
  malformed, mixed-policy, and cap-plus-one answer sets, and deterministically
  pinned one approved address while retaining the validated DNS Host/SNI name.
- Added exact POST serialization for validated origin-form targets, fixed
  framing/identity/close headers, optional bearer authorization, body/head
  ceilings, and one send call under the absolute deadline.
- Added a strict incremental HTTP/1.1 parser for bounded informational heads,
  content-length and ordinary chunked bodies, chunk extensions, separate
  bounded trailers, early close, and cap-plus-one rejection. Redirects,
  compression, ambiguous length, unsupported transfer coding, close-delimited
  bodies, upgrades, and malformed CRLF framing are rejected.
- Routed DNS and the one socket through the registered fail-stop attempt tree;
  deadline and caller death close the socket before physical capacity is
  released. Raw TCP/TLS fixtures assert exact bytes, one connection, one
  request, cleanup, and pinned-address TLS identity; property tests vary every
  response boundary.

Exit met: arbitrary bounded JSON echo requests work against local fixtures
without provider semantics. The transport entry point remains internal; Slice
4 owns the provider-neutral request/response structs, public call API, and the
versioned HTTP/provider error partitions.

### Slice 4 — OpenAI-compatible text and errors — complete

- Added the exact provider-neutral text request surface, redacted normalized
  response and usage values, and the public one-attempt `call/4` API.
- Added deterministic `/chat/completions` encoding with model insertion,
  ordered system/user/assistant messages, `n: 1`, non-stream selection, and
  bounded optional output-token, temperature, and seed fields.
- Added bounded JSON decoding in the attempt codec role, one usable assistant
  choice, optional or guaranteed token/cost usage extraction, and explicit
  OpenRouter cached-token/cost mappings.
- Completed `error-openai-v1` with classified DNS, connect, TLS, framing,
  response-limit, HTTP status, provider-code, and malformed-response facts;
  completeness tests enumerate every contract entry. Documented quota codes
  are retained only on HTTP 429 responses.
- Added exact raw-loopback request/response fixtures proving one connection,
  terminal handoff, redaction, usage, error text discard, pre-connect
  capability rejection, and physical lease release.

Exit met in this package: text calls are independently releasable. PtcRunner
cutover remains a pinned integration checkpoint and is intentionally not
performed from this repository.

### Slice 5 — tools and structured output — complete

- Added exact strict function definitions, assistant tool-call replay, ordered
  tool results, parallel returned calls, bounded decoded argument objects, and
  redacted tool-call values.
- Added strict JSON Schema and JSON-object request translation, response object
  validation, and deterministic canonical JSON output.
- Added exact local wire fixtures and malformed/null/scalar/schema-mismatch/
  overflow coverage. PtcRunner parity remains a pinned consumer checkpoint and
  is intentionally not performed from this repository.
- Verification on 2026-08-21: `mix check` completed in 18.38 seconds; the full
  supported-toolchain, audit, minimum-runtime, Dialyzer, docs, release-smoke, and
  package gate (`mix full_check`) completed in 97.58 seconds.

Exit met in this package: non-streaming tool and structured-output capability
is independently releasable for supported targets.

### Slice 6 — streaming — complete

- Added a bounded incremental UTF-8 SSE parser with comment/heartbeat,
  LF/CRLF/CR, multi-line data, per-event, event-count, trailing-event, and
  unsupported `id`/`retry` enforcement.
- Added `PtcLlmHttp.stream/5` with exact `stream: true` plus
  `stream_options.include_usage`, synchronous monitored callback execution,
  natural socket backpressure, `:cont | :halt`, terminal usage, `[DONE]`, and
  independent 262,144-byte decoded-text enforcement.
- Added redacted stream completion/halt values and caller-retained terminal
  handoff, including partial usage observed before early halt.
- Proved byte-wise fragmentation, one-read event floods, permanently blocked
  callbacks, deadline and caller-cancellation cleanup, callback raise/throw/
  exit, early halt, usage guarantees, missing/extra terminal states, wire/event/
  count/text overflow, and explicit V1 rejection of tool-bearing requests and
  tool-call deltas.
- Kept PtcRunner direct callback-consumption and gateway-disconnect tests as the
  separate consumer-repository checkpoint; no Enumerable bridge or producer
  mailbox was added here.
- 2026-08-21: accepted OpenRouter's repeated-finish terminal usage event as a
  compatible extension of the documented `choices: []` usage chunk, with a
  fragmented raw-TCP/SSE regression and a post-finish rejection table.

Exit met in this package: text streaming parity without tool-delta support.
PtcRunner callback consumption and gateway disconnect remain the pinned next
integration checkpoint.

### Slice 7 — cache mode, observability, and hardening

- Add every cache translation required by a retained PtcRunner target, each
  proven by exact fixtures; otherwise record the corresponding installation
  migration rejection before cutover.
- Add closed upstream-routing capabilities required by supported gateways and
  label all other gateway routing opaque.
- Finalize safe numeric metadata and the private-inspection projection of the
  same closed error facts; no provider-text evidence channel is added.
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

- Publish the exact package version to Hex. A Git tag or commit is only a
  pre-release integration checkpoint and cannot satisfy this slice.
- Publish only through the manually dispatched `hex-publish` environment. Its
  dry-run mode must authenticate and validate the package without publication;
  publish mode additionally runs only from `main` and requires an exact
  `vVERSION` tag naming that commit, the complete release gate, explicit
  environment approval, and the step-scoped `HEX_API_KEY` environment secret.
- Pin the Hex requirement in PtcRunner, extend its package-metadata verifier,
  and run the root full gate, release verification, focused
  independent review, and live supported E2E.
- Document supported/unsupported providers and the failover implication:
  native Bedrock requires another adapter or an OpenAI-compatible gateway.
- Begin ReqLLM deletion only after the companion plan's cutover criteria pass.

## Acceptance matrix

- Target and credential rejection occurs before DNS/connect.
- Literal and every resolved address is authorized by the target's closed
  connect policy immediately before the single pinned connect; HTTPS IP
  literals are rejected and Host/SNI retain the original DNS hostname.
- One call opens at most one socket and produces at most one HTTP request.
- Runtime/group saturation is atomic, fail-fast, and observable; independent
  runtime instances are explicitly independent capacity domains.
- Runtime concurrency/group counts and shared admission/supervisor heaps satisfy
  the fixed control-memory formula; control overflow poisons the generation.
- Guardian fallback teardown observes every old attempt/role `DOWN` before a new
  generation becomes ready, including admission-owner failure mid-handoff.
- Success, every error, timeout, cancellation, callback failure, caller death,
  and runtime-owner failure release or poison capacity exactly as specified.
- Every value-bearing response, stream completion/halt, and classified error
  travels only from the bounded relay to the bounded authorized caller and
  becomes returnable only after opaque arbitration/teardown/lease commit; shared
  control owners never retain or copy it, and superseded candidates are
  discarded.
- Every package-owned allocation process has a non-disableable role ceiling,
  all concurrent role ceilings fit one aggregate attempt budget, and forced
  heap kills return the closed resource-limit outcome only after the full
  attempt tree is down.
- TCP and TLS `recv_up_to` satisfy prompt partial delivery and exact caps.
- TLS handshake and certificate-chain processing satisfy the selected bounded
  resource contract or the transport stops at the feasibility gate.
- Request targets and headers are injection-safe and encoded exactly once.
- Status, headers, chunk framing, trailers, SSE, body, JSON, tool arguments,
  and decoded text remain within independent caps under arbitrary
  fragmentation.
- Redirects, compression, ambiguous framing, close-delimited bodies, proxy
  environment, and transparent retries are impossible in V1.
- Text, tools, structured output, synchronous streaming with `:cont | :halt`,
  usage, required cache modes, and upstream-routing declarations match the
  documented normalized contract on supported OpenAI-compatible fixtures.
- Stream success returns completion/usage metadata without retained content;
  only the consumer's separately bounded wrapper may accumulate full text.
- Errors carry sufficient closed kind, phase, status/code, scope, and dispatch
  state for PtcRunner's complete `ProviderError` mapping without raw-body
  inspection.
- No ordinary inspection/log/telemetry path discloses target, model, prompt,
  tool arguments, credential, header, body, or provider text.
- The package builds and its TLS trust works in a minimal release.
- The production integration uses a published Hex package; Git/path pins remain
  development checkpoints only.
- Minimum and current supported Elixir/OTP jobs pass.
- PtcRunner integration contains transport mapping, not a second HTTP/parser
  implementation.
- Routine package pushes do not run PtcRunner's full gate; pinned integration
  updates do.

## Risks and stop conditions

### TLS bounded-read feasibility — cleared

The primary technical stop condition did not fire; `docs/transport-backend.md`
records why, with the measurements. It stays live as a regression rule rather
than an open risk: do not build a streaming parser on an API that can only
block for the requested maximum or deliver an unbounded record, and do not
relax the handshake or chain bounds without new evidence in that document.

### Scope creep into ReqLLM

Reject model catalogs, pricing inference, prompt frameworks, arbitrary
provider options, native provider protocols, client retries, and
client-initiated failover. When a feature request is provider-specific, prefer
a separate adapter or an explicit target capability backed by fixtures. A
closed gateway control that disables upstream fallback is routing declaration,
not package-initiated failover.

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
- client-initiated provider failover, circuit breakers, retries, or fallback
  prompts;
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
