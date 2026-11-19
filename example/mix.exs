# Example app built, instrumented and run by the SDK tests (../mix_app_check.exs).
defmodule Shop.MixProject do
  use Mix.Project

  def project do
    [app: :shop, version: "0.1.0", deps: [{:antithesis_elixir, path: "../elixir"}]]
  end

  def application, do: [mod: {Shop.Application, []}]
end
