defmodule Shop.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Shop.checkout(apple: 50, pear: 70)
    Antithesis.Lifecycle.setup_complete(%{app: "shop"})
    Supervisor.start_link([], strategy: :one_for_one)
  end
end
