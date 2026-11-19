%% Instruments compiled BEAM files using Erlang abstract code from debug_info.
%% Elixir modules require Elixir's ebin on the code path for their debug_info
%% backend. See instrumentation/symbol_file_format.md for the output format.
%%
%% Coverage edges are function and fun clauses, case/if/receive clauses,
%% try of/catch/after branches, maybe-else clauses, and comprehension templates.
%% Generated clauses use their body's source location when available. Each
%% invocation produces one symbol table with edge indices 1..N.
%%
%% Assertion calls with literal metadata become catalog entries in each
%% application's .app file. The instrumentor also adds the antithesis dependency
%% so releases include the SDK and declare the catalog at startup.
%%
%% Usage: antithesis-beam-instrumentor [--name NAME] --symbols DIR EBIN_DIR...
%% Or invoke directly:
%%     erl -noshell -pa <sdk ebin> [-pa <elixir ebin>] \
%%         -eval 'antithesis_instrument:main(init:get_plain_arguments())' \
%%         -extra [--name NAME] --symbols DIR EBIN_DIR...
-module(antithesis_instrument).
-antithesis_instrumented(sdk).

-export([main/1, instrument/2]).

-define(INSTRUMENTOR, "antithesis-beam-instrumentor").
%% Skip modules marked as already instrumented or as SDK code.
-define(MARK, antithesis_instrumented).
%% Resolved after all modules have been walked.
-define(MODULE_KEY, '$antithesis_module_key').
-define(EDGE_COUNT, '$antithesis_edge_count').
%% Chunks compile:forms does not regenerate, carried over unchanged.
-define(CARRIED_CHUNKS, ["Docs", "ExCk"]).
%% Preserve options that still apply to abstract forms. Exclude output paths,
%% parse transforms already applied, and options requiring Core Erlang input.
-define(KEPT_OPTIONS, [no_auto_import, no_spawn_compiler_process, export_all, tuple_calls, deterministic]).

-record(edge, {file, class, function, line, column, language}).
%% source identifies the module's source file; file tracks -file attributes.
%% function is the enclosing {Name, Arity}; scope names the innermost fun or
%% function for coverage. fun_names holds compiler-assigned {Location, Name}
%% pairs, consumed during traversal. edges and catalog accumulate in reverse
%% order; next is the next edge index.
-record(ctx, {
    language, class, source, file, function, scope, fun_names = [], next, edges = [], catalog = []
}).

