%% Details serialization and diagnostics for assertion, guidance and lifecycle
%% packets. See sdk/conformance/README.md, "Details".
%%
%% BEAM cannot represent non-finite floats. The atoms nan, infinity and
%% neg_infinity encode as "NaN", "Infinity" and "-Infinity" with warning 6002.
%% Both null and Elixir's nil encode as JSON null.
-module(antithesis_details).
-antithesis_instrumented(sdk).
-moduledoc false.

-export([is_absent/1, details_object/1, merge_guidance/2, put_details/2, dispatch/3, warn_once/2]).

%% Defer caller serialization to dispatch so failures and warnings are handled
%% there. A custom encoder's output determines wrapping and guidance merging.
-record(details, {value :: term(), guidance = #{} :: map()}).
-opaque object() :: #details{}.
-export_type([object/0]).

%% First magnitude outside JavaScript's safe integer range. Not all integers
%% at or above this magnitude can be represented exactly as doubles.
-define(UNSAFE_INTEGER, 9007199254740992).
-define(CODES_KEY, {?MODULE, codes}).

is_absent(undefined) -> true;
is_absent(nil) -> true;
is_absent(_) -> false.

%% Defer normalization: encoded objects pass through; other values are wrapped
%% under "value". This does not invoke custom encoders.
-spec details_object(term()) -> object().
details_object(#details{} = Details) -> Details;
details_object(Details) -> #details{value = Details}.

%% Guidance overrides matching JSON field names after custom encoding.
%% Absent details contribute no fields.
-spec merge_guidance(term(), map()) -> object().
merge_guidance(Details, Guidance) ->
    Object = details_object(case is_absent(Details) of true -> #{}; false -> Details end),
    Object#details{guidance = Guidance}.

normalize_object(#{'__struct__' := _} = Struct, Encode) ->
    %% Decode the protocol's JSON iodata to inspect its shape without
    %% invoking the custom encoder twice.
    object_value(json:decode(iolist_to_binary(Encode(Struct, Encode))));
normalize_object(Value, _Encode) ->
    object_value(Value).

object_value(Value) when is_map(Value) -> json_keys(Value);
object_value(Value) -> #{<<"value">> => Value}.

json_keys(Map) ->
    maps:from_list([{json_key(Key), Value} || Key := Value <- Map]).

%% Match the key spellings accepted by OTP's json:encode_map/2.
json_key(Key) when is_binary(Key) -> Key;
json_key(Key) when is_atom(Key) -> atom_to_binary(Key);
json_key(Key) when is_integer(Key) -> integer_to_binary(Key);
json_key(Key) when is_float(Key) -> iolist_to_binary(json:encode_float(Key)).

%% Omit absent details; defer normalization of other values to dispatch.
put_details(Record, Details) ->
    case is_absent(Details) of
        true -> Record;
        false -> Record#{<<"details">> => details_object(Details)}
    end.

%% Serialize Packet and emit its diagnostics. On failure, emit error 6001 and
%% Fallback without caller details, or no replacement packet if Fallback = none.
-spec dispatch(map(), map() | none, binary()) -> ok.
dispatch(Packet, Fallback, Context) ->
    put(?CODES_KEY, []),
    Result =
        try
            {ok, json:encode(Packet, fun encode/2)}
        catch
            Class:Reason -> {error, failure_reason(Class, Reason)}
        end,
    Codes = erase(?CODES_KEY),
    case Result of
        {ok, IoData} ->
            [warn_once(Code, Context) || Code <- lists:usort(Codes)],
            antithesis_sdk:output(IoData);
        {error, Text} ->
            antithesis_sdk:output(
                diagnostic(
                    <<"antithesis_error">>,
                    6001,
                    <<(language())/binary, " SDK failed to serialize details for \"", Context/binary,
                        "\": ", Text/binary>>,
                    Context
                )
            ),
            Fallback =:= none orelse output_fallback(Fallback)
    end,
    ok.

%% Fallback text fields also come from the caller. Drop an unserializable
%% fallback rather than propagating the error.
output_fallback(Packet) ->
    try json:encode(Packet, fun encode/2) of
        IoData -> antithesis_sdk:output(IoData)
    catch
        _:_ -> ok
    end.

failure_reason(error, #{'__exception__' := true} = Exception) ->
    nonempty('Elixir.Exception':message(Exception));
failure_reason(error, {unsupported_type, Value}) ->
    iolist_to_binary(io_lib:format("~0tP cannot be encoded as JSON", [Value, 5]));
failure_reason(Class, Reason) ->
    nonempty(iolist_to_binary(io_lib:format("~0tp", [{Class, Reason}]))).

nonempty(<<>>) -> <<"unserializable value">>;
nonempty(Text) -> Text.

%% Collect warning codes during serialization; dispatch emits them on success.
encode(Value, _Encode) when is_integer(Value) ->
    abs(Value) >= ?UNSAFE_INTEGER andalso note(6003),
    json:encode_integer(Value);
encode(nan, _Encode) ->
    note(6002),
    json:encode_binary(<<"NaN">>);
encode(infinity, _Encode) ->
    note(6002),
    json:encode_binary(<<"Infinity">>);
encode(neg_infinity, _Encode) ->
    note(6002),
    json:encode_binary(<<"-Infinity">>);
encode(nil, _Encode) ->
    <<"null">>;
encode(#details{value = Value, guidance = Guidance}, Encode) ->
    Object = maps:merge(normalize_object(Value, Encode), json_keys(Guidance)),
    json:encode_map(Object, Encode);
encode(#{'__struct__' := _} = Struct, Encode) ->
    %% Pass this hook to the protocol so nested values receive the same
    %% normalization and diagnostics.
    'Elixir.JSON.Encoder':encode(Struct, Encode);
encode(Value, Encode) when is_map(Value) ->
    json:encode_map(Value, Encode);
encode(Value, Encode) when is_list(Value) ->
    json:encode_list(Value, Encode);
encode(Value, Encode) when is_atom(Value); is_binary(Value); is_float(Value) ->
    json:encode_value(Value, Encode);
encode(Value, _Encode) ->
    error({unsupported_type, Value}).

note(Code) ->
    case get(?CODES_KEY) of
        Codes when is_list(Codes) -> put(?CODES_KEY, [Code | Codes]);
        undefined -> ok
    end.

warn_once(Code, Context) ->
    case antithesis_sdk:claim_warning(Code) of
        true ->
            Message = <<(warning_text(Code, Context))/binary,
                "; later occurrences in this process are not reported">>,
            antithesis_sdk:output(diagnostic(<<"antithesis_warning">>, Code, Message, Context));
        false ->
            ok
    end,
    ok.

warning_text(6002, Context) ->
    <<(language())/binary, " SDK replaced non-finite numbers in details for \"", Context/binary,
        "\" with the strings \"NaN\", \"Infinity\" or \"-Infinity\"">>;
warning_text(6003, Context) ->
    <<(language())/binary, " SDK emitted integers beyond ±2^53 in details for \""/utf8, Context/binary,
        "\"; consumers that parse JSON numbers as doubles will round them">>;
warning_text(6004, Context) ->
    <<(language())/binary, " SDK skipped numeric guidance for \"", Context/binary,
        "\" because an operand was not finite">>.

language() -> antithesis_sdk:language().

diagnostic(Kind, Code, Message, Context) ->
    json:encode(#{Kind => #{<<"code">> => Code, <<"message">> => Message, <<"context">> => Context}}).
