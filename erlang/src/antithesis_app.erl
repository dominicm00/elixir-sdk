%% Initialize the SDK at application startup to emit the header and catalog.
%% Without this application, the SDK initializes on its first call.
-module(antithesis_app).
-antithesis_instrumented(sdk).
-moduledoc false.

-behaviour(application).
-behaviour(supervisor).

-export([start/2, stop/1, init/1]).

start(_Type, _Args) ->
    ok = antithesis_sdk:start(),
    supervisor:start_link(?MODULE, []).

stop(_State) -> ok.

%% SDK state outlives this application: persistent_term holds configuration,
%% and an independent process owns the ETS tables.
init([]) -> {ok, {#{}, []}}.
