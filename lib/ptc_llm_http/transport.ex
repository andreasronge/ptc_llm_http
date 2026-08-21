defmodule PtcLlmHttp.Transport do
  @moduledoc false

  alias PtcLlmHttp.{Credential, Deadline, Error, ProcessBudget, Runtime, Target}
  alias PtcLlmHttp.Http.{Parser, Request}
  alias PtcLlmHttp.Runtime.Role
  alias PtcLlmHttp.Transport.{Dns, Tcp, Tls, Trust}

  @option_keys [:decoder, :resolver, :streamer, :trust]

  @doc false
  @spec request(
          Runtime.t(),
          Target.t(),
          Credential.t(),
          [binary()],
          binary(),
          ProcessBudget.t(),
          Deadline.t(),
          keyword()
        ) :: {:ok, term()} | {:halted, term()} | {:error, Error.t()}
  def request(
        runtime,
        target,
        credential,
        operation_segments,
        body,
        budget,
        deadline,
        options \\ []
      )

  def request(
        runtime,
        target,
        credential,
        operation_segments,
        body,
        budget,
        deadline,
        options
      )
      when is_pid(runtime) and is_list(options) do
    with :ok <- validate_options(options),
         true <- Target.credential_compatible?(target, credential),
         {:ok, deadline} <- Deadline.validate(deadline),
         {:ok, _remaining} <- Deadline.remaining(deadline) do
      encode_and_run(
        runtime,
        target,
        credential,
        operation_segments,
        body,
        budget,
        deadline,
        options
      )
    else
      false -> {:error, Error.build!(:invalid_credential, :validate, :credential, :not_sent)}
      :error -> {:error, Error.build!(:invalid_request, :validate, :request, :not_sent)}
      {:error, error} -> {:error, error}
    end
  end

  def request(_runtime, _target, _credential, _segments, _body, _budget, _deadline, _options),
    do: {:error, Error.build!(:invalid_request, :validate, :request, :not_sent)}

  defp encode_and_run(
         runtime,
         target,
         credential,
         operation_segments,
         body,
         budget,
         deadline,
         options
       ) do
    response_type = if Keyword.get(options, :streamer), do: :event_stream, else: :json

    case Request.encode(target, credential, operation_segments, body, response_type) do
      {:ok, head, body, encoded_bytes} ->
        operation =
          {:http,
           %{
             target: target,
             head: head,
             body: body,
             encoded_bytes: encoded_bytes,
             resolver: Keyword.get(options, :resolver, &Dns.system_resolve/1),
             trust: Keyword.get(options, :trust, :system),
             decoder: Keyword.get(options, :decoder, fn response -> {:ok, response} end),
             streamer: Keyword.get(options, :streamer)
           }}

        Runtime.run_http(runtime, target, budget, deadline, operation)

      {:error, _reason} ->
        {:error, Error.build!(:invalid_request, :encode, :request, :not_sent)}
    end
  end

  @doc false
  def resolve(%{target: target, resolver: resolver, trust: trust}) do
    with {:ok, address} <- Dns.resolve(target, resolver),
         {:ok, authorities} <- authorities(Target.authority(target).scheme, trust) do
      {:ok, %{address: address, trust: authorities}}
    end
  end

  @doc false
  def exchange(spec, connection_spec, progress) when is_function(progress, 2) do
    authority = Target.authority(spec.target)
    deadline = Deadline.monotonic_millisecond(spec.deadline)

    {backend, connect_spec} =
      backend(authority, connection_spec.address, connection_spec.trust, progress)

    case progress.(:connect, :not_sent) do
      :ok ->
        case backend.connect(connect_spec, deadline) do
          {:ok, socket} ->
            try do
              exchange_connected(backend, socket, spec, deadline, progress)
            after
              backend.close(socket)
            end

          {:error, reason} ->
            {:error, connect_error(authority.scheme, reason)}
        end

      {:error, _runtime_unavailable} ->
        {:error, :runtime_unavailable}
    end
  end

  defp exchange_connected(backend, socket, spec, deadline, progress) do
    with :ok <- progress.(:send, :possibly_sent),
         :ok <- backend.send(socket, [spec.head, spec.body], deadline),
         :ok <- progress.(:receive_head, :possibly_sent),
         {:ok, response, _socket} <- parse_response(backend, socket, spec, deadline, progress) do
      with :ok <- terminal_progress(response, progress), do: {:ok, response}
    else
      {:error, :timeout} -> {:error, :deadline_exceeded}
      {:error, :closed} -> {:error, :connection_closed}
      {:error, reason, _socket} -> {:error, reason}
      {:error, _reason} -> {:error, :transport_failure}
    end
  end

  defp parse_response(backend, socket, %{streamer: nil} = spec, deadline, progress) do
    Parser.parse(
      backend,
      socket,
      deadline,
      spec.target.max_wire_response_bytes,
      progress
    )
  end

  defp parse_response(backend, socket, %{streamer: streamer} = spec, deadline, progress) do
    consumer = fn bytes, state ->
      case Role.call(streamer.codec_role, fn ->
             {:ok, streamer.consume.(state, bytes, streamer.callback_role)}
           end) do
        {:ok, result} -> result
        _role_failure -> {:error, :internal_failure}
      end
    end

    case Parser.parse_stream(
           backend,
           socket,
           deadline,
           spec.target.max_wire_response_bytes,
           progress,
           streamer.state,
           consumer
         ) do
      {:ok, {:response, response}, socket} ->
        {:ok, response, socket}

      {:ok, {:stream, :halted, state, facts}, socket} ->
        {:ok, {:stream_candidate, streamer.halt.(state, facts)}, socket}

      {:ok, {:stream, :complete, state, facts}, socket} ->
        case Role.call(streamer.codec_role, fn ->
               {:ok, streamer.complete.(state, facts)}
             end) do
          {:ok, {:ok, candidate}} ->
            {:ok, {:stream_candidate, candidate}, socket}

          {:ok, {:error, reason}} ->
            {:error, {:stream, reason, facts.status, :completed}, socket}

          _role_failure ->
            {:error, :internal_failure, socket}
        end

      {:error, reason, socket} ->
        {:error, reason, socket}
    end
  end

  defp terminal_progress({:stream_candidate, _candidate}, progress),
    do: progress.(:stream, :completed)

  defp terminal_progress(_response, progress), do: progress.(:receive_body, :completed)

  defp backend(%{scheme: :http, port: port}, address, _trust, _progress),
    do: {Tcp, %{address: address, port: port}}

  defp backend(%{scheme: :https, host: host, port: port}, address, trust, progress),
    do: {Tls, %{address: address, port: port, hostname: host, trust: trust, progress: progress}}

  defp connect_error(_scheme, :timeout), do: :deadline_exceeded
  defp connect_error(:https, :no_trust_store), do: :tls_failure
  defp connect_error(:https, {:tls, _reason}), do: :tls_failure
  defp connect_error(_scheme, _reason), do: :connect_failure

  defp validate_options(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Enum.all?(Keyword.keys(options), &(&1 in @option_keys)) and
         is_function(Keyword.get(options, :resolver, &Dns.system_resolve/1), 1) and
         is_function(Keyword.get(options, :decoder, fn response -> response end), 1) and
         valid_streamer?(Keyword.get(options, :streamer)) and
         valid_trust?(Keyword.get(options, :trust, :system)) do
      :ok
    else
      :error
    end
  end

  defp valid_streamer?(nil), do: true

  defp valid_streamer?(streamer) when is_map(streamer) do
    Enum.all?([:state, :consume, :complete, :halt], &Map.has_key?(streamer, &1)) and
      is_function(streamer.consume, 3) and is_function(streamer.complete, 2) and
      is_function(streamer.halt, 2)
  end

  defp valid_streamer?(_streamer), do: false

  defp valid_trust?(:system), do: true
  defp valid_trust?([]), do: true
  defp valid_trust?([_ | _] = certificates), do: Enum.all?(certificates, &is_binary/1)
  defp valid_trust?(_trust), do: false

  defp authorities(:http, _trust), do: {:ok, []}
  defp authorities(:https, :system), do: Trust.system_authorities()
  defp authorities(:https, []), do: {:error, :no_trust_store}
  defp authorities(:https, [_ | _] = certificates), do: {:ok, certificates}
end
