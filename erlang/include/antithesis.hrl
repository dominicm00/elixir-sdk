%% Antithesis assertion macros. Messages identify assertions; macros record
%% source locations automatically.
%%
%%     -include_lib("antithesis/include/antithesis.hrl").
%%
%%     ?ALWAYS(Balance >= 0, <<"balance is never negative">>, #{balance => Balance}),
%%     ?SOMETIMES(Retried, <<"a request is retried">>),
%%     ?ALWAYS_LESS_THAN(Latency, 500, <<"latency stays under 500 ms">>).
%%
%% Use binary or string literals for messages so the instrumentor can declare
%% assertions at startup, including those never reached.
%%
%% Set {d, 'NO_ANTITHESIS_ASSERTIONS'} in erl_opts to compile assertions out.
%% They return ok without evaluating arguments or reporting to the SDK.
-ifndef(ANTITHESIS_HRL).
-define(ANTITHESIS_HRL, true).

%% Keep every field literal so the instrumentor can extract the call site.
-define(ANTITHESIS_SITE, {?FILE, ?MODULE_STRING, {?FUNCTION_NAME, ?FUNCTION_ARITY}, ?LINE}).

-ifdef(NO_ANTITHESIS_ASSERTIONS).
%% The unused fun prevents unused-variable warnings for assertion arguments
%% without evaluating them. The compiler removes it.
-define(ANTITHESIS_HIT(Condition, Message, Details, DisplayType),
    begin _ = fun() -> {Condition, Message, Details} end, ok end).

-define(ANTITHESIS_RICH(Kind, Operands, Message, Details),
    begin _ = fun() -> {Operands, Message, Details} end, ok end).
-else.
-define(ANTITHESIS_HIT(Condition, Message, Details, DisplayType),
    antithesis_assert:hit(Condition, Message, Details, ?ANTITHESIS_SITE, DisplayType)).

-define(ANTITHESIS_RICH(Kind, Operands, Message, Details),
    antithesis_assert:rich(Kind, Operands, Message, Details, ?ANTITHESIS_SITE)).
-endif.

%% Condition is true every time this is reached, and it is reached at least once.
-define(ALWAYS(Condition, Message), ?ALWAYS(Condition, Message, undefined)).
-define(ALWAYS(Condition, Message, Details),
    ?ANTITHESIS_HIT(Condition, Message, Details, <<"Always">>)).

%% Condition must be true whenever reached; reaching this assertion is optional.
-define(ALWAYS_OR_UNREACHABLE(Condition, Message), ?ALWAYS_OR_UNREACHABLE(Condition, Message, undefined)).
-define(ALWAYS_OR_UNREACHABLE(Condition, Message, Details),
    ?ANTITHESIS_HIT(Condition, Message, Details, <<"AlwaysOrUnreachable">>)).

%% Condition is true at least once.
-define(SOMETIMES(Condition, Message), ?SOMETIMES(Condition, Message, undefined)).
-define(SOMETIMES(Condition, Message, Details),
    ?ANTITHESIS_HIT(Condition, Message, Details, <<"Sometimes">>)).

%% This line is reached at least once.
-define(REACHABLE(Message), ?REACHABLE(Message, undefined)).
-define(REACHABLE(Message, Details),
    ?ANTITHESIS_HIT(true, Message, Details, <<"Reachable">>)).

%% This line is never reached.
-define(UNREACHABLE(Message), ?UNREACHABLE(Message, undefined)).
-define(UNREACHABLE(Message, Details),
    ?ANTITHESIS_HIT(false, Message, Details, <<"Unreachable">>)).

%% Rich assertions also report operands as guidance toward falsifying always
%% assertions or satisfying sometimes assertions. Left and Right accept numbers,
%% nan, infinity and neg_infinity; they override matching fields in Details.
-define(ALWAYS_GREATER_THAN(Left, Right, Message), ?ALWAYS_GREATER_THAN(Left, Right, Message, undefined)).
-define(ALWAYS_GREATER_THAN(Left, Right, Message, Details),
    ?ANTITHESIS_RICH(always_greater_than, {Left, Right}, Message, Details)).
-define(ALWAYS_GREATER_THAN_OR_EQUAL_TO(Left, Right, Message),
    ?ALWAYS_GREATER_THAN_OR_EQUAL_TO(Left, Right, Message, undefined)).
-define(ALWAYS_GREATER_THAN_OR_EQUAL_TO(Left, Right, Message, Details),
    ?ANTITHESIS_RICH(always_greater_than_or_equal_to, {Left, Right}, Message, Details)).
-define(ALWAYS_LESS_THAN(Left, Right, Message), ?ALWAYS_LESS_THAN(Left, Right, Message, undefined)).
-define(ALWAYS_LESS_THAN(Left, Right, Message, Details),
    ?ANTITHESIS_RICH(always_less_than, {Left, Right}, Message, Details)).
-define(ALWAYS_LESS_THAN_OR_EQUAL_TO(Left, Right, Message),
    ?ALWAYS_LESS_THAN_OR_EQUAL_TO(Left, Right, Message, undefined)).
-define(ALWAYS_LESS_THAN_OR_EQUAL_TO(Left, Right, Message, Details),
    ?ANTITHESIS_RICH(always_less_than_or_equal_to, {Left, Right}, Message, Details)).
-define(SOMETIMES_GREATER_THAN(Left, Right, Message), ?SOMETIMES_GREATER_THAN(Left, Right, Message, undefined)).
-define(SOMETIMES_GREATER_THAN(Left, Right, Message, Details),
    ?ANTITHESIS_RICH(sometimes_greater_than, {Left, Right}, Message, Details)).
-define(SOMETIMES_GREATER_THAN_OR_EQUAL_TO(Left, Right, Message),
    ?SOMETIMES_GREATER_THAN_OR_EQUAL_TO(Left, Right, Message, undefined)).
-define(SOMETIMES_GREATER_THAN_OR_EQUAL_TO(Left, Right, Message, Details),
    ?ANTITHESIS_RICH(sometimes_greater_than_or_equal_to, {Left, Right}, Message, Details)).
-define(SOMETIMES_LESS_THAN(Left, Right, Message), ?SOMETIMES_LESS_THAN(Left, Right, Message, undefined)).
-define(SOMETIMES_LESS_THAN(Left, Right, Message, Details),
    ?ANTITHESIS_RICH(sometimes_less_than, {Left, Right}, Message, Details)).
-define(SOMETIMES_LESS_THAN_OR_EQUAL_TO(Left, Right, Message),
    ?SOMETIMES_LESS_THAN_OR_EQUAL_TO(Left, Right, Message, undefined)).
-define(SOMETIMES_LESS_THAN_OR_EQUAL_TO(Left, Right, Message, Details),
    ?ANTITHESIS_RICH(sometimes_less_than_or_equal_to, {Left, Right}, Message, Details)).

%% NamedBools maps names to booleans. ALWAYS_SOME requires at least one true
%% value on every hit and at least one hit.
-define(ALWAYS_SOME(NamedBools, Message), ?ALWAYS_SOME(NamedBools, Message, undefined)).
-define(ALWAYS_SOME(NamedBools, Message, Details),
    ?ANTITHESIS_RICH(always_some, NamedBools, Message, Details)).
%% SOMETIMES_ALL requires all values to be true together on at least one hit.
-define(SOMETIMES_ALL(NamedBools, Message), ?SOMETIMES_ALL(NamedBools, Message, undefined)).
-define(SOMETIMES_ALL(NamedBools, Message, Details),
    ?ANTITHESIS_RICH(sometimes_all, NamedBools, Message, Details)).

-endif.
