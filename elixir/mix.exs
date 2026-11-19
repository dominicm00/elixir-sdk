defmodule Antithesis.Elixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :antithesis_elixir,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:antithesis, path: "../erlang"}],
      description: "The Antithesis SDK for Elixir: a front end over the Erlang core",
      package: [licenses: ["MIT"], files: ~w(lib mix.exs)]
    ]
  end
end
