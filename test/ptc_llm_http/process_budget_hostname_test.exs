defmodule PtcLlmHttp.ProcessBudgetHostnameTest do
  use ExUnit.Case, async: false

  @probe Path.expand("../../scripts/cold_hostname_budget.exs", __DIR__)

  test "the documented hostname budget survives cold and warm resolution in a fresh OS process" do
    {output, status} = run_probe()

    assert status == 0, output
    assert output =~ "COLD connect_failure connect transport not_sent"
    assert output =~ "WARM connect_failure connect transport not_sent"
    assert output =~ "POLICY address_rejected dns transport not_sent"
  end

  defp run_probe do
    elixir = System.find_executable("elixir") || flunk("elixir is not on PATH")

    System.cmd(
      elixir,
      [@probe],
      env: [{"ERL_LIBS", Path.join(Mix.Project.build_path(), "lib")}],
      stderr_to_stdout: true
    )
  end
end
