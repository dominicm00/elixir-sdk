%% Shared assertion implementation for Erlang macros and Antithesis.Assert.
%% The macros pass literal metadata to hit/5 and rich/5 so the instrumentor
%% can build a startup catalog, including assertions that are never reached.
%% raw/13, raw/14 and the raw guidance functions accept explicit metadata for
%% framework integrations.
%%
%% Details normalization and serialization are handled by antithesis_details.
%% Numeric operands may be numbers or the atoms nan, infinity and neg_infinity.
-module(antithesis_assert).
-antithesis_instrumented(sdk).

-export([hit/5, rich/5, declare/1, raw/13, raw/14]).
-export([numeric_guidance_raw/11, boolean_guidance_raw/10]).

-type details() :: term().
-type text() :: unicode:chardata() | atom().
%% Literal {File, Module, Function, Line}; names use the source language's spelling.
-type site() :: {text(), text(), text() | {atom(), arity()}, pos_integer()}.
-type display_type() :: binary().
-type number_or_non_finite() :: number() | nan | infinity | neg_infinity.
-type rich_kind() ::
    always_greater_than | always_greater_than_or_equal_to | always_less_than
    | always_less_than_or_equal_to | sometimes_greater_than
    | sometimes_greater_than_or_equal_to | sometimes_less_than
    | sometimes_less_than_or_equal_to | always_some | sometimes_all.
-type operands() :: {number_or_non_finite(), number_or_non_finite()} | #{term() => boolean()}.
%% Literal metadata extracted from a hit/5 or rich/5 call.
-type catalog_entry() :: {hit, text(), site(), display_type()} | {rich, rich_kind(), text(), site()}.

-export_type([details/0, text/0, site/0, rich_kind/0, operands/0, catalog_entry/0]).

%% DisplayType is Always, AlwaysOrUnreachable, Sometimes, Reachable or
%% Unreachable. Message identifies the assertion.
-spec hit(boolean(), text(), details(), site(), display_type()) -> ok.
hit(Condition, Message0, Details, Site, DisplayType) when is_boolean(Condition) ->
    Message = text(Message0),
    unless_emitted(Message, Condition, fun() ->
        {AssertType, MustHit} = display_type(DisplayType),
        emit(Condition, Message, Details, location(Site), true, MustHit, AssertType, DisplayType, Message)
    end).

display_type(<<"Always">>) -> {<<"always">>, true};
display_type(<<"AlwaysOrUnreachable">>) -> {<<"always">>, false};
display_type(<<"Sometimes">>) -> {<<"sometimes">>, true};
display_type(<<"Reachable">>) -> {<<"reachability">>, true};
display_type(<<"Unreachable">>) -> {<<"reachability">>, false}.

%% Assert a numeric comparison or named boolean conditions and emit guidance.
%% Operands override colliding fields in Details.
-spec rich(rich_kind(), operands(), text(), details(), site()) -> ok.
rich(Kind, Operands, Message0, Details, Site) ->
    Message = text(Message0),
    {DisplayType, Maximize, Op} = rich_kind(Kind),
    {AssertType, MustHit} = display_type(DisplayType),
    {Condition, Data} = evaluate(Op, Operands),
    unless_emitted(Message, Condition, fun() ->
        emit(Condition, Message, antithesis_details:merge_guidance(Details, Data), location(Site), true, MustHit,
             AssertType, DisplayType, Message)
    end),
    case Op of
        Boolean when Boolean =:= some; Boolean =:= all ->
            antithesis_guidance:emit(<<"boolean">>, Message, Message, first_location(Message, Site), Maximize,
                                     true, Data);
        _ ->
            {Left, Right} = Operands,
            antithesis_guidance:should_emit_numeric(Message, Maximize, Left, Right) andalso
                antithesis_guidance:emit(<<"numeric">>, Message, Message, first_location(Message, Site), Maximize,
                                         true, Data),
            ok
    end.

