defmodule Mix.Tasks.Antithesis.Instrument do
  @shortdoc "Instruments the compiled project for Antithesis"
  @moduledoc """
  Adds coverage probes and an assertion catalog to compiled project and dependency modules.
  The catalog declares assertions at startup, including those never reached.

      MIX_ENV=prod mix antithesis.instrument
      MIX_ENV=prod mix release

  Compiles the project and rewrites `.beam` files under `_build` in place.
  Build the release afterwards to include the instrumented modules. Copy
  the symbol tables from `--symbols` (default: `_build/<env>/antithesis/symbols`)
  to `/symbols` in the image Antithesis runs to map coverage to source.

  After a partial recompile, rerunning this task instruments only changed or
  new modules and writes an additional symbol table. Keep the earlier tables
  for modules that remain instrumented.

  ## Options

    * `--symbols DIR` - output directory for symbol tables
    * `--name NAME` - program name in the symbol table; defaults to the
      project's application name, or the directory name for an umbrella
    * `--skip-dependencies` - instrument only project applications
    * `--no-compile` - skip compilation and instrument existing modules
  """

  use Mix.Task
  use Antithesis.FrontEnd

  if Antithesis.FrontEnd.enabled?(__ENV__) do
    @switches [symbols: :string, name: :string, skip_dependencies: :boolean, compile: :boolean]
    # SDK probes would recurse into the SDK; exclude its applications.
    @sdk [:antithesis, :antithesis_elixir]

    @impl true
    def run(args) do
      {opts, _} = OptionParser.parse!(args, strict: @switches)
      Mix.Task.run(if(Keyword.get(opts, :compile, true), do: "compile", else: "loadpaths"), [])

      build = Mix.Project.build_path()
      deps = if opts[:skip_dependencies], do: [], else: dependency_apps()
      apps = (project_apps() ++ deps) |> Enum.uniq() |> Enum.sort() |> Enum.reject(&(&1 in @sdk))
      dirs = for app <- apps, do: Path.join([build, "lib", to_string(app), "ebin"])

      case Enum.reject(dirs, &File.dir?/1) do
        [] -> :ok
        missing -> Mix.raise("antithesis: not compiled: #{Enum.join(missing, ", ")}")
      end

      symbols = Path.expand(opts[:symbols] || Path.join(build, "antithesis/symbols"))
      name = opts[:name] || default_name()

      case :antithesis_instrument.instrument(Enum.map(dirs, &String.to_charlist/1), %{
             symbols: String.to_charlist(symbols),
             name: String.to_charlist(name)
           }) do
        {:ok, :none, 0} ->
          Mix.shell().info("antithesis: nothing to instrument; every module already is")

        {:ok, key, count} ->
          Mix.shell().info("antithesis: instrumented #{count} edges; symbol table #{Path.join(symbols, key)}.sym.tsv")

        {:error, reason} ->
          Mix.raise("antithesis: #{IO.chardata_to_string(reason)}")
      end
    end

    defp project_apps do
      if Mix.Project.umbrella?(),
        do: Mix.Project.apps_paths() |> Map.keys() |> Enum.sort(),
        else: [Mix.Project.config()[:app]]
    end

    defp dependency_apps do
      for dep <- Mix.Dep.cached(), dep.opts[:app] != false, do: dep.app
    end

    defp default_name do
      if Mix.Project.umbrella?(), do: Path.basename(File.cwd!()), else: to_string(Mix.Project.config()[:app])
    end
  else
    @impl true
    def run(_args),
      do: Mix.raise("antithesis: the SDK is disabled by config :antithesis_elixir, enabled: false")
  end
end
