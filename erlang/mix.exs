defmodule Antithesis.MixProject do
  use Mix.Project

  # Share application metadata with rebar3 via src/antithesis.app.src.
  @app (
         {:ok, [{:application, :antithesis, props}]} =
           :file.consult(String.to_charlist(Path.join(__DIR__, "src/antithesis.app.src")))

         props
       )

  def project do
    [
      app: :antithesis,
      version: to_string(@app[:vsn]),
      erlc_paths: ["src"],
      erlc_include_path: "include",
      compilers: [:antithesis_nif | Mix.compilers()],
      description: to_string(@app[:description]),
      package: [licenses: ["MIT"], files: ~w(src include c_src Makefile rebar.config mix.exs)]
    ]
  end

  def application, do: Keyword.take(@app, [:mod, :registered, :applications, :env])
end

defmodule Mix.Tasks.Compile.AntithesisNif do
  @moduledoc false
  # Build into the priv directory returned by code:priv_dir(antithesis).
  use Mix.Task.Compiler

  @impl true
  def run(_args) do
    nif = Path.join(Mix.Project.app_path(), "priv/antithesis_nif.so")
    make = ["--no-print-directory", "-C", __DIR__, "NIF=#{nif}", nif]

    case System.cmd("make", make, stderr_to_stdout: true) do
      {_, 0} -> {:ok, []}
      {output, _} -> Mix.raise("antithesis: building the NIF failed:\n" <> output)
    end
  end
end
