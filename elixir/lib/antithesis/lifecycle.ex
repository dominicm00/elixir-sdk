defmodule Antithesis.Lifecycle do
  @moduledoc """
  Reports setup completion and named events.

  Omitted or `nil` details are absent from setup records and become `{}` for
  events. Encoded objects pass through; other values are wrapped under `"value"`.
  """

  use Antithesis.FrontEnd

  @doc """
  Indicates that the system and workload are fully initialized. Antithesis
  then takes a snapshot and begins injecting faults.
  """
  defdelegate setup_complete(details \\ nil), to: :antithesis_lifecycle

  @doc "Records a named event with optional details."
  defdelegate send_event(name, details \\ nil), to: :antithesis_lifecycle
end
