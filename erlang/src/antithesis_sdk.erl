%% VM-wide SDK state and output selection.
%%
%% The first SDK call selects libvoidstar, the ANTITHESIS_SDK_LOCAL_OUTPUT
%% JSONL file, or no output. It writes the version header and declares catalogs
%% stored in loaded applications' environments under catalog_key().
%%
%% Known front ends are loaded before the header is written so they can set
%% the language even when the antithesis application starts before user code.
-module(antithesis_sdk).
-antithesis_instrumented(sdk).
-moduledoc false.

-export([start/0, sdk_version/0, set_language/2, language/0, catalog_key/0]).
-export([table/1, claim_warning/1, output/1, random/0]).

-define(PROTOCOL_VERSION, <<"1.1.0">>).
-define(LOCAL_OUTPUT_ENV, "ANTITHESIS_SDK_LOCAL_OUTPUT").
-define(STATE_KEY, {?MODULE, state}).
-define(LANGUAGE_KEY, {?MODULE, language}).
%% These modules set the SDK language in their on_load callbacks.
-define(FRONT_ENDS, ['Elixir.Antithesis.Assert']).

catalog_key() -> antithesis_catalog.

%% Return "unknown" if the antithesis .app file is unavailable.
sdk_version() ->
    _ = application:load(antithesis),
    case application:get_key(antithesis, vsn) of
        {ok, Vsn} -> list_to_binary(Vsn);
        undefined -> <<"unknown">>
    end.

%% Set the header's language and version before initialization. Later calls
%% have no effect, keeping diagnostics consistent with the header.
-spec set_language(binary(), binary()) -> ok.
set_language(Name, Version) when is_binary(Name), is_binary(Version) ->
    persistent_term:get(?STATE_KEY, undefined) =:= undefined andalso
        persistent_term:put(?LANGUAGE_KEY, {Name, Version}),
    ok.

language() ->
    element(1, language_info()).

language_info() ->
    persistent_term:get(
        ?LANGUAGE_KEY, {<<"Erlang">>, list_to_binary(erlang:system_info(otp_release))}
    ).

state() ->
    case persistent_term:get(?STATE_KEY, undefined) of
        undefined -> initialize();
        State -> State
    end.

%% Application startup calls this to declare the catalog even if user code
%% never calls the SDK. Subsequent calls reuse the initialized state.
-spec start() -> ok.
start() ->
    _ = state(),
    ok.

%% Serialize initialization within this VM; only the initializer declares the catalog.
initialize() ->
    case global:trans({?MODULE, self()}, fun init/0, [node()]) of
        {new, State} ->
            declare_catalog(),
            State;
        {old, State} ->
            State
    end.

init() ->
    case persistent_term:get(?STATE_KEY, undefined) of
        undefined ->
            [code:ensure_loaded(M) || M <- ?FRONT_ENDS],
            State = #{
                handler => choose_handler(),
                tables => start_owner(),
                warned => atomics:new(3, [])
            },
            %% Publish state after writing the header so callers that skip the lock
            %% cannot emit packets before it.
            write(maps:get(handler, State), version_message()),
            persistent_term:put(?STATE_KEY, State),
            {new, State};
        State ->
            {old, State}
    end.

declare_catalog() ->
    [
        antithesis_assert:declare(Entry)
     || {App, _, _} <- application:loaded_applications(),
        Entry <- application:get_env(App, catalog_key(), [])
    ],
    ok.

choose_handler() ->
    case native_available() of
        true ->
            voidstar;
        false ->
            case os:getenv(?LOCAL_OUTPUT_ENV) of
                false ->
                    noop;
                Path ->
                    case file:open(Path, [append]) of
                        {ok, File} ->
                            ok = file:close(File),
                            {local, Path};
                        {error, _} ->
                            noop
                    end
            end
    end.

native_available() ->
    try
        antithesis_nif:available()
    catch
        error:_ -> false
    end.

%% A dedicated process owns the ETS tables so they outlive the first caller.
%% Using init's group leader also keeps application shutdown from killing it.
start_owner() ->
    Parent = self(),
    Ref = make_ref(),
    spawn(fun() ->
        group_leader(whereis(init), self()),
        Tables = #{
            assertions => ets:new(antithesis_assertions, [set, public, {read_concurrency, true}]),
            guidance => ets:new(antithesis_guidance, [set, public, {read_concurrency, true}])
        },
        Parent ! {Ref, Tables},
        timer:sleep(infinity)
    end),
    receive
        {Ref, Tables} -> Tables
    end.

table(Name) -> maps:get(Name, maps:get(tables, state())).

%% Return true once per warning code (6002..6004) per VM.
claim_warning(Code) ->
    atomics:compare_exchange(maps:get(warned, state()), Code - 6001, 0, 1) =:= ok.

output(IoData) -> write(maps:get(handler, state()), IoData).

write(voidstar, IoData) ->
    antithesis_nif:output(IoData),
    ok;
%% Append each JSONL packet in one write to avoid interleaving concurrent output.
write({local, Path}, IoData) ->
    _ = file:write_file(Path, [IoData, $\n], [append, raw]),
    ok;
write(noop, _IoData) ->
    ok.

random() ->
    case maps:get(handler, state()) of
        voidstar -> antithesis_nif:get_random();
        _ -> rand:uniform(1 bsl 64) - 1
    end.

version_message() ->
    {Name, Version} = language_info(),
    json:encode(#{
        <<"antithesis_sdk">> => #{
            <<"language">> => #{<<"name">> => Name, <<"version">> => Version},
            <<"sdk_version">> => sdk_version(),
            <<"protocol_version">> => ?PROTOCOL_VERSION
        }
    }).
