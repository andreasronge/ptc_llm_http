defmodule PtcLlmHttp.ApplicationTest do
  use ExUnit.Case, async: true

  test "the application is started with its supervisor" do
    assert {:ptc_llm_http, _description, _version} =
             List.keyfind(Application.started_applications(), :ptc_llm_http, 0)

    assert is_pid(Process.whereis(PtcLlmHttp.Supervisor))
  end

  test "the supervisor starts with no children" do
    assert Supervisor.count_children(PtcLlmHttp.Supervisor) == %{
             active: 0,
             specs: 0,
             supervisors: 0,
             workers: 0
           }
  end

  test "TLS trust material is reachable from the running application" do
    assert [_ | _] = :public_key.cacerts_get()
  end
end
