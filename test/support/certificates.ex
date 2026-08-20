defmodule PtcLlmHttp.Test.Certificates do
  @moduledoc false

  # In-memory certificate authoring for the TLS suite. Nothing is written to
  # disk and nothing is committed: a repository fixture would carry a private
  # key and would start failing on the day it expired, which is a poor way to
  # learn that a validity check works.

  alias X509.Certificate.Extension

  @type bundle :: %{
          roots: [binary()],
          chain: [binary()],
          key: {:ECPrivateKey, binary()},
          # An `X509.Certificate` record. Named loosely on purpose: X509's own
          # types are macro-generated and unknown to Dialyzer.
          authority: tuple()
        }

  @doc """
  Builds a server bundle: a root, `:depth` intermediates, and a leaf.

    * `:depth` — intermediate CAs between root and leaf (default 1)
    * `:names` — subject alternative names on the leaf (default `["localhost"]`);
      an empty list leaves the leaf with a common name and no SAN at all
    * `:validity` — leaf validity, e.g. an `X509.Certificate.Validity` in the past
    * `:extensions` — extra leaf extensions, such as an oversized one
    * `:trusted_by` — the authorities the client is told to trust (default: this
      bundle's own root, so another bundle's `:authority` makes the chain
      untrusted without making it malformed)
  """
  @spec build(keyword()) :: bundle()
  def build(options \\ []) do
    names = Keyword.get(options, :names, ["localhost"])
    root_key = X509.PrivateKey.new_ec(:secp256r1)

    root =
      X509.Certificate.self_signed(root_key, "/CN=ptc-llm-http-test-root",
        template: :root_ca,
        extensions: unconstrained()
      )

    {issuer_key, issuer, intermediates} =
      intermediates(root_key, root, Keyword.get(options, :depth, 1))

    key = X509.PrivateKey.new_ec(:secp256r1)

    leaf =
      X509.Certificate.new(
        X509.PublicKey.derive(key),
        "/CN=#{Keyword.get(options, :common_name, List.first(names, "localhost"))}",
        issuer,
        issuer_key,
        [extensions: leaf_extensions(names, options)] ++ Keyword.take(options, [:validity])
      )

    %{
      roots: Enum.map(Keyword.get(options, :trusted_by, [root]), &X509.Certificate.to_der/1),
      chain: Enum.map([leaf | intermediates], &X509.Certificate.to_der/1),
      key: {:ECPrivateKey, X509.PrivateKey.to_der(key)},
      authority: root
    }
  end

  @doc "`:ssl.listen/2` options that present `bundle`."
  @spec server_options(bundle()) :: keyword()
  def server_options(bundle) do
    [cert: hd(bundle.chain), key: bundle.key, cacerts: tl(bundle.chain)]
  end

  @doc "Total DER size of the chain the server will present."
  @spec chain_size(bundle()) :: non_neg_integer()
  def chain_size(bundle), do: bundle.chain |> Enum.map(&byte_size/1) |> Enum.sum()

  defp intermediates(root_key, root, depth) do
    Enum.reduce(1..depth//1, {root_key, root, []}, fn index, {issuer_key, issuer, chain} ->
      key = X509.PrivateKey.new_ec(:secp256r1)

      certificate =
        X509.Certificate.new(
          X509.PublicKey.derive(key),
          "/CN=ptc-llm-http-test-intermediate-#{index}",
          issuer,
          issuer_key,
          template: :ca,
          extensions: unconstrained()
        )

      {key, certificate, [certificate | chain]}
    end)
  end

  defp leaf_extensions([], options), do: Keyword.get(options, :extensions, [])

  defp leaf_extensions(names, options) do
    [subject_alt_name: Extension.subject_alt_name(names)] ++
      Keyword.get(options, :extensions, [])
  end

  # X509's CA templates carry a path-length constraint, which would reject a
  # long chain before OTP's own `depth` check ever saw it. The depth tests need
  # the chain to be structurally valid and merely long.
  defp unconstrained, do: [basic_constraints: Extension.basic_constraints(true)]
end
