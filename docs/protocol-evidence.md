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

None yet — this file is seeded with the bootstrap commit. The first entries
arrive with the HTTP/1 core (Slice 3) and the OpenAI-compatible codec
(Slice 4).

| Area | Decision | Source | Version / revision | Accessed | Fixture |
| --- | --- | --- | --- | --- | --- |
