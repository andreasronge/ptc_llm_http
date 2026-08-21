# Started in a fresh OS/BEAM process so OTP's resolver and platform-trust
# cache cannot already be warm. Hostname lookup uses the hosts-file name
# `localhost`; loopback CIDRs are admitted only so the DNS role continues
# through `:public_key.cacerts_get/0` after resolution. The peer port is
# closed, so a surviving DNS role fails at connect rather than sending
# bytes. A second call in the same node covers the warm path. A `:public`
# target then proves resolution still ends in the documented policy
# rejection.

defmodule PtcLlmHttp.Test.ColdHostnameBudgetProbe do
  @moduledoc false

  alias PtcLlmHttp.{
    Credential,
    Deadline,
    ProcessBudget,
    Request,
    ResourceContract,
    Runtime,
    Target
  }

  alias PtcLlmHttp.Test.LoopbackPort

  @loopback_cidrs ["127.0.0.0/8", "::1/128"]

  def main do
    {:ok, _} = Application.ensure_all_started(:ptc_llm_http)
    {:ok, runtime} = Runtime.start_link(max_concurrency: 1, groups: %{"group" => 1})
    hostname_words = ResourceContract.current().process_budget_heap_words.hostname
    {:ok, budget} = ProcessBudget.new(total_heap_words: hostname_words)
    {:ok, request} = Request.new(messages: [%{role: :user, content: "ping"}])
    port = unused_loopback_port()
    allowed = hostname_target(port, {:allow_cidrs, @loopback_cidrs})
    public = hostname_target(port, :public)

    cold = call(runtime, allowed, request, budget)
    warm = call(runtime, allowed, request, budget)
    policy = call(runtime, public, request, budget)

    IO.write(report("COLD", cold) <> report("WARM", warm) <> report("POLICY", policy))

    if connect_refused?(cold) and connect_refused?(warm) and address_rejected?(policy) do
      System.halt(0)
    else
      System.halt(1)
    end
  end

  defp call(runtime, target, request, budget) do
    PtcLlmHttp.call(runtime, target, request,
      credential: Credential.none(),
      deadline: deadline(),
      process_budget: budget
    )
  end

  defp connect_refused?({:error, error}) do
    error.kind == :connect_failure and error.phase == :connect and error.scope == :transport and
      error.dispatch == :not_sent
  end

  defp connect_refused?(_result), do: false

  defp address_rejected?({:error, error}) do
    error.kind == :address_rejected and error.phase == :dns and error.scope == :transport and
      error.dispatch == :not_sent
  end

  defp address_rejected?(_result), do: false

  defp report(label, {:error, error}) do
    "#{label} #{error.kind} #{error.phase} #{error.scope} #{error.dispatch}\n"
  end

  defp report(label, other), do: "#{label} #{inspect(other)}\n"

  defp hostname_target(port, policy) do
    {:ok, target} =
      Target.new(
        kind: :openai_compat,
        base_url: "https://localhost:#{port}",
        model: "model",
        capacity_group: "group",
        connect_policy: policy,
        max_encoded_request_bytes: 1_024,
        max_wire_response_bytes: 1_024,
        tools: false,
        streaming: false,
        structured_output: :unsupported,
        cache_mode: :unsupported,
        upstream_routing: :opaque,
        usage_guarantees: %{tokens: false, cost: false}
      )

    target
  end

  defp deadline do
    {:ok, deadline} = Deadline.new(System.monotonic_time(:millisecond) + 5_000)
    deadline
  end

  defp unused_loopback_port, do: LoopbackPort.unused()
end

PtcLlmHttp.Test.ColdHostnameBudgetProbe.main()
