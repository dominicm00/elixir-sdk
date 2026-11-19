defmodule Antithesis.FrontEnd do
  @moduledoc false
  # Persist the SDK marker so the instrumentor skips front-end modules.

  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :antithesis_instrumented, persist: true)
      @antithesis_instrumented :sdk
    end
  end
end
