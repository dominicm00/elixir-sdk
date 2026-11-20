defmodule Antithesis.Random do
  @moduledoc """
  Random values controlled by Antithesis, falling back to `:rand` outside it.

  Consume values immediately rather than caching them or seeding a PRNG,
  so Antithesis can control individual choices.

  With `config :antithesis_elixir, enabled: false`, randomness comes from `:rand`.
  """

  use Antithesis.FrontEnd

  @enabled Antithesis.FrontEnd.enabled?(__ENV__)

  @doc "A random unsigned 64-bit integer."
  if @enabled do
    defdelegate get_random, to: :antithesis_random
  else
    def get_random, do: :rand.uniform(0x1_0000_0000_0000_0000) - 1
  end

  @doc """
  A uniformly random element of `things`. Raises `Enum.EmptyError` on an
  empty list.
  """
  def random_choice([]), do: raise(Enum.EmptyError)

  if @enabled do
    def random_choice(things) when is_list(things), do: :antithesis_random.random_choice(things)
  else
    def random_choice(things) when is_list(things), do: Enum.random(things)
  end
end
