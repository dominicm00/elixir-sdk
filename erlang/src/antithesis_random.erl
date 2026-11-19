%% Random values controlled by Antithesis, falling back to rand outside it.
%% Consume values immediately rather than caching them or seeding a PRNG,
%% so Antithesis can control individual choices.
-module(antithesis_random).
-antithesis_instrumented(sdk).

-export([get_random/0, random_choice/1]).

-define(U64_MAX, 18446744073709551615).

%% A random unsigned 64-bit integer.
-spec get_random() -> non_neg_integer().
get_random() -> antithesis_sdk:random().

%% A uniformly random element of Things. Raises error:empty_list on [].
-spec random_choice([T, ...]) -> T.
random_choice([]) ->
    error(empty_list);
random_choice([Only]) ->
    Only;
random_choice(Things) when is_list(Things) ->
    Count = length(Things),
    %% Reject the incomplete range to avoid modulo bias.
    Ceiling = (?U64_MAX div Count) * Count,
    lists:nth(draw_below(Ceiling) rem Count + 1, Things).

draw_below(Ceiling) ->
    case get_random() of
        Value when Value >= Ceiling -> draw_below(Ceiling);
        Value -> Value
    end.
