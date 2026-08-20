defmodule PtcLlmHttp.Http.Request do
  @moduledoc false

  alias PtcLlmHttp.{Credential, Limits, Target}

  @user_agent "ptc_llm_http/0.0.1"
  @token_special ~c"!#$%&'*+-.^_`|~"
  @pchar_special ~c"!$&'()*+,-.:;=@_~"

  @spec encode(Target.t(), Credential.t(), [binary()], binary()) ::
          {:ok, binary(), binary(), non_neg_integer()} | {:error, atom()}
  def encode(%Target{} = target, %Credential{} = credential, operation_segments, body)
      when is_list(operation_segments) and is_binary(body) do
    authority = Target.authority(target)

    with true <- byte_size(body) <= target.max_encoded_request_bytes,
         {:ok, request_target} <- request_target(authority.path_segments, operation_segments),
         {:ok, fields} <- fields(authority, credential, byte_size(body)),
         true <- length(fields) <= Limits.request_header_fields(),
         {:ok, head} <- head(request_target, fields),
         true <- byte_size(head) <= Limits.request_head_bytes() do
      {:ok, head, body, byte_size(head) + byte_size(body)}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  def encode(_target, _credential, _operation_segments, _body),
    do: {:error, :invalid_request}

  defp request_target(base_segments, operation_segments) do
    segments = base_segments ++ operation_segments

    if Enum.all?(operation_segments, &valid_operation_segment?/1) do
      target = "/" <> Enum.map_join(segments, "/", &encode_segment/1)

      if byte_size(target) <= Limits.base_url_bytes(),
        do: {:ok, target},
        else: {:error, :request_target_too_large}
    else
      {:error, :invalid_request_target}
    end
  end

  defp valid_operation_segment?(segment) when is_binary(segment) do
    byte_size(segment) > 0 and
      Enum.all?(:binary.bin_to_list(segment), fn byte ->
        byte > 31 and byte != 127 and byte not in [?/, ?\\]
      end)
  end

  defp valid_operation_segment?(_segment), do: false

  defp encode_segment(segment) do
    for <<byte <- segment>>, into: <<>> do
      if pchar?(byte), do: <<byte>>, else: percent(byte)
    end
  end

  defp pchar?(byte),
    do: byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in @pchar_special

  defp percent(byte) do
    digits = "0123456789ABCDEF"
    <<"%", :binary.at(digits, div(byte, 16)), :binary.at(digits, rem(byte, 16))>>
  end

  defp fields(authority, credential, content_length) do
    base = [
      {"Host", host(authority)},
      {"Content-Type", "application/json"},
      {"Accept", "application/json"},
      {"Accept-Encoding", "identity"},
      {"Connection", "close"},
      {"User-Agent", @user_agent},
      {"Content-Length", Integer.to_string(content_length)}
    ]

    fields =
      case Credential.authorization_value(credential) do
        nil -> base
        value -> base ++ [{"Authorization", IO.iodata_to_binary(value)}]
      end

    if Enum.all?(fields, &valid_field?/1), do: {:ok, fields}, else: {:error, :invalid_header}
  end

  defp host(%{scheme: scheme, host: host, port: port}) do
    host = if ipv6?(host), do: "[#{host}]", else: host

    if default_port?(scheme, port), do: host, else: host <> ":" <> Integer.to_string(port)
  end

  defp ipv6?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> tuple_size(address) == 8
      {:error, _reason} -> false
    end
  end

  defp default_port?(:http, 80), do: true
  defp default_port?(:https, 443), do: true
  defp default_port?(_scheme, _port), do: false

  defp valid_field?({name, value}) do
    byte_size(name) in 1..Limits.header_name_bytes() and
      byte_size(value) <= Limits.header_value_bytes() and token?(name) and visible_value?(value)
  end

  defp token?(value) do
    Enum.all?(:binary.bin_to_list(value), fn byte ->
      byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in @token_special
    end)
  end

  defp visible_value?(value) do
    Enum.all?(:binary.bin_to_list(value), fn byte -> byte == ?\t or byte in 32..126 end)
  end

  defp head(request_target, fields) do
    encoded = [
      "POST ",
      request_target,
      " HTTP/1.1\r\n",
      Enum.map(fields, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n"
    ]

    {:ok, IO.iodata_to_binary(encoded)}
  rescue
    _invalid_iodata -> {:error, :invalid_header}
  end
end
