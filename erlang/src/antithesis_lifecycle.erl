%% Report setup completion and named events.
%%
%% Omitted or undefined details are absent from setup records and become #{}
%% for events. Encoded objects pass through; other values are wrapped under
%% "value".
-module(antithesis_lifecycle).
-antithesis_instrumented(sdk).

-export([setup_complete/0, setup_complete/1, send_event/1, send_event/2]).

setup_complete() -> setup_complete(undefined).

%% Indicates that the system and workload are fully initialized. Antithesis
%% then takes a snapshot and begins injecting faults.
setup_complete(Details) ->
    Record = #{<<"status">> => <<"complete">>},
    antithesis_details:dispatch(
        #{<<"antithesis_setup">> => antithesis_details:put_details(Record, Details)},
        #{<<"antithesis_setup">> => Record},
        <<"setup_complete">>
    ).

send_event(Name) -> send_event(Name, undefined).

%% Record a named event with optional details.
send_event(Name, Details) when is_binary(Name) ->
    Payload =
        case antithesis_details:is_absent(Details) of
            true -> #{};
            false -> antithesis_details:details_object(Details)
        end,
    antithesis_details:dispatch(#{Name => Payload}, #{Name => #{}}, Name).
