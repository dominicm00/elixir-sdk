%% Numeric guidance emits only new extremes of Left - Right for each Id.
%% Operands use double precision; overflowing gaps are represented by infinity
%% or neg_infinity because BEAM floats cannot hold them. Boolean guidance emits
%% every hit.
-module(antithesis_guidance).
-antithesis_instrumented(sdk).
-moduledoc false.

-export([should_emit_numeric/4, emit/7]).

%% Reject non-finite operands and integers outside double range with warning
%% 6004. Otherwise, atomically record whether the gap improves the extreme.
should_emit_numeric(Id, Maximize, Left, Right) ->
    case {to_double(Left), to_double(Right)} of
        {L, R} when is_float(L), is_float(R) ->
            improve(antithesis_sdk:table(guidance), Id, Maximize, gap(L, R));
        _ ->
            antithesis_details:warn_once(6004, Id),
            false
    end.

to_double(V) when is_float(V) -> V;
to_double(V) when is_integer(V) ->
    try
        float(V)
    catch
        error:badarg -> non_finite
    end;
to_double(_) ->
    non_finite.

gap(Left, Right) ->
    try
        {finite, Left - Right}
    catch
        error:badarith when Left > Right -> infinity;
        error:badarith -> neg_infinity
    end.

%% The first hit fixes Maximize and always emits. Later hits use compare-and-swap
%% to update the extreme without losing concurrent improvements.
improve(Table, Id, Maximize, Gap) ->
    case ets:lookup(Table, Id) of
        [] ->
            ets:insert_new(Table, {Id, Maximize, Gap}) orelse improve(Table, Id, Maximize, Gap);
        [{Id, Fixed, Mark} = Old] ->
            Better =
                case Fixed of
                    true -> greater(Gap, Mark);
                    false -> greater(Mark, Gap)
                end,
            Better andalso
                (ets:select_replace(Table, [{Old, [], [{{Id, Fixed, {const, Gap}}}]}]) =:= 1 orelse
                    improve(Table, Id, Maximize, Gap))
    end.

greater(Same, Same) -> false;
greater(infinity, _) -> true;
greater(_, infinity) -> false;
greater(neg_infinity, _) -> false;
greater(_, neg_infinity) -> true;
greater({finite, A}, {finite, B}) -> A > B.

emit(Type, Id, Message, Location, Maximize, Hit, Data) ->
    Record0 = #{
        <<"guidance_type">> => Type,
        <<"id">> => Id,
        <<"message">> => Message,
        <<"location">> => Location,
        <<"maximize">> => Maximize,
        <<"hit">> => Hit
    },
    Record =
        case Hit andalso not antithesis_details:is_absent(Data) of
            true -> Record0#{<<"guidance_data">> => Data};
            false -> Record0
        end,
    antithesis_details:dispatch(#{<<"antithesis_guidance">> => Record}, none, Id).
