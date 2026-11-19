defmodule Antithesis.Random do
  @moduledoc """
  Random values controlled by Antithesis, falling back to `:rand` outside it.

  Consume values immediately rather than caching them or seeding a PRNG,
  so Antithesis can control individual choices.
  """

  use Antithesis.FrontEnd

  @doc "A random unsigned 64-bit integer."
  defdelegate get_random, to: :antithesis_random

  @doc """
  A uniformly random element of `things`. Raises `Enum.EmptyError` on an
  empty list.
  """
  def random_choice([]), do: raise(Enum.EmptyError)
  def random_choice(things) when is_list(things), do: :antithesis_random.random_choice(things)
end
