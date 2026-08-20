defmodule PtcLlmHttp.Application do
  @moduledoc """
  OTP application for `PtcLlmHttp`.

  The supervision tree is deliberately empty. A `PtcLlmHttp.Runtime` owns
  physical connection admission and is started by the consumer under the
  consumer's own supervisor, so that capacity dies with the application that
  configured it rather than with this library's lifecycle. This supervisor
  exists as the owner for future package-internal backend processes only.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: PtcLlmHttp.Supervisor)
  end
end