main(Args) ->
    try parse_args(Args, #{dirs => []}) of
        #{symbols := _, dirs := [_ | _] = Dirs} = Opts ->
            case instrument(Dirs, Opts) of
                {ok, none, 0} ->
                    io:format("antithesis: nothing to instrument~n"),
                    halt(0);
                {ok, Key, Count} ->
                    io:format("antithesis: instrumented ~b edges as ~ts~n", [Count, Key]),
                    halt(0);
                {error, Reason} ->
                    io:format(standard_error, "antithesis: ~ts~n", [Reason]),
                    halt(1)
            end;
        _ ->
            usage()
    catch
        throw:usage -> usage()
    end.

usage() ->
    io:format(standard_error, "usage: antithesis_instrument [--name NAME] --symbols DIR EBIN_DIR...~n", []),
    halt(2).

parse_args([], Opts) -> Opts;
parse_args(["--name", Name | Rest], Opts) -> parse_args(Rest, Opts#{name => Name});
parse_args(["--symbols", Dir | Rest], Opts) -> parse_args(Rest, Opts#{symbols => Dir});
parse_args(["--" ++ _ | _], _Opts) -> throw(usage);
parse_args([Dir | Rest], #{dirs := Dirs} = Opts) -> parse_args(Rest, Opts#{dirs := Dirs ++ [Dir]}).

%% Rewrites .beam files in Dirs and writes <key>.sym.tsv under Opts.symbols.
%% Returns {ok, Key, EdgeCount}, {ok, none, 0} if no modules need instrumentation,
%% or {error, Reason}. All modules must recompile before any files are written;
%% the symbol table is written first, then each BEAM file is replaced by rename.
instrument(Dirs, Opts) ->
    Beams = lists:sort(lists:append([filelib:wildcard(filename:join(D, "*.beam")) || D <- Dirs])),
    Name = maps:get(name, Opts, default_name(hd(Dirs))),
    Loaded = [load(Beam) || Beam <- Beams],
    case [Error || {error, Error} <- Loaded] of
        [_ | _] = Errors ->
            {error, lists:join("\n", Errors)};
        [] ->
            [warn("skipping ~ts: ~ts", [Beam, Why]) || {skip, Beam, Why} <- Loaded],
            {Walked, Edges} = walk_all([M || {ok, M} <- Loaded]),
            case [M || #{instrumented := false} = M <- Walked] of
                [] ->
                    update_apps(Walked),
                    {ok, none, 0};
                Modules ->
                    Key = module_key(Name, Modules),
                    Count = length(Edges),
                    Compiled = [recompile(M, Key, Count) || M <- Modules],
                    case [Error || {error, Error} <- Compiled] of
                        [_ | _] = Errors ->
                            {error, lists:join("\n", Errors)};
                        [] ->
                            ok = write_symbols(maps:get(symbols, Opts), Key, Name, Edges),
                            [ok = replace(Beam, Bin) || {ok, Beam, Bin} <- Compiled],
                            update_apps(Walked),
                            {ok, Key, Count}
                    end
            end
    end.

warn(Format, Args) -> io:format(standard_error, "antithesis: " ++ Format ++ "~n", Args).

%% Use the OTP application name, falling back to the parent directory name.
default_name(Dir) ->
    case app_file(Dir) of
        {ok, App} -> filename:basename(App, ".app");
        none -> filename:basename(filename:dirname(filename:absname(Dir)))
    end.

app_file(Dir) ->
    case filelib:wildcard(filename:join(Dir, "*.app")) of
        [App | _] -> {ok, App};
        [] -> none
    end.

%% Rebuild catalogs from all modules, including those already instrumented.
%% Their original debug info allows catalog recovery without changing their
%% code or assigning new edge indices.
update_apps(Modules) ->
    Catalogs = maps:groups_from_list(
        fun(#{beam := Beam}) -> filename:dirname(Beam) end,
        fun(#{catalog := C}) -> C end,
        Modules
    ),
    maps:foreach(fun(Dir, Cs) -> update_app(Dir, lists:append(Cs)) end, Catalogs).

update_app(Dir, Catalog) ->
    case app_file(Dir) of
        {ok, App} ->
            case file:consult(App) of
                {ok, [{application, AppName, Props}]} ->
                    Apps = proplists:get_value(applications, Props, []),
                    Env = proplists:get_value(env, Props, []),
                    Key = antithesis_sdk:catalog_key(),
                    Entries = lists:usort(Catalog),
                    Props1 = lists:keystore(applications, 1, Props, {applications, (Apps -- [antithesis]) ++ [antithesis]}),
                    Props2 = lists:keystore(env, 1, Props1, {env, lists:keystore(Key, 1, Env, {Key, Entries})}),
                    case Props2 =:= Props of
                        true -> ok;
                        false -> ok = file:write_file(App, io_lib:format("~tp.~n", [{application, AppName, Props2}]))
                    end;
                _ ->
                    warn("~ts: unreadable; make sure its application depends on antithesis", [App])
            end;
        none ->
            Lost =
                case Catalog of
                    [] -> "";
                    _ -> io_lib:format(", and its ~b assertions are declared only once reached", [length(Catalog)])
                end,
            warn("~ts has no .app file: make sure the instrumented code's application depends on antithesis~ts",
                 [Dir, Lost])
    end.

load(Beam) ->
    case beam_lib:chunks(Beam, [debug_info, attributes, compile_info, exports]) of
        {ok, {Mod, [{debug_info, DebugInfo}, {attributes, Attrs}, {compile_info, Info}, {exports, Exports}]}} ->
            case {proplists:get_value(?MARK, Attrs), lists:member({'__protocol__', 1}, Exports)} of
                {[sdk], _} ->
                    {skip, Beam, "the Antithesis SDK itself"};
                {[_], _} ->
                    case load_forms(Beam, Mod, DebugInfo, Info) of
                        {ok, M} -> {ok, M#{instrumented := true}};
                        Other -> Other
                    end;
                %% Elixir dispatches through consolidated protocol modules, so probes
                %% in these originals would not run.
                {_, true} ->
                    {skip, Beam, "a protocol module"};
                _ ->
                    load_forms(Beam, Mod, DebugInfo, Info)
            end;
        {error, beam_lib, Reason} ->
            {skip, Beam, no_abstract_code(Reason)}
    end.

load_forms(Beam, Mod, {debug_info_v1, Backend, Data} = DebugInfo, Info) ->
    case code:ensure_loaded(Backend) of
        {module, Backend} ->
            case Backend:debug_info(erlang_v1, Mod, Data, []) of
                {ok, Forms} ->
                    Language = language(Backend, Forms),
                    case fun_names(Language, Forms, Info) of
                        {ok, FunNames} ->
                            {ok, #{beam => Beam, module => Mod, forms => Forms, info => Info, instrumented => false,
                                   debug_info => DebugInfo, language => Language, fun_names => FunNames}};
                        {error, Reason} ->
                            {error, io_lib:format("~ts: compiling to Core Erlang failed: ~0tp", [Beam, Reason])}
                    end;
                {error, Reason} ->
                    {skip, Beam, no_abstract_code(Reason)}
            end;
        _ when Backend =:= elixir_erl ->
            {error, io_lib:format("~ts: an Elixir module; put Elixir's ebin on the code path", [Beam])};
        _ ->
            {error, io_lib:format("~ts: unknown debug_info backend ~p", [Beam, Backend])}
    end;
load_forms(Beam, _Mod, DebugInfo, _Info) ->
    {skip, Beam, no_abstract_code(DebugInfo)}.

no_abstract_code(Reason) ->
    io_lib:format("no Erlang abstract code (~0tp); compile with debug_info and instrument before "
                  "stripping beams (mix release strip_beams, relx prod mode)", [Reason]).

language(elixir_erl, _Forms) ->
    <<"Elixir">>;
language(_Backend, Forms) ->
    case filename:extension(first_file(Forms)) of
        ".gleam" -> <<"Gleam">>;
        _ -> <<"Erlang">>
    end.

first_file(Forms) ->
    case [File || {attribute, _, file, {File, _}} <- Forms] of
        [File | _] -> File;
        [] -> ""
    end.

%% Read fun names from Core Erlang to match compiler numbering, which is
%% shared with comprehensions and assigns nested funs before their parents.
fun_names(<<"Erlang">>, Forms, Info) ->
    Options = [to_core0, binary, return_errors, no_spawn_compiler_process | kept_options(Info)],
    try compile:noenv_forms(Forms, Options) of
        {ok, _, Core} -> {ok, lists:reverse(core_funs(Core, []))};
        {error, Errors, _Warnings} -> {error, Errors}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end;
fun_names(_Language, _Forms, _Info) ->
    {ok, []}.

core_funs({c_fun, Anno, _Vars, Body}, Acc) ->
    Found = [{Location, atom_to_binary(Name)} || {id, {_, _, Name}} <- Anno, Location <- Anno, is_location(Location)],
    core_funs(Body, lists:reverse(Found, Acc));
core_funs(Tuple, Acc) when is_tuple(Tuple) ->
    core_funs(tuple_to_list(Tuple), Acc);
core_funs([H | T], Acc) ->
    core_funs(T, core_funs(H, Acc));
core_funs(_, Acc) ->
    Acc.

is_location(Line) when is_integer(Line) -> true;
is_location({Line, Column}) -> is_integer(Line) andalso is_integer(Column);
is_location(_) -> false.

%% Collect catalogs from all modules; assign edge indices only to new ones.
walk_all(Modules) ->
    {Walked, {_, EdgeLists}} = lists:mapfoldl(
        fun(M, {Next, Acc}) ->
            {Forms, Ctx} = walk_module(M, Next),
            State = case maps:get(instrumented, M) of
                true -> {Next, Acc};
                false -> {Ctx#ctx.next, [lists:reverse(Ctx#ctx.edges) | Acc]}
            end,
            {M#{forms := Forms, catalog => lists:reverse(Ctx#ctx.catalog)}, State}
        end,
        {1, []},
        Modules
    ),
    {Walked, lists:append(lists:reverse(EdgeLists))}.

walk_module(#{module := Mod, forms := Forms, language := Language, fun_names := FunNames}, Next) ->
    Source = file_text(first_file(Forms)),
    Ctx = #ctx{language = Language, class = class(Language, Mod), source = Source, file = Source,
               fun_names = FunNames, next = Next},
    lists:mapfoldl(fun form/2, Ctx, Forms).

file_text(File) -> unicode:characters_to_binary(File).

form({attribute, _, file, {File, _}} = Form, Ctx) ->
    {Form, Ctx#ctx{file = file_text(File)}};
form({function, Anno, Name, Arity, Clauses} = Form, Ctx) ->
    case skip_function(Name, Arity) orelse not written(Anno) orelse injected(Ctx) of
        true ->
            {Form, Ctx};
        false ->
            Function = {Name, Arity},
            Ctx1 = Ctx#ctx{function = Function, scope = function_name(Ctx#ctx.language, Function)},
            {Clauses1, Ctx2} = clauses(Clauses, Ctx1),
            {{function, Anno, Name, Arity, Clauses1}, Ctx2}
    end;
form(Form, Ctx) ->
    {Form, Ctx}.

%% Exclude compiler-generated reflection and macro expansion functions,
%% which may run while compiling other modules.
skip_function('__info__', 1) -> true;
skip_function(module_info, 0) -> true;
skip_function(module_info, 1) -> true;
skip_function('LFE-EXPAND-EXPORTED-MACRO', 3) -> true;
skip_function(_, _) -> false.

%% Elixir's `quote location: :keep` attributes injected functions (such as
%% GenServer defaults) to the macro's file but uses lines from the call site.
%% Skip these functions because their locations are unreliable. Erlang include
%% locations are accurate and do not need this exclusion.
injected(#ctx{language = <<"Elixir">>, source = Source, file = File}) -> File =/= Source;
injected(_Ctx) -> false.

clauses(Clauses, Ctx) ->
    lists:mapfoldl(fun clause/2, Ctx, Clauses).

clause({clause, Anno, Patterns, Guards, Body}, Ctx) ->
    {Body1, Ctx1} = exprs(Body, Ctx),
    {Body2, Ctx2} = probe(edge_anno(Anno, Body), Body1, Ctx1),
    {{clause, Anno, Patterns, Guards, Body2}, Ctx2}.

%% Use the clause's source location, or the first body expression's location
%% for a generated clause.
edge_anno(Anno, Body) ->
    case written(Anno) of
        true -> Anno;
        false -> body_anno(Body, Anno)
    end.

body_anno([First | _], Default) when is_tuple(First), tuple_size(First) >= 2 ->
    Anno = element(2, First),
    try written(Anno) of
        true -> Anno;
        false -> Default
    catch
        _:_ -> Default
    end;
body_anno(_, Default) ->
    Default.

written(Anno) ->
    not erl_anno:generated(Anno) andalso erl_anno:line(Anno) > 0.

probe(Anno, Body, #ctx{next = Index} = Ctx) ->
    case erl_anno:line(Anno) > 0 of
        true ->
            Edge = #edge{
                file = Ctx#ctx.file,
                class = Ctx#ctx.class,
                function = Ctx#ctx.scope,
                line = erl_anno:line(Anno),
                column = column(Anno),
                language = Ctx#ctx.language
            },
            {[probe_call(Anno, Index) | Body], Ctx#ctx{next = Index + 1, edges = [Edge | Ctx#ctx.edges]}};
        false ->
            {Body, Ctx}
    end.

column(Anno) ->
    case erl_anno:column(Anno) of
        undefined -> 0;
        Column -> Column
    end.

probe_call(Anno0, Index) ->
    Anno = erl_anno:set_generated(true, Anno0),
    {call, Anno, {remote, Anno, {atom, Anno, antithesis_nif}, {atom, Anno, hit}},
     [{atom, Anno, ?MODULE_KEY}, {atom, Anno, ?EDGE_COUNT}, {integer, Anno, Index}]}.

exprs(Exprs, Ctx) -> lists:mapfoldl(fun expr/2, Ctx, Exprs).

expr({'case', A, E, Cs}, Ctx) ->
    {E1, Ctx1} = expr(E, Ctx),
    {Cs1, Ctx2} = clauses(Cs, Ctx1),
    {{'case', A, E1, Cs1}, Ctx2};
expr({'if', A, Cs}, Ctx) ->
    {Cs1, Ctx1} = clauses(Cs, Ctx),
    {{'if', A, Cs1}, Ctx1};
expr({'receive', A, Cs}, Ctx) ->
    {Cs1, Ctx1} = clauses(Cs, Ctx),
    {{'receive', A, Cs1}, Ctx1};
expr({'receive', A, Cs, T, After}, Ctx) ->
    {Cs1, Ctx1} = clauses(Cs, Ctx),
    {T1, Ctx2} = expr(T, Ctx1),
    {After1, Ctx3} = body_edge(A, After, Ctx2),
    {{'receive', A, Cs1, T1, After1}, Ctx3};
expr({'try', A, Body, Of, Catch, After}, Ctx) ->
    {Body1, Ctx1} = exprs(Body, Ctx),
    {Of1, Ctx2} = clauses(Of, Ctx1),
    {Catch1, Ctx3} = clauses(Catch, Ctx2),
    {After1, Ctx4} =
        case After of
            [] -> {[], Ctx3};
            _ -> body_edge(A, After, Ctx3)
        end,
    {{'try', A, Body1, Of1, Catch1, After1}, Ctx4};
expr({'maybe', A, Body, {'else', A2, Cs}}, Ctx) ->
    {Body1, Ctx1} = exprs(Body, Ctx),
    {Cs1, Ctx2} = clauses(Cs, Ctx1),
    {{'maybe', A, Body1, {'else', A2, Cs1}}, Ctx2};
expr({'fun', A, {clauses, Cs}}, Ctx) ->
    {Cs1, Ctx1} = closure(A, Cs, Ctx),
    {{'fun', A, {clauses, Cs1}}, Ctx1};
expr({named_fun, A, Name, Cs}, Ctx) ->
    {Cs1, Ctx1} = closure(A, Cs, Ctx),
    {{named_fun, A, Name, Cs1}, Ctx1};
expr({call, A, {remote, _, {atom, _, antithesis_assert}, {atom, _, Function}} = Callee, Args}, Ctx) ->
    {Args1, Ctx1} = exprs(Args, Ctx),
    Catalog =
        case catalog_entry(Function, Args) of
            none -> Ctx1#ctx.catalog;
            Entry -> [Entry | Ctx1#ctx.catalog]
        end,
    {{call, A, Callee, Args1}, Ctx1#ctx{catalog = Catalog}};
expr({Comprehension, A, Template, Qualifiers}, Ctx) when
    Comprehension =:= lc; Comprehension =:= bc; Comprehension =:= mc
->
    {Qualifiers1, Ctx1} = exprs(Qualifiers, Ctx),
    {Template1, Ctx2} = expr(Template, Ctx1),
    {Template2, Ctx3} = probe_template(A, Template1, Ctx2),
    {{Comprehension, A, Template2, Qualifiers1}, Ctx3};
expr(Tuple, Ctx) when is_tuple(Tuple) ->
    {Elements, Ctx1} = lists:mapfoldl(fun expr/2, Ctx, tuple_to_list(Tuple)),
    {list_to_tuple(Elements), Ctx1};
expr(List, Ctx) when is_list(List) ->
    lists:mapfoldl(fun expr/2, Ctx, List);
expr(Other, Ctx) ->
    {Other, Ctx}.

%% Extract catalog metadata from assertion calls only when it is literal.
catalog_entry(hit, [_Condition, Message, _Details, Site, DisplayType]) ->
    case literals([Message, Site, DisplayType]) of
        {ok, [M, S, D]} -> {hit, M, S, D};
        error -> none
    end;
catalog_entry(rich, [Kind, _Operands, Message, _Details, Site]) ->
    case literals([Kind, Message, Site]) of
        {ok, [K, M, S]} -> {rich, K, M, S};
        error -> none
    end;
catalog_entry(_Function, _Args) ->
    none.

literals(Exprs) ->
    try
        {ok, [erl_parse:normalise(E) || E <- Exprs]}
    catch
        _:_ -> error
    end.

%% A comprehension template executes once per element. Map templates are
%% associations, so their probes must go in the value expression.
probe_template(A, {map_field_assoc, A2, K, V}, Ctx) ->
    {V1, Ctx1} = probed_block(A, V, Ctx),
    {{map_field_assoc, A2, K, V1}, Ctx1};
probe_template(A, Template, Ctx) ->
    probed_block(A, Template, Ctx).

probed_block(A, Expr, Ctx) ->
    case probe(A, [Expr], Ctx) of
        {[Expr], Ctx1} -> {Expr, Ctx1};
        {Probed, Ctx1} -> {{block, A, Probed}, Ctx1}
    end.

%% Treat receive/try after bodies as edges at the body's source location.
body_edge(A, Body, Ctx) ->
    {Body1, Ctx1} = exprs(Body, Ctx),
    probe(body_anno(Body, A), Body1, Ctx1).

%% Attribute edges inside a fun to that fun. Compiler-generated funs do not
%% get clause probes, but their bodies may contain instrumentable expressions.
closure(A, Cs, Ctx) ->
    Arity =
        case Cs of
            [{clause, _, Patterns, _, _} | _] -> length(Patterns);
            [] -> 0
        end,
    {Name, Ctx1} = closure_name(A, Arity, Ctx),
    {Cs1, Ctx2} =
        case written(A) of
            true -> clauses(Cs, Ctx1#ctx{scope = Name});
            false -> exprs(Cs, Ctx1#ctx{scope = Name})
        end,
    {Cs1, Ctx2#ctx{scope = Ctx#ctx.scope}}.

function_name(<<"Gleam">>, {Name, _Arity}) ->
    atom_to_binary(Name);
function_name(_Language, {Name, Arity}) ->
    iolist_to_binary([atom_to_binary(Name), "/", integer_to_binary(Arity)]).

%% Match stack trace names: Elixir and Gleam use the enclosing function;
%% Erlang uses compiler-assigned names matched by source location.
closure_name(_A, Arity, #ctx{language = <<"Elixir">> = Language, function = Function} = Ctx) ->
    {iolist_to_binary(["anonymous fn/", integer_to_binary(Arity), " in ", function_name(Language, Function)]), Ctx};
closure_name(_A, _Arity, #ctx{language = <<"Gleam">> = Language, function = Function} = Ctx) ->
    {iolist_to_binary(["anonymous fn in ", function_name(Language, Function)]), Ctx};
closure_name(A, _Arity, #ctx{fun_names = Known} = Ctx) ->
    Location = erl_anno:location(A),
    Line = erl_anno:line(A),
    Other = fun({L, _}) -> L =/= Location andalso L =/= Line end,
    {Before, [{_, Name} | After]} = lists:splitwith(Other, Known),
    {Name, Ctx#ctx{fun_names = Before ++ After}}.

class(<<"Elixir">>, Mod) ->
    case atom_to_binary(Mod) of
        <<"Elixir.", Rest/binary>> -> Rest;
        Other -> Other
    end;
class(<<"Gleam">>, Mod) ->
    binary:replace(atom_to_binary(Mod), <<"@">>, <<"/">>, [global]);
class(_Language, Mod) ->
    atom_to_binary(Mod).

%% Hash the module names and forms to distinguish instrumented builds.
module_key(Name, Modules) ->
    Digest = erlang:md5_final(lists:foldl(
        fun(#{module := Mod, forms := Forms}, Md5) -> erlang:md5_update(Md5, term_to_binary({Mod, Forms})) end,
        erlang:md5_init(),
        Modules
    )),
    <<Hex:12/binary, _/binary>> = binary:encode_hex(Digest, lowercase),
    Safe = re:replace(Name, "[^A-Za-z0-9_.-]", "-", [global, {return, binary}, unicode]),
    <<Safe/binary, "-", Hex/binary>>.

recompile(#{beam := Beam, module := Mod, forms := Forms0, info := Info, debug_info := {debug_info_v1, Backend, Data}}, Key, Count) ->
    KeyAtom = binary_to_atom(Key),
    Forms = mark(substitute(Forms0, KeyAtom, Count), KeyAtom),
    {ok, Mod, All} = beam_lib:all_chunks(Beam),
    Carried = [{list_to_binary(Id), Bin} || {Id, Bin} <- All, lists:member(Id, ?CARRIED_CHUNKS)],
    Source = [{source, S} || S <- [proplists:get_value(source, Info)], S =/= undefined],
    Options = [binary, return_errors, {extra_chunks, Carried}, {debug_info, {Backend, Data}}]
        ++ Source ++ kept_options(Info),
    try compile:noenv_forms(Forms, Options) of
        {ok, Mod, Bin} -> {ok, Beam, Bin};
        {error, Errors, _Warnings} -> {error, io_lib:format("~ts: recompiling failed: ~0tp", [Beam, Errors])}
    catch
        Class:Reason -> {error, io_lib:format("~ts: recompiling failed: ~0tp", [Beam, {Class, Reason}])}
    end.

kept_options(Info) ->
    [O || O <- proplists:get_value(options, Info, []), kept_option(O)].

kept_option({feature, _, _}) -> true;
kept_option({no_auto_import, _}) -> true;
kept_option(O) -> lists:member(O, ?KEPT_OPTIONS).

%% Rename atomically so readers cannot see a partially written BEAM file.
replace(Beam, Bin) ->
    Temp = Beam ++ ".antithesis",
    ok = file:write_file(Temp, Bin),
    file:rename(Temp, Beam).

substitute({atom, A, ?MODULE_KEY}, Key, _Count) -> {atom, A, Key};
substitute({atom, A, ?EDGE_COUNT}, _Key, Count) -> {integer, A, Count};
substitute(Tuple, Key, Count) when is_tuple(Tuple) ->
    list_to_tuple([substitute(E, Key, Count) || E <- tuple_to_list(Tuple)]);
substitute(List, Key, Count) when is_list(List) ->
    [substitute(E, Key, Count) || E <- List];
substitute(Other, _Key, _Count) ->
    Other.

mark([{attribute, A, module, _} = Module | Rest], Key) ->
    [Module, {attribute, A, ?MARK, Key} | Rest];
mark([Form | Rest], Key) ->
    [Form | mark(Rest, Key)].

write_symbols(Dir, Key, Name, Edges) ->
    ok = filelib:ensure_path(Dir),
    %% Mixed-language builds need a language column; others use the header.
    {LanguageGlobal, LanguageColumn} =
        case lists:usort([E#edge.language || E <- Edges]) of
            [Only] -> {Only, false};
            _ -> {<<"BEAM">>, true}
        end,
    Header = [
        "# language = ", LanguageGlobal, "\n",
        "# instrumentor = ", ?INSTRUMENTOR, " ", antithesis_sdk:sdk_version(), "\n",
        "# module = ", Key, "\n",
        "# name = ", unicode:characters_to_binary(Name), "\n",
        lists:join("\t", ["file", "class", "function", "begin_line", "begin_column", "address"]
                         ++ ["language" || LanguageColumn]), "\n"
    ],
    Rows = [
        [lists:join("\t", [E#edge.file, E#edge.class, E#edge.function, integer_to_binary(E#edge.line),
                           integer_to_binary(E#edge.column), integer_to_binary(I)]
                          ++ [E#edge.language || LanguageColumn]), "\n"]
     || {I, E} <- lists:enumerate(Edges)
    ],
    file:write_file(filename:join(Dir, <<Key/binary, ".sym.tsv">>), [Header | Rows]).
