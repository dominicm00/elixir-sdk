defmodule Antithesis.Elixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :antithesis_elixir,
      version: "0.2.0",
      elixir: "~> 1.18",
      deps: deps(),
      description: "The Antithesis SDK for Elixir: a front end over the Erlang core",
      package: [licenses: ["MIT"], files: ~w(lib mix.exs)]
    ]
  end

  # Mix loads the parent project's config before evaluating this dependency.
  # Omitting the core also excludes its NIF from compilation and the release.
  defp deps do
    if Application.get_env(:antithesis_elixir, :enabled, true),
      do: [{:antithesis, path: "../erlang"}],
      else: []
  end
end
