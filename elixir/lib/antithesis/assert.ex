defmodule Antithesis.Assert do
  @moduledoc """
  Assertions checked by Antithesis.

  Assertion macros record source locations at compile time. Messages identify
  assertions and must be string literals so the instrumentor can declare them
  at startup, including assertions that are never reached. Conditions use
  Elixir truthiness, as in `if`.

  Disable the SDK through compile-time configuration:

      config :antithesis_elixir, enabled: false

  Disabled builds omit the Erlang core and NIF. Assertion macros return `:ok`
  without evaluating arguments. Raw assertion and guidance functions and
  `Antithesis.Lifecycle` return `:ok`; `Antithesis.Random` uses `:rand`.
  Changing this setting recompiles the SDK and macro callers. It cannot be
  set in `config/runtime.exs`.

  Rich assertions report operands as guidance toward falsifying `always`
  assertions or satisfying `sometimes` assertions. Operands override matching
  fields in `details`.

  Framework integrations can use `raw/14` and the raw guidance functions to
  supply explicit assertion metadata.

  `details` accepts JSON-encodable values, including structs implementing
  `JSON.Encoder`. Encoded objects pass through; other values are wrapped under
  `"value"`. `nil` omits details. In details and numeric operands, use `:nan`,
  `:infinity` and `:neg_infinity` for non-finite floats, which BEAM cannot
  represent directly.
  """

  use Antithesis.FrontEnd

  @enabled Antithesis.FrontEnd.enabled?(__ENV__)

  if @enabled do
    # The core loads this module before writing its header to identify Elixir.
    @on_load :__antithesis_language__
    @doc false
    def __antithesis_language__ do
      :antithesis_sdk.set_language("Elixir", "#{System.version()} (OTP #{:erlang.system_info(:otp_release)})")
    end
  end

  @doc """
  Asserts that `condition` is true every time this is reached, and that it is
  reached at least once.
  """
  defmacro always(condition, message, details \\ nil),
    do: hit(__CALLER__, condition, message, details, "Always")

  @doc "Asserts that `condition` is true whenever reached; reaching this assertion is optional."
  defmacro always_or_unreachable(condition, message, details \\ nil),
    do: hit(__CALLER__, condition, message, details, "AlwaysOrUnreachable")

  @doc "Asserts that `condition` is true at least once."
  defmacro sometimes(condition, message, details \\ nil),
    do: hit(__CALLER__, condition, message, details, "Sometimes")

  @doc "Asserts that this line is reached at least once."
  defmacro reachable(message, details \\ nil),
    do: hit(__CALLER__, true, message, details, "Reachable")

  @doc "Asserts that this line is never reached."
  defmacro unreachable(message, details \\ nil),
    do: hit(__CALLER__, false, message, details, "Unreachable")

  for {kind, comparison, quantifier} <- [
        {:always_greater_than, ">", "every time this is reached"},
        {:always_greater_than_or_equal_to, ">=", "every time this is reached"},
        {:always_less_than, "<", "every time this is reached"},
        {:always_less_than_or_equal_to, "<=", "every time this is reached"},
        {:sometimes_greater_than, ">", "at least once"},
        {:sometimes_greater_than_or_equal_to, ">=", "at least once"},
        {:sometimes_less_than, "<", "at least once"},
        {:sometimes_less_than_or_equal_to, "<=", "at least once"}
      ] do
    @doc "Asserts that `left #{comparison} right` holds #{quantifier} and reports both operands as guidance."
    defmacro unquote(kind)(left, right, message, details \\ nil),
      do: rich(__CALLER__, unquote(kind), {left, right}, message, details)
  end

  @doc """
  Asserts that at least one named condition is true on every hit and that
  this assertion is reached at least once. `named_bools` accepts a map or
  keyword list of names to conditions; each is reported as guidance.
  """
  defmacro always_some(named_bools, message, details \\ nil),
    do: rich(__CALLER__, :always_some, named_bools(named_bools), message, details)

  @doc """
  Asserts that all named conditions are true together on at least one hit.
  Accepts the same inputs and reports guidance as `always_some/3`.
  """
  defmacro sometimes_all(named_bools, message, details \\ nil),
    do: rich(__CALLER__, :sometimes_all, named_bools(named_bools), message, details)

  defp hit(caller, condition, message, details, display_type) do
    if Antithesis.FrontEnd.enabled?(caller) do
      hit_call(caller, condition, message, details, display_type)
    else
      compiled_out(caller, message, [condition, details])
    end
  end

  defp hit_call(caller, condition, message, details, display_type) do
    quote do
      :antithesis_assert.hit(
        Antithesis.Assert.truthy(unquote(condition)),
        unquote(literal!(caller, message)),
        unquote(details),
        unquote(Macro.escape(site(caller))),
        unquote(display_type)
      )
    end
  end

  defp rich(caller, kind, operands, message, details) do
    if Antithesis.FrontEnd.enabled?(caller) do
      rich_call(caller, kind, operands, message, details)
    else
      compiled_out(caller, message, [operands, details])
    end
  end

  defp rich_call(caller, kind, operands, message, details) do
    quote do
      :antithesis_assert.rich(
        unquote(kind),
        unquote(operands),
        unquote(literal!(caller, message)),
        unquote(details),
        unquote(Macro.escape(site(caller)))
      )
    end
  end

  # The unused fun prevents unused-variable warnings without evaluating
  # assertion arguments. The compiler removes it.
  defp compiled_out(caller, message, args) do
    literal!(caller, message)

    quote generated: true do
      _ = fn -> {unquote_splicing(args)} end
      :ok
    end
  end

  defp named_bools(named_bools), do: quote(do: Antithesis.Assert.bools(unquote(named_bools)))

  defp literal!(_caller, message) when is_binary(message), do: message

  defp literal!(caller, _message) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "Antithesis assertion messages must be string literals"
  end

  defp site(caller) do
    module = if caller.module, do: inspect(caller.module), else: ""
    {Path.relative_to_cwd(caller.file), module, caller.function || "", caller.line}
  end

  @doc false
  def truthy(value), do: value != false and value != nil

  @doc false
  def bools(named_bools), do: Map.new(named_bools, fn {name, value} -> {name, truthy(value)} end)

  @doc """
  Reports an assertion with explicit metadata for framework integrations.
  `condition` uses Elixir truthiness.

  Passing `false` for `hit` declares the assertion without recording an
  evaluation. On hits, `guidance_data` overrides matching fields in `details`.
  """
  if @enabled do
    def raw(
          condition,
          message,
          details,
          file,
          function,
          class,
          begin_line,
          begin_column,
          hit,
          must_hit,
          assert_type,
          display_type,
          id,
          guidance_data \\ nil
        ),
        do:
          :antithesis_assert.raw(
            truthy(condition),
            message,
            details,
            file,
            function,
            class,
            begin_line,
            begin_column,
            hit,
            must_hit,
            assert_type,
            display_type,
            id,
            guidance_data
          )
  else
    def raw(
          _condition,
          _message,
          _details,
          _file,
          _function,
          _class,
          _begin_line,
          _begin_column,
          _hit,
          _must_hit,
          _assert_type,
          _display_type,
          _id,
          _guidance_data \\ nil
        ),
        do: :ok
  end

  @doc """
  On hits, reports `left` and `right` only when `left - right` improves the
  recorded extreme for `id`: larger if `maximize`, smaller otherwise.
  Passing `false` for `hit` declares the guidance point.
  """
  if @enabled do
    defdelegate numeric_guidance_raw(left, right, message, maximize, file, function, class, begin_line, begin_column, hit, id),
      to: :antithesis_assert
  else
    def numeric_guidance_raw(_left, _right, _message, _maximize, _file, _function, _class, _begin_line, _begin_column, _hit, _id),
      do: :ok
  end

  @doc "Reports `named_bools` on every hit; passing `false` for `hit` declares the guidance point."
  if @enabled do
    defdelegate boolean_guidance_raw(named_bools, message, maximize, file, function, class, begin_line, begin_column, hit, id),
      to: :antithesis_assert
  else
    def boolean_guidance_raw(_named_bools, _message, _maximize, _file, _function, _class, _begin_line, _begin_column, _hit, _id),
      do: :ok
  end
end