%% Return {DisplayType, Maximize, Operator}. Numeric guidance tracks Left - Right:
%% maximize or minimize it to falsify an always assertion or satisfy a sometimes
%% assertion. Boolean guidance uses the same falsify/satisfy distinction.
rich_kind(always_greater_than) -> {<<"Always">>, false, '>'};
rich_kind(always_greater_than_or_equal_to) -> {<<"Always">>, false, '>='};
rich_kind(always_less_than) -> {<<"Always">>, true, '<'};
rich_kind(always_less_than_or_equal_to) -> {<<"Always">>, true, '=<'};
rich_kind(sometimes_greater_than) -> {<<"Sometimes">>, true, '>'};
rich_kind(sometimes_greater_than_or_equal_to) -> {<<"Sometimes">>, true, '>='};
rich_kind(sometimes_less_than) -> {<<"Sometimes">>, false, '<'};
rich_kind(sometimes_less_than_or_equal_to) -> {<<"Sometimes">>, false, '=<'};
rich_kind(always_some) -> {<<"Always">>, false, some};
rich_kind(sometimes_all) -> {<<"Sometimes">>, true, all}.

evaluate(some, NamedBools) when is_map(NamedBools) ->
    {lists:member(true, maps:values(NamedBools)), NamedBools};
evaluate(all, NamedBools) when is_map(NamedBools) ->
    {lists:all(fun(V) -> V =:= true end, maps:values(NamedBools)), NamedBools};
