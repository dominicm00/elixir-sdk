%% Erlang interface to c_src/antithesis_nif.c.
%%
%% If loading fails, hit/3 remains a no-op and the SDK treats available/0's
%% exception as unavailable. It calls output/1 and get_random/0 only after
%% available/0 returns true.
-module(antithesis_nif).
-antithesis_instrumented(sdk).
-moduledoc false.

-export([available/0, output/1, get_random/0, hit/3]).

-on_load(load_nif/0).

load_nif() ->
    Path = filename:join(priv_dir(), "antithesis_nif"),
    case erlang:load_nif(Path, 0) of
        ok ->
            ok;
        {error, {Reason, Text}} ->
            logger:warning("Antithesis SDK NIF not loaded (~p): ~s", [Reason, Text]),
            ok
    end.

priv_dir() ->
    case code:priv_dir(antithesis) of
        {error, _} ->
            %% Support loading via -pa ebin without a registered application directory.
            filename:join(filename:dirname(filename:dirname(code:which(?MODULE))), "priv");
        Dir ->
            Dir
    end.

available() -> erlang:nif_error(not_loaded).

output(_IoData) -> erlang:nif_error(not_loaded).

get_random() -> erlang:nif_error(not_loaded).

hit(_ModuleKey, _EdgeCount, _Edge) -> ok.
