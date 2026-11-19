defmodule Antithesis.Assert do
  @moduledoc """
  Assertions checked by Antithesis.

  Assertion macros record source locations at compile time. Messages identify
  assertions and must be string literals so the instrumentor can declare them
  at startup, including assertions that are never reached. Conditions use
  Elixir truthiness, as in `if`.

  To disable assertions in a build, set this in its configuration:

      config :antithesis_elixir, assertions: false

  Disabled assertions return `:ok` without evaluating arguments or reporting
  to the SDK. Changing the setting recompiles modules that use the macros.

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

  # The core loads this module before writing its header to identify Elixir.
  @on_load :__antithesis_language__
  @doc false
  def __antithesis_language__ do
    :antithesis_sdk.set_language("Elixir", "#{System.version()} (OTP #{:erlang.system_info(:otp_release)})")
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
    if enabled?(caller) do
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
    if enabled?(caller) do
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

  # Track the caller's config dependency so changes trigger recompilation.
  defp enabled?(caller), do: Application.compile_env(caller, :antithesis_elixir, :assertions, true) != false

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

  @doc """
  On hits, reports `left` and `right` only when `left - right` improves the
  recorded extreme for `id`: larger if `maximize`, smaller otherwise.
  Passing `false` for `hit` declares the guidance point.
  """
  defdelegate numeric_guidance_raw(left, right, message, maximize, file, function, class, begin_line, begin_column, hit, id),
    to: :antithesis_assert

  @doc "Reports `named_bools` on every hit; passing `false` for `hit` declares the guidance point."
  defdelegate boolean_guidance_raw(named_bools, message, maximize, file, function, class, begin_line, begin_column, hit, id),
    to: :antithesis_assert
end
