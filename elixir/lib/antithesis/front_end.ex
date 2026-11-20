defmodule Antithesis.FrontEnd do
  @moduledoc false
  # Persist the SDK marker so the instrumentor skips front-end modules.

  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :antithesis_instrumented, persist: true)
      @antithesis_instrumented :sdk
    end
  end

  @doc """
  Reads the compile-time `:enabled` flag, defaulting to `true`.

  Use the result in a module-level `if` to exclude references to the Erlang
  core from disabled builds.

  Pass `__ENV__` in module bodies or `__CALLER__` in macros to track the
  config dependency for recompilation.
  """
  @spec enabled?(Macro.Env.t()) :: boolean()
  def enabled?(env) do
    case Application.compile_env(env, :antithesis_elixir, :enabled, true) do
      enabled when is_boolean(enabled) ->
        enabled

      other ->
        raise ArgumentError, "config :antithesis_elixir, enabled: must be a boolean, got: #{inspect(other)}"
    end
  end
end
