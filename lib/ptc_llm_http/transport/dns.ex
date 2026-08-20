defmodule PtcLlmHttp.Transport.Dns do
  @moduledoc false

  alias PtcLlmHttp.{ConnectPolicy, Limits, Target}

  @maximum_addresses Limits.dns_addresses()

  @type address :: :inet.ip_address()
  @type resolver :: (binary() -> {:ok, [address()]} | {:error, atom()})

  @spec resolve(Target.t(), resolver()) :: {:ok, address()} | {:error, atom()}
  def resolve(target, resolver) when is_function(resolver, 1) do
    authority = Target.authority(target)

    case ConnectPolicy.parse_address(authority.host) do
      {:ok, address} -> authorize([address], Target.connect_policy(target))
      :hostname -> resolve_hostname(authority.host, Target.connect_policy(target), resolver)
    end
  end

  @spec system_resolve(binary()) :: {:ok, [address()]} | {:error, atom()}
  def system_resolve(host) when is_binary(host) do
    host = String.to_charlist(host)

    with {:ok, ipv4} <- family_addresses(host, :inet),
         {:ok, ipv6} <- family_addresses(host, :inet6),
         addresses = Enum.uniq(ipv4 ++ ipv6),
         true <- addresses != [] do
      {:ok, addresses}
    else
      false -> {:error, :nxdomain}
      {:error, reason} -> {:error, reason}
    end
  catch
    _kind, _reason -> {:error, :resolver_failure}
  end

  defp family_addresses(host, family) do
    case :inet.getaddrs(host, family) do
      {:ok, addresses} -> {:ok, addresses}
      {:error, :nxdomain} -> {:ok, []}
      {:error, reason} when is_atom(reason) -> {:error, reason}
    end
  end

  defp resolve_hostname(host, policy, resolver) do
    case invoke_resolver(resolver, host) do
      {:ok, addresses} -> authorize(addresses, policy)
      {:error, reason} -> {:error, reason}
    end
  end

  defp invoke_resolver(resolver, host) do
    case resolver.(host) do
      {:ok, addresses} when is_list(addresses) -> {:ok, addresses}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _invalid -> {:error, :resolver_failure}
    end
  catch
    _kind, _reason -> {:error, :resolver_failure}
  end

  defp authorize([_ | _] = addresses, policy) do
    case Enum.split(addresses, @maximum_addresses) do
      {within_limit, []} ->
        if Enum.all?(within_limit, &valid_allowed?(&1, policy)) do
          {:ok, within_limit |> Enum.uniq() |> Enum.min()}
        else
          {:error, :address_rejected}
        end

      {_maximum, _overflow} ->
        {:error, :address_rejected}
    end
  end

  defp authorize(_addresses, _policy), do: {:error, :address_rejected}

  defp valid_allowed?(address, policy) do
    valid_address?(address) and ConnectPolicy.allowed?(policy, address)
  end

  defp valid_address?({a, b, c, d}),
    do: Enum.all?([a, b, c, d], &is_integer/1) and Enum.all?([a, b, c, d], &(&1 in 0..255))

  defp valid_address?({a, b, c, d, e, f, g, h}) do
    parts = [a, b, c, d, e, f, g, h]
    Enum.all?(parts, &is_integer/1) and Enum.all?(parts, &(&1 in 0..65_535))
  end

  defp valid_address?(_address), do: false
end
