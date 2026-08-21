defmodule PtcLlmHttp.Test.Fragmentation do
  @moduledoc false

  # Splits a wire byte stream into the exact chunk sizes a test wants to see
  # arrive, cycling `sizes` until the stream runs out. Fragmentation tables are
  # how parser and transport tests assert that a boundary between two reads
  # never changes the outcome, so both drive the same splitter.

  @spec fragment(binary(), [pos_integer()]) :: [binary()]
  def fragment(binary, sizes), do: fragment(binary, sizes, sizes, [])

  defp fragment(<<>>, _sizes, _original, fragments), do: Enum.reverse(fragments)

  defp fragment(binary, [], original, fragments),
    do: fragment(binary, original, original, fragments)

  defp fragment(binary, [size | sizes], original, fragments) do
    take = min(size, byte_size(binary))
    <<fragment::binary-size(^take), rest::binary>> = binary
    fragment(rest, sizes, original, [fragment | fragments])
  end
end
