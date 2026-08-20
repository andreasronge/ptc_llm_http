# Protocol evidence

Retained record of the primary sources behind every wire decision in this
package. It is not background reading: a shape that is implemented without an
entry here, and without an exact local fixture, is unsupported.

## Rules

1. **Primary sources only.** RFC 3986 for URI syntax, RFC 9110 and RFC 9112 for
   HTTP semantics and HTTP/1.1 framing, the WHATWG HTML standard for the
   server-sent-event format, and official provider documentation for codecs.
2. **Documentation is not proof.** Every supported shape also has an exact
   local request/response fixture under `test/fixtures/`. The fixture is what
   the parser is tested against; the document explains why the fixture is
   correct.
3. **Record what was read.** Source URL, access date, and the exact
   protocol/document version or provider API version.
4. **A surprising response is not a licence to loosen a parser.** When a
   provider changes wire behavior, add the new fixture and decide explicitly
   whether it is a compatible extension or a target capability/version change.
   Do not make a domain-blind parser permissive to accommodate one
   undocumented response.

## Entries

HTTP framing and provider-codec entries arrive with the HTTP/1 core and the
OpenAI-compatible codec. The transport entries below came first, because the
socket layer had to know what a TLS record can hold before anything could be
read into a bounded buffer.

| Area | Decision | Source | Version / revision | Accessed | Fixture |
| --- | --- | --- | --- | --- | --- |
| Target addresses | `:public` accepts globally reachable unicast and rejects private, shared, loopback, link-local, documentation, benchmark, unallocated/reserved, mapped, and other non-global blocks. IPv6 is allowlisted from the global-unicast allocation registry, then narrowed by the special-purpose registry. | IANA IPv4/IPv6 Special-Purpose Address Registries and IPv6 Global Unicast Address Space, <https://www.iana.org/assignments/iana-ipv4-special-registry/>, <https://www.iana.org/assignments/iana-ipv6-special-registry/>, and <https://www.iana.org/assignments/ipv6-unicast-address-assignments/> | Special registries updated 2025-10-09; global-unicast registry updated 2025-10-10 | 2026-08-20 | `test/ptc_llm_http/target_test.exs`, "compiled policies enforce current IANA reachability and exact CIDR edges" |
| Bearer credentials | The `Authorization` value uses the RFC 6750 `Bearer` scheme and accepts exactly its bounded `b64token` alphabet and trailing padding grammar. | RFC 6750 section 2.1, <https://www.rfc-editor.org/rfc/rfc6750.html#section-2.1> | RFC 6750 | 2026-08-20 | `test/ptc_llm_http/value_contracts_test.exs`, "accepts no credential and bounded RFC 6750 bearer tokens" |
| Target URI path | The constructor separates URI components, rejects userinfo/query/fragment, splits the raw path on literal `/`, and percent-decodes each segment exactly once before rejecting separator, control, and traversal-shaped segments. | RFC 3986 sections 2.1, 3, and 6, <https://www.rfc-editor.org/rfc/rfc3986.html> | RFC 3986 | 2026-08-20 | `test/ptc_llm_http/target_test.exs`, constructor path table |
| TLS records | One read returns at most 16 KiB of application plaintext, which is the arrival cap both socket backends pin `buffer` to. TLS 1.3's `2^14+1` limit counts the inner content-type byte, so the payload bound is unchanged. | RFC 8446 section 5.1; the limit as restated in RFC 8449 section 4, <https://www.rfc-editor.org/rfc/rfc8449.html> ("For TLS 1.2 and earlier, that limit is 2^14 octets. TLS 1.3 uses a limit of 2^14+1 octets.") | TLS 1.2 and TLS 1.3 | 2026-08-20 | `test/ptc_llm_http/transport/tls_test.exs`, "one arrival is one TLS record at most" |
| TLS alerts | An alert name is a diagnostic, not a contract: OTP 26, 27 and 29 answer the same rejected certificate with different alerts, so error mapping classifies by kind | Measured across releases; the alert set is RFC 8446 section 6.2 | OTP 26.2.5, 27.3.4, 29.0.3 | 2026-08-20 | `test/ptc_llm_http/transport/tls_test.exs`, `@certificate_rejected` |
| TLS ALPN | The client offers `http/1.1` only; a peer sharing no protocol with it fails the handshake instead of negotiating something else | RFC 7301 section 3.2, <https://www.rfc-editor.org/rfc/rfc7301#section-3.2> ("the server SHALL respond with a fatal `no_application_protocol` alert") | RFC 7301 | 2026-08-20 | `test/ptc_llm_http/transport/tls_test.exs`, "verifies the chain and negotiates HTTP/1.1" |
| TLS identity | Certificate verification uses the DNS name the caller started from, while the socket goes to one approved address | RFC 9110 section 4.3.4, <https://www.rfc-editor.org/rfc/rfc9110#section-4.3.4>, which defers the matching rules to RFC 6125 section 6 | RFC 9110, RFC 6125 | 2026-08-20 | `test/ptc_llm_http/transport/tls_test.exs`, "verifies the certificate against the hostname while connecting to a pinned address" |
| TLS identity | A certificate that names the host only in its common name is rejected | RFC 9110 section 4.3.4, <https://www.rfc-editor.org/rfc/rfc9110#section-4.3.4> ("A reference identity of type CN-ID MUST NOT be used by clients") | RFC 9110 | 2026-08-20 | `test/ptc_llm_http/transport/tls_test.exs`, "rejects a certificate that names the host only in its common name" |