evaluate(Op, {Left, Right}) ->
    {compare(Op, Left, Right), #{<<"left">> => Left, <<"right">> => Right}}.

%% NaN is unordered: all supported comparisons with it are false.
compare(Op, Left, Right) ->
    case {extended(Left), extended(Right)} of
        {nan, _} -> false;
        {_, nan} -> false;
        {L, R} -> erlang:Op(L, R)
    end.

%% Tuple ordering places finite numbers between negative and positive infinity.
extended(nan) -> nan;
extended(neg_infinity) -> {0, 0};
extended(infinity) -> {2, 0};
extended(N) when is_number(N) -> {1, N}.

%% Declare an unhit assertion and, for rich assertions, its guidance point.
-spec declare(catalog_entry()) -> ok.
declare({hit, Message0, Site, DisplayType}) ->
    Message = text(Message0),
    {AssertType, MustHit} = display_type(DisplayType),
    emit(false, Message, undefined, location(Site), false, MustHit, AssertType, DisplayType, Message);
declare({rich, Kind, Message0, Site}) ->
    Message = text(Message0),
    {DisplayType, Maximize, Op} = rich_kind(Kind),
    {AssertType, MustHit} = display_type(DisplayType),
    emit(false, Message, undefined, location(Site), false, MustHit, AssertType, DisplayType, Message),
    Type =
        case Op of
            some -> <<"boolean">>;
            all -> <<"boolean">>;
            _ -> <<"numeric">>
        end,
    antithesis_guidance:emit(Type, Message, Message, first_location(Message, Site), Maximize, false, undefined).

raw(Condition, Message, Details, File, Function, Class, BeginLine, BeginColumn, Hit, MustHit,
    AssertType, DisplayType, Id) ->
    raw(Condition, Message, Details, File, Function, Class, BeginLine, BeginColumn, Hit, MustHit,
        AssertType, DisplayType, Id, undefined).

%% Hit = false declares an assertion without recording an evaluation.
%% For hits, GuidanceData overrides colliding fields in Details.
raw(Condition, Message, Details0, File, Function, Class, BeginLine, BeginColumn, Hit, MustHit,
    AssertType, DisplayType, Id0, GuidanceData) when is_boolean(Condition) ->
    Id = text(Id0),
    Emit = fun() ->
        Details =
            case Hit andalso not antithesis_details:is_absent(GuidanceData) of
                true -> antithesis_details:merge_guidance(Details0, GuidanceData);
                false -> Details0
            end,
        Location = location(File, Function, Class, BeginLine, BeginColumn),
        emit(Condition, text(Message), Details, Location, Hit, MustHit, AssertType, DisplayType, Id)
    end,
    case Hit of
        true -> unless_emitted(Id, Condition, Emit);
        false -> Emit()
    end.

text(Text) when is_binary(Text) -> Text;
text(Text) when is_atom(Text) -> atom_to_binary(Text);
text(Text) ->
    case unicode:characters_to_binary(Text) of
        Binary when is_binary(Binary) -> Binary;
        _ -> error(badarg, [Text])
    end.

%% Emit once per {Id, Condition}. The ETS claim prevents concurrent duplicates;
%% checking membership first avoids writes and packet construction on later hits.
unless_emitted(Id, Condition, Emit) ->
    Table = antithesis_sdk:table(assertions),
    Key = {emitted, Id, Condition},
    case ets:member(Table, Key) orelse not ets:insert_new(Table, {Key}) of
        true -> ok;
        false -> Emit()
    end.

%% Keep the first file and class seen for each Id so declarations and hits
%% agree even when the same message is used at multiple call sites.
first_location(Id, Site) when is_tuple(Site) ->
    first_location(Id, location(Site));
first_location(Id, Location) ->
    Table = antithesis_sdk:table(assertions),
    ets:insert_new(Table, {{location, Id}, maps:get(<<"file">>, Location), maps:get(<<"class">>, Location)}),
    [{_, File, Class}] = ets:lookup(Table, {location, Id}),
    Location#{<<"file">> := File, <<"class">> := Class}.

emit(Condition, Message, Details, Location, Hit, MustHit, AssertType, DisplayType, Id) ->
    Record0 = #{
        <<"condition">> => Condition,
        <<"must_hit">> => MustHit,
        <<"hit">> => Hit,
        <<"id">> => Id,
        <<"message">> => Message,
        <<"display_type">> => DisplayType,
        <<"assert_type">> => AssertType,
        <<"location">> => first_location(Id, Location)
    },
    Record =
        case Hit of
            true -> antithesis_details:put_details(Record0, Details);
            false -> Record0
        end,
    antithesis_details:dispatch(#{<<"antithesis_assert">> => Record}, #{<<"antithesis_assert">> => Record0}, Id).

%% On a hit, report Left and Right only when Left - Right improves the recorded
%% extreme for Id: larger if Maximize, smaller otherwise. Hit = false declares
%% the guidance point.
numeric_guidance_raw(Left, Right, Message, Maximize, File, Function, Class, BeginLine, BeginColumn,
                     Hit, Id0) ->
    Id = text(Id0),
    Location = location(File, Function, Class, BeginLine, BeginColumn),
    case Hit of
        false ->
            antithesis_guidance:emit(<<"numeric">>, Id, text(Message), Location, Maximize, false, undefined);
        true ->
            antithesis_guidance:should_emit_numeric(Id, Maximize, Left, Right) andalso
                antithesis_guidance:emit(<<"numeric">>, Id, text(Message), Location, Maximize, true,
                                         #{<<"left">> => Left, <<"right">> => Right}),
            ok
    end.

%% Report NamedBools on every hit; Hit = false declares the guidance point.
boolean_guidance_raw(NamedBools, Message, Maximize, File, Function, Class, BeginLine, BeginColumn,
                     Hit, Id) ->
    Location = location(File, Function, Class, BeginLine, BeginColumn),
    antithesis_guidance:emit(<<"boolean">>, text(Id), text(Message), Location, Maximize, Hit, NamedBools).

location({File, Class, Function, Line}) ->
    location(text(File), function_text(Function), text(Class), Line, 0).

location(File, Function, Class, BeginLine, BeginColumn) ->
    #{
        <<"file">> => File,
        <<"function">> => Function,
        <<"class">> => Class,
        <<"begin_line">> => BeginLine,
        <<"begin_column">> => BeginColumn
    }.

function_text({Name, Arity}) -> <<(atom_to_binary(Name))/binary, "/", (integer_to_binary(Arity))/binary>>;
function_text(Function) -> text(Function).
