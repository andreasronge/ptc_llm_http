defmodule PtcLlmHttp.ConnectPolicy do
  @moduledoc false

  import Bitwise

  alias PtcLlmHttp.Limits

  @type address :: :inet.ip_address()
  @type compiled :: :public | :literal_loopback | {:allow_cidrs, [cidr()]}
  @type cidr :: {:ipv4 | :ipv6, non_neg_integer(), non_neg_integer()}

  @allocated_2001_ranges [
    0x0200..0x03FF,
    0x0400..0x05FF,
    0x0600..0x07FF,
    0x0800..0x0BFF,
    0x0C00..0x0DFF,
    0x0E00..0x0FFF,
    0x1200..0x13FF,
    0x1400..0x17FF,
    0x1800..0x19FF,
    0x1A00..0x1BFF,
    0x1C00..0x1FFF,
    0x2000..0x3FFF,
    0x4000..0x41FF,
    0x4200..0x43FF,
    0x4400..0x45FF,
    0x4600..0x47FF,
    0x4800..0x49FF,
    0x4A00..0x4BFF,
    0x4C00..0x4DFF,
    0x5000..0x5FFF,
    0x8000..0x9FFF,
    0xA000..0xAFFF,
    0xB000..0xBFFF
  ]

  def compile(:public, :https, host) do
    case parse_address(host) do
      {:ok, _literal} -> {:error, :https_ip_literal}
      :hostname -> {:ok, :public}
    end
  end

  def compile(:literal_loopback, :http, host) do
    with {:ok, address} <- parse_address(host),
         true <- loopback?(address) do
      {:ok, :literal_loopback}
    else
      _invalid -> {:error, :invalid_literal_loopback}
    end
  end

  def compile({:allow_cidrs, cidrs}, :https, host) when is_list(cidrs) do
    with :hostname <- parse_address(host),
         true <- cidrs != [] and length(cidrs) <= Limits.connect_policy_cidrs(),
         {:ok, compiled} <- compile_cidrs(cidrs) do
      {:ok, {:allow_cidrs, compiled}}
    else
      _invalid -> {:error, :invalid_cidrs}
    end
  end

  def compile(_policy, _scheme, _host), do: {:error, :invalid_connect_policy}

  def allowed?(:public, address), do: public?(address)
  def allowed?(:literal_loopback, address), do: loopback?(address)

  def allowed?({:allow_cidrs, cidrs}, address) do
    Enum.any?(cidrs, &contains?(&1, address))
  end

  def literal?(host), do: match?({:ok, _address}, parse_address(host))

  def parse_address(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> {:ok, address}
      {:error, :einval} -> :hostname
    end
  end

  defp compile_cidrs(cidrs) do
    Enum.reduce_while(cidrs, {:ok, []}, fn cidr, {:ok, compiled} ->
      case compile_cidr(cidr) do
        {:ok, value} -> {:cont, {:ok, [value | compiled]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, compiled} -> {:ok, Enum.reverse(compiled)}
      error -> error
    end
  end

  defp compile_cidr(cidr) when is_binary(cidr) do
    case String.split(cidr, "/", parts: 2) do
      [address_text, prefix_text] ->
        with {:ok, address} <- literal_address(address_text),
             {prefix, ""} <- Integer.parse(prefix_text),
             {family, bits, integer} <- address_integer(address),
             true <- prefix in 1..bits,
             mask <- mask(bits, prefix),
             true <- band(integer, mask) == integer do
          {:ok, {family, integer, prefix}}
        else
          _invalid -> {:error, :invalid_cidr}
        end

      _invalid ->
        {:error, :invalid_cidr}
    end
  end

  defp compile_cidr(_cidr), do: {:error, :invalid_cidr}

  defp literal_address(text) do
    case parse_address(text) do
      {:ok, address} -> {:ok, address}
      :hostname -> {:error, :invalid_cidr}
    end
  end

  defp contains?({family, network, prefix}, address) do
    case address_integer(address) do
      {^family, bits, integer} -> band(integer, mask(bits, prefix)) == network
      {_other_family, _bits, _integer} -> false
    end
  end

  defp mask(_bits, 0), do: 0
  defp mask(bits, prefix), do: ((1 <<< prefix) - 1) <<< (bits - prefix)

  defp address_integer({a, b, c, d}) do
    {:ipv4, 32, (a <<< 24) + (b <<< 16) + (c <<< 8) + d}
  end

  defp address_integer({a, b, c, d, e, f, g, h}) do
    integer =
      Enum.reduce([a, b, c, d, e, f, g, h], 0, fn part, value ->
        (value <<< 16) + part
      end)

    {:ipv6, 128, integer}
  end

  defp loopback?({127, _b, _c, _d}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_address), do: false

  # This is deliberately conservative. A target that needs a special-purpose
  # address must name an explicit CIDR policy; public authority is never
  # inferred from an address merely because the local host can route to it.
  defp public?({0, _b, _c, _d}), do: false
  defp public?({10, _b, _c, _d}), do: false
  defp public?({100, b, _c, _d}) when b in 64..127, do: false
  defp public?({127, _b, _c, _d}), do: false
  defp public?({169, 254, _c, _d}), do: false
  defp public?({172, b, _c, _d}) when b in 16..31, do: false
  defp public?({192, 0, 0, d}) when d in [9, 10], do: true
  defp public?({192, 0, 0, _d}), do: false
  defp public?({192, 0, 2, _d}), do: false
  defp public?({192, 88, 99, _d}), do: false
  defp public?({192, 168, _c, _d}), do: false
  defp public?({198, b, _c, _d}) when b in 18..19, do: false
  defp public?({198, 51, 100, _d}), do: false
  defp public?({203, 0, 113, _d}), do: false
  defp public?({a, _b, _c, _d}) when a >= 224, do: false
  defp public?({_a, _b, _c, _d}), do: true

  defp public?({0x0064, 0xFF9B, 0, 0, 0, 0, _g, _h}), do: true

  defp public?({a, _b, _c, _d, _e, _f, _g, _h}) when a < 0x2000 or a > 0x3FFF,
    do: false

  defp public?({0x2001, 0x0001, 0, 0, 0, 0, 0, h}) when h in 1..3, do: true
  defp public?({0x2001, 0x0003, _c, _d, _e, _f, _g, _h}), do: true
  defp public?({0x2001, 0x0004, 0x0112, _d, _e, _f, _g, _h}), do: true
  defp public?({0x2001, b, _c, _d, _e, _f, _g, _h}) when b in 0x0020..0x003F, do: true
  defp public?({0x2001, b, _c, _d, _e, _f, _g, _h}) when b < 0x0200, do: false
  defp public?({0x2001, 0x0DB8, _c, _d, _e, _f, _g, _h}), do: false
  defp public?({0x2001, b, _c, _d, _e, _f, _g, _h}), do: allocated_2001?(b)
  defp public?({0x2002, _b, _c, _d, _e, _f, _g, _h}), do: false
  defp public?({0x2003, b, _c, _d, _e, _f, _g, _h}) when b < 0x4000, do: true
  defp public?({a, _b, _c, _d, _e, _f, _g, _h}) when a in 0x2400..0x241F, do: true
  defp public?({a, _b, _c, _d, _e, _f, _g, _h}) when a in 0x2600..0x260F, do: true
  defp public?({0x2610, b, _c, _d, _e, _f, _g, _h}) when b < 0x0200, do: true
  defp public?({0x2620, b, _c, _d, _e, _f, _g, _h}) when b < 0x0200, do: true
  defp public?({a, _b, _c, _d, _e, _f, _g, _h}) when a in 0x2630..0x263F, do: true
  defp public?({a, _b, _c, _d, _e, _f, _g, _h}) when a in 0x2800..0x280F, do: true
  defp public?({a, _b, _c, _d, _e, _f, _g, _h}) when a in 0x2A00..0x2A1F, do: true
  defp public?({a, _b, _c, _d, _e, _f, _g, _h}) when a in 0x2C00..0x2C0F, do: true
  defp public?({_a, _b, _c, _d, _e, _f, _g, _h}), do: false

  defp public?(_address), do: false

  defp allocated_2001?(part), do: Enum.any?(@allocated_2001_ranges, &(part in &1))
end
