defmodule PtcLlmHttp.Target do
  @moduledoc """
  Validated target authority and wire capabilities.

  A target is canonicalized once. It contains no credential and inspection
  reveals none of its endpoint, model, group, or capability configuration.
  HTTPS is mandatory except for an explicitly authorized literal loopback HTTP
  target.
  """

  alias PtcLlmHttp.{ConnectPolicy, Credential, Error, Limits}

  @base_url_bytes Limits.base_url_bytes()

  @enforce_keys [
    :kind,
    :scheme,
    :host,
    :port,
    :path_segments,
    :model,
    :capacity_group,
    :connect_policy,
    :max_encoded_request_bytes,
    :max_wire_response_bytes,
    :tools,
    :streaming,
    :structured_output,
    :cache_mode,
    :upstream_routing,
    :usage_guarantees,
    :codec_version
  ]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{}

  @keys [
    :kind,
    :base_url,
    :model,
    :capacity_group,
    :connect_policy,
    :max_encoded_request_bytes,
    :max_wire_response_bytes,
    :tools,
    :streaming,
    :structured_output,
    :cache_mode,
    :upstream_routing,
    :usage_guarantees
  ]

  @doc "Validates and canonicalizes one OpenAI-compatible target."
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) when is_list(options) do
    with :ok <- exact_options(options),
         {:ok, authority} <- parse_authority(Keyword.fetch!(options, :base_url)),
         :ok <- kind(Keyword.fetch!(options, :kind)),
         {:ok, model} <- bounded_identifier(Keyword.fetch!(options, :model), Limits.model_bytes()),
         {:ok, group} <-
           bounded_identifier(
             Keyword.fetch!(options, :capacity_group),
             Limits.capacity_group_bytes()
           ),
         {:ok, policy} <-
           ConnectPolicy.compile(
             Keyword.fetch!(options, :connect_policy),
             authority.scheme,
             authority.host
           ),
         :ok <- capabilities(options),
         :ok <- wire_limits(options) do
      {:ok,
       struct!(__MODULE__,
         kind: :openai_compat,
         scheme: authority.scheme,
         host: authority.host,
         port: authority.port,
         path_segments: authority.path_segments,
         model: model,
         capacity_group: group,
         connect_policy: policy,
         max_encoded_request_bytes: Keyword.fetch!(options, :max_encoded_request_bytes),
         max_wire_response_bytes: Keyword.fetch!(options, :max_wire_response_bytes),
         tools: Keyword.fetch!(options, :tools),
         streaming: Keyword.fetch!(options, :streaming),
         structured_output: Keyword.fetch!(options, :structured_output),
         cache_mode: Keyword.fetch!(options, :cache_mode),
         upstream_routing: Keyword.fetch!(options, :upstream_routing),
         usage_guarantees: Keyword.fetch!(options, :usage_guarantees),
         codec_version: "openai-compat-v1"
       )}
    else
      _invalid -> invalid()
    end
  rescue
    _external_input -> invalid()
  end

  def new(_options), do: invalid()

  @doc false
  def capacity_group(%__MODULE__{capacity_group: group}), do: group

  @doc false
  def connect_policy(%__MODULE__{connect_policy: policy}), do: policy

  @doc false
  def credential_compatible?(%__MODULE__{scheme: :https}, %Credential{}), do: true

  def credential_compatible?(
        %__MODULE__{scheme: :http, connect_policy: :literal_loopback},
        %Credential{} = credential
      ),
      do: Credential.kind(credential) == :none

  @doc false
  def authority(%__MODULE__{} = target) do
    %{
      scheme: target.scheme,
      host: target.host,
      port: target.port,
      path_segments: target.path_segments
    }
  end

  defp exact_options(options) do
    if Keyword.keyword?(options) and length(options) == length(@keys) and
         Enum.sort(Keyword.keys(options)) == Enum.sort(@keys) do
      :ok
    else
      {:error, :invalid_options}
    end
  end

  defp parse_authority(base_url)
       when is_binary(base_url) and byte_size(base_url) > 0 and
              byte_size(base_url) <= @base_url_bytes do
    with true <- ascii?(base_url),
         %URI{} = uri <- URI.parse(base_url),
         {:ok, scheme} <- scheme(uri.scheme),
         {:ok, host} <- hostname(uri.host),
         true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         {:ok, port} <- port(uri.port, scheme),
         {:ok, segments} <- path_segments(uri.path) do
      {:ok, %{scheme: scheme, host: host, port: port, path_segments: segments}}
    else
      _invalid -> {:error, :invalid_authority}
    end
  end

  defp parse_authority(_base_url), do: {:error, :invalid_authority}

  defp scheme("https"), do: {:ok, :https}
  defp scheme("http"), do: {:ok, :http}
  defp scheme(_scheme), do: {:error, :invalid_scheme}

  defp hostname(host) when is_binary(host) and byte_size(host) > 0 do
    host = String.downcase(host)

    cond do
      String.contains?(host, "%") -> {:error, :zone_identifier}
      match?({:ok, _address}, ConnectPolicy.parse_address(host)) -> {:ok, host}
      dns_name?(host) -> {:ok, host}
      true -> {:error, :invalid_hostname}
    end
  end

  defp hostname(_host), do: {:error, :invalid_hostname}

  defp dns_name?(host) do
    byte_size(host) <= 253 and
      Enum.all?(String.split(host, ".", trim: false), fn label ->
        byte_size(label) in 1..63 and ascii_alnum?(binary_part(label, 0, 1)) and
          ascii_alnum?(binary_part(label, byte_size(label) - 1, 1)) and
          Enum.all?(:binary.bin_to_list(label), fn byte ->
            byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte == ?-
          end)
      end)
  end

  defp ascii_alnum?(<<byte>>),
    do: byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9

  defp port(nil, :https), do: {:ok, 443}
  defp port(nil, :http), do: {:ok, 80}
  defp port(value, _scheme) when is_integer(value) and value in 1..65_535, do: {:ok, value}
  defp port(_value, _scheme), do: {:error, :invalid_port}

  defp path_segments(nil), do: {:ok, []}
  defp path_segments(""), do: {:ok, []}

  defp path_segments(<<"/", path::binary>>) do
    path
    |> String.split("/", trim: false)
    |> Enum.reduce_while({:ok, []}, fn segment, {:ok, decoded} ->
      case decode_segment(segment) do
        {:ok, value} -> {:cont, {:ok, [value | decoded]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp path_segments(_path), do: {:error, :invalid_path}

  defp decode_segment(segment), do: decode_segment(segment, <<>>)

  defp decode_segment(<<>>, decoded) do
    if decoded in [".", ".."], do: {:error, :path_traversal}, else: {:ok, decoded}
  end

  defp decode_segment(<<"%", high, low, rest::binary>>, decoded) do
    with {:ok, high} <- hex(high),
         {:ok, low} <- hex(low),
         byte = high * 16 + low,
         true <- safe_decoded_path_byte?(byte) do
      decode_segment(rest, <<decoded::binary, byte>>)
    else
      _invalid -> {:error, :invalid_path_escape}
    end
  end

  defp decode_segment(<<"%", _rest::binary>>, _decoded), do: {:error, :invalid_path_escape}

  defp decode_segment(<<byte, rest::binary>>, decoded) do
    if raw_path_byte?(byte) do
      decode_segment(rest, <<decoded::binary, byte>>)
    else
      {:error, :invalid_path_byte}
    end
  end

  defp hex(byte) when byte in ?0..?9, do: {:ok, byte - ?0}
  defp hex(byte) when byte in ?A..?F, do: {:ok, byte - ?A + 10}
  defp hex(byte) when byte in ?a..?f, do: {:ok, byte - ?a + 10}
  defp hex(_byte), do: {:error, :invalid_hex}

  defp safe_decoded_path_byte?(byte), do: byte > 31 and byte != 127 and byte not in [?/, ?\\]

  defp raw_path_byte?(byte) do
    byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or
      byte in [?-, ?., ?_, ?~, ?!, ?$, ?&, ?', ?(, ?), ?*, ?+, ?,, ?;, ?=, ?:, ?@]
  end

  defp kind(:openai_compat), do: :ok
  defp kind(_kind), do: {:error, :invalid_kind}

  defp bounded_identifier(value, maximum)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= maximum do
    if String.valid?(value) and Enum.all?(:binary.bin_to_list(value), &(&1 > 31 and &1 != 127)) do
      {:ok, value}
    else
      {:error, :invalid_identifier}
    end
  end

  defp bounded_identifier(_value, _maximum), do: {:error, :invalid_identifier}

  defp capabilities(options) do
    usage = Keyword.fetch!(options, :usage_guarantees)

    if is_boolean(Keyword.fetch!(options, :tools)) and
         is_boolean(Keyword.fetch!(options, :streaming)) and
         Keyword.fetch!(options, :structured_output) in [:unsupported, :json_schema] and
         Keyword.fetch!(options, :cache_mode) in [:unsupported, :explicit] and
         Keyword.fetch!(options, :upstream_routing) in [:opaque, :single_provider] and
         is_map(usage) and map_size(usage) == 2 and is_boolean(usage[:tokens]) and
         is_boolean(usage[:cost]) and Map.has_key?(usage, :tokens) and Map.has_key?(usage, :cost) do
      :ok
    else
      {:error, :invalid_capabilities}
    end
  end

  defp wire_limits(options) do
    request = Keyword.fetch!(options, :max_encoded_request_bytes)
    response = Keyword.fetch!(options, :max_wire_response_bytes)

    if is_integer(request) and request in 1..Limits.encoded_request_bytes() and
         is_integer(response) and response in 1..Limits.wire_response_bytes() do
      :ok
    else
      {:error, :invalid_wire_limits}
    end
  end

  defp ascii?(value), do: Enum.all?(:binary.bin_to_list(value), &(&1 <= 127))

  defp invalid, do: {:error, Error.build!(:invalid_target, :validate, :request, :not_sent)}
end

defimpl Inspect, for: PtcLlmHttp.Target do
  def inspect(_target, _options), do: "#PtcLlmHttp.Target<redacted>"
end
