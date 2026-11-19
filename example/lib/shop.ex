defmodule Shop do
  require Antithesis.Assert, as: Assert

  def checkout(cart) do
    total = Enum.reduce(cart, 0, fn {_item, price}, acc -> acc + price end)
    Assert.always(total >= 0, "cart total is never negative", %{total: total})
    Assert.always_less_than(total, 1000, "cart total stays under 1000")
    if total > 100, do: Assert.sometimes(true, "a big order is placed")
    total
  end

  def refund, do: Assert.unreachable("refunds never happen")
end
