#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

export MIX_ENV=prod

# Minimal-release smoke.
#
# This package is a library and nobody deploys this release. It exists to prove
# two things that only break inside an assembled release: the application boots
# from a generated boot script, and OTP trust material is reachable there. A
# release that starts but cannot produce CA certificates fails every TLS call
# at runtime, which is exactly the failure a library test in the source tree
# cannot see.
mix deps.get --check-locked
mix release --overwrite

"_build/prod/rel/ptc_llm_http/bin/ptc_llm_http" eval '
  {:ok, _} = Application.ensure_all_started(:ptc_llm_http)
  true = is_pid(Process.whereis(PtcLlmHttp.Supervisor))

  {:ok, _} = Application.ensure_all_started(:ssl)
  [_ | _] = :public_key.cacerts_get()

  IO.puts("release smoke: application started, TLS trust store reachable")
'
