defmodule Antithesis.Lifecycle do
  @moduledoc """
  Reports setup completion and named events.

  Omitted or `nil` details are absent from setup records and become `{}` for
  events. Encoded objects pass through; other values are wrapped under `"value"`.

  With `config :antithesis_elixir, enabled: false`, these functions return
  `:ok` without reporting events or setup completion.
  """

  use Antithesis.FrontEnd

  @enabled Antithesis.FrontEnd.enabled?(__ENV__)

  @doc """
  Indicates that the system and workload are fully initialized. Antithesis
  then takes a snapshot and begins injecting faults.
  """
  if @enabled do
    defdelegate setup_complete(details \\ nil), to: :antithesis_lifecycle
  else
    def setup_complete(_details \\ nil), do: :ok
  end

  @doc "Records a named event with optional details."
  if @enabled do
    defdelegate send_event(name, details \\ nil), to: :antithesis_lifecycle
  else
    def send_event(name, _details \\ nil) when is_binary(name), do: :ok
  end
end
