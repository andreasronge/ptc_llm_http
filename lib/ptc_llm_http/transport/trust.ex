defmodule PtcLlmHttp.Transport.Trust do
  @moduledoc false

  # The HTTP runtime invokes this inside its registered DNS role. That role is
  # heap-bounded and killed with the attempt at the absolute deadline, so trust
  # loading needs no helper process that could escape the attempt tree.
  @doc false
  def system_authorities(loader \\ &:public_key.cacerts_get/0) when is_function(loader, 0) do
    case loader.() do
      [_ | _] = cacerts -> {:ok, cacerts}
      _missing_or_invalid -> {:error, :no_trust_store}
    end
  catch
    _kind, _unreadable_store -> {:error, :no_trust_store}
  end
end
