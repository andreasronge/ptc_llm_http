defmodule PtcLlmHttp.ValueContractsTest do
  use ExUnit.Case, async: true

  alias PtcLlmHttp.{Credential, Deadline, Error, ProcessBudget, ResourceContract}

  describe "Credential" do
    test "accepts no credential and bounded RFC 6750 bearer tokens" do
      assert %Credential{} = Credential.none()
      assert {:ok, credential} = Credential.bearer("sk-private_token+/==")
      assert Credential.kind(credential) == :bearer
    end

    test "rejects empty, oversized, and header-breaking values" do
      assert {:error, %Error{}} = Credential.bearer("")
      assert {:error, %Error{}} = Credential.bearer(:binary.copy("a", 16_377))
      assert {:error, %Error{}} = Credential.bearer("secret\r\nX-Leak: yes")
      assert {:error, %Error{}} = Credential.bearer("token=not-padding")
    end

    test "inspection never reveals the secret" do
      secret = "sentinel-credential"
      assert {:ok, credential} = Credential.bearer(secret)
      inspected = inspect(credential)

      assert inspected == "#PtcLlmHttp.Credential<redacted>"
      refute inspected =~ secret
    end
  end

  describe "Deadline" do
    test "uses only an absolute monotonic millisecond value" do
      absolute = System.monotonic_time(:millisecond) + 10_000
      assert {:ok, deadline} = Deadline.new(absolute)
      assert {:ok, remaining} = Deadline.remaining(deadline)
      assert remaining in 1..10_000
      assert inspect(deadline) == "#PtcLlmHttp.Deadline<redacted>"
    end

    test "returns the closed error once elapsed" do
      assert {:ok, deadline} = Deadline.new(System.monotonic_time(:millisecond))
      assert {:error, %Error{kind: :deadline_exceeded}} = Deadline.remaining(deadline)
      assert {:error, %Error{kind: :invalid_request}} = Deadline.new("wall clock")
    end
  end

  describe "ProcessBudget and ResourceContract" do
    test "accepts both inclusive aggregate endpoints" do
      assert {:ok, minimum} = ProcessBudget.new(total_heap_words: 100_000)
      assert {:ok, maximum} = ProcessBudget.new(total_heap_words: 2_073_600_000)
      assert ProcessBudget.total_heap_words(minimum) == 100_000
      assert ProcessBudget.total_heap_words(maximum) == 2_073_600_000
    end

    test "rejects values outside the range and any role-level option" do
      assert {:error, %Error{kind: :invalid_request}} =
               ProcessBudget.new(total_heap_words: 99_999)

      assert {:error, %Error{kind: :invalid_request}} =
               ProcessBudget.new(total_heap_words: 2_073_600_001)

      assert {:error, %Error{kind: :invalid_request}} =
               ProcessBudget.new(total_heap_words: 1_000_000, socket: :infinity)
    end

    test "the internal partition sums to the exact aggregate" do
      assert {:ok, budget} = ProcessBudget.new(total_heap_words: 100_003)
      partition = ProcessBudget.partition(budget)

      assert Enum.sum(Map.values(partition)) == 100_003
      assert partition.codec == 40_003
    end

    test "publishes only stable integration facts" do
      assert ResourceContract.current() == %{
               version: "resource-v1",
               process_budget_heap_words: %{minimum: 100_000, maximum: 2_073_600_000},
               process_partition_version: "process-v1",
               runtime_control_formula_version: "runtime-control-v1"
             }

      refute inspect(ResourceContract.current()) =~ "socket"
      refute inspect(ResourceContract.current()) =~ "coordinator"
    end
  end

  describe "Error" do
    test "inspection is wholly redacted while fields remain closed facts" do
      error = Error.build!(:capacity_exhausted, :admission, :capacity, :not_sent)
      assert inspect(error) == "#PtcLlmHttp.Error<redacted>"
      assert error.kind == :capacity_exhausted
    end

    test "rejects kind/phase/scope combinations outside the contract" do
      assert {:error, :invalid_error} =
               Error.new(
                 kind: :invalid_credential,
                 phase: :send,
                 scope: :credential,
                 dispatch: :possibly_sent,
                 http_status: nil,
                 provider_code: nil
               )
    end

    test "contract entries are bounded, sorted, and disjoint by stable id" do
      contract = Error.contract()
      entries = contract.entries

      assert contract.version == "error-openai-v1"
      assert Enum.map(entries, & &1.id) == Enum.sort(Enum.map(entries, & &1.id))
      assert length(entries) == length(Enum.uniq_by(entries, & &1.id))

      assert contract.enums.provider_codes == [
               :credit_balance_exhausted,
               :organization_spend_limit_exceeded,
               :organization_usage_limit_exceeded,
               :project_spend_limit_exceeded
             ]

      Enum.each(entries, fn entry ->
        assert entry.kind in contract.enums.kinds
        assert Enum.all?(entry.phases, &(&1 in contract.enums.phases))
        assert Enum.all?(entry.scopes, &(&1 in contract.enums.scopes))
        assert Enum.all?(entry.dispatches, &(&1 in contract.enums.dispatches))
      end)

      assert Enum.sort(Enum.uniq(Enum.map(entries, & &1.kind))) ==
               Enum.sort(contract.enums.kinds)

      Enum.each(entries, fn entry ->
        statuses = if entry.statuses == [], do: [nil], else: Enum.to_list(entry.statuses)
        codes = if entry.provider_codes == [], do: [nil], else: entry.provider_codes

        for phase <- entry.phases,
            scope <- entry.scopes,
            dispatch <- entry.dispatches,
            status <- statuses,
            code <- codes do
          assert {:ok, %Error{}} =
                   Error.new(
                     kind: entry.kind,
                     phase: phase,
                     scope: scope,
                     dispatch: dispatch,
                     http_status: status,
                     provider_code: code
                   )
        end
      end)
    end
  end
end
