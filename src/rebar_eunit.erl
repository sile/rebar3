%% -*- tab-width: 4;erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2009, 2010 Dave Smith (dizzyd@dizzyd.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -------------------------------------------------------------------
%% @author Dave Smith <dizzyd@dizzyd.com>
%% @doc rebar_eunit supports the following commands:
%% <ul>
%%   <li>eunit - runs eunit tests</li>
%%   <li>clean - remove .eunit directory</li>
%% </ul>
%% The following Global options are supported:
%% <ul>
%%   <li>verbose=1 - show extra output from the eunit test</li>
%%   <li>suite="foo"" - runs test/foo_tests.erl</li>
%% </ul>
%% Additionally, for projects that have separate folders for the core
%% implementation, and for the unit tests, then the following <code>rebar.config</code>
%% option can be provided: <code>{eunit_compile_opts, [{src_dirs, ["dir"]}]}.</code>.
%% @copyright 2009, 2010 Dave Smith
%% -------------------------------------------------------------------
-module(rebar_eunit).

-export([eunit/2]).

-compile([export_all]).

-include("rebar.hrl").

-define(EUNIT_DIR, ".eunit").

%% ===================================================================
%% Public API
%% ===================================================================

eunit(Config, _File) ->
    %% Make sure ?EUNIT_DIR/ directory exists (tack on dummy module)
    ok = filelib:ensure_dir(?EUNIT_DIR ++ "/foo"),

    %% Obtain all the test modules for inclusion in the compile stage.
    %% Notice: this could also be achieved with the following rebar.config option:
    %% {eunit_compile_opts, [{src_dirs, ["test"]}]}
    TestErls = rebar_utils:find_files("test", ".*\\.erl\$"),

    %% Compile erlang code to ?EUNIT_DIR, using a tweaked config
    %% with appropriate defines for eunit, and include all the test modules
    %% as well.
    rebar_erlc_compiler:doterl_compile(eunit_config(Config), ?EUNIT_DIR, TestErls),

    %% Build a list of all the .beams in ?EUNIT_DIR -- use this for cover
    %% and eunit testing. Normally you can just tell cover and/or eunit to
    %% scan the directory for you, but eunit does a code:purge in conjunction
    %% with that scan and causes any cover compilation info to be lost.
    BeamFiles = rebar_utils:beams(?EUNIT_DIR),
    Modules = [rebar_utils:beam_to_mod(?EUNIT_DIR, N) || N <- BeamFiles],

    cover_init(Config, BeamFiles),
    EunitResult = perform_eunit(Config, Modules),
    perform_cover(Config, BeamFiles),

    case EunitResult of
        ok ->
            ok;
        _ ->
            ?CONSOLE("One or more eunit tests failed.~n", []),
            ?FAIL
    end,
    ok.

clean(_Config, _File) ->
    rebar_file_utils:rm_rf(?EUNIT_DIR).

%% ===================================================================
%% Internal functions
%% ===================================================================

perform_eunit(Config, Modules) ->
    %% suite defined, so only specify the module that relates to the
    %% suite (if any)
    Suite = rebar_config:get_global(suite, undefined),
    EunitOpts = get_eunit_opts(Config),

    OrigEnv = set_proc_env(),
    EunitResult = perform_eunit(EunitOpts, Modules, Suite),
    restore_proc_env(OrigEnv),
    EunitResult.

perform_eunit(EunitOpts, Modules, undefined) ->
    (catch eunit:test(Modules, EunitOpts));
perform_eunit(EunitOpts, _Modules, Suite) ->
    (catch eunit:test(list_to_atom(Suite), EunitOpts)).

set_proc_env() ->
    %% Save current code path and then prefix ?EUNIT_DIR on it so that our modules
    %% are found there
    CodePath = code:get_path(),
    true = code:add_patha(?EUNIT_DIR),

    %% Move down into ?EUNIT_DIR while we run tests so any generated files
    %% are created there (versus in the source dir)
    Cwd = rebar_utils:get_cwd(),
    file:set_cwd(?EUNIT_DIR),
    {CodePath, Cwd}.

restore_proc_env({CodePath, Cwd}) ->
    %% Return to original working dir
    file:set_cwd(Cwd),
    %% Restore code path
    true = code:set_path(CodePath).

get_eunit_opts(Config) ->
    %% Enable verbose in eunit if so requested..
    BaseOpts = case rebar_config:is_verbose() of
                   true ->
                       [verbose];
                   false ->
                       []
               end,

    BaseOpts ++ rebar_config:get_list(Config, eunit_opts, []).

eunit_config(Config) ->
    EqcOpts = case is_quickcheck_avail() of
                  true ->
                      [{d, 'EQC'}];
                  false ->
                      []
              end,

    ErlOpts = rebar_config:get_list(Config, erl_opts, []),
    EunitOpts = rebar_config:get_list(Config, eunit_compile_opts, []),
    Opts = [{d, 'TEST'}, debug_info] ++
        ErlOpts ++ EunitOpts ++ EqcOpts,
    rebar_config:set(Config, erl_opts, Opts).

is_quickcheck_avail() ->
    case erlang:get(is_quickcheck_avail) of
        undefined ->
            case code:lib_dir(eqc, include) of
                {error, bad_name} ->
                    IsAvail = false;
                Dir ->
                    IsAvail = filelib:is_file(filename:join(Dir, "eqc.hrl"))
            end,
            erlang:put(is_quickcheck_avail, IsAvail),
            ?DEBUG("Quickcheck availability: ~p\n", [IsAvail]),
            IsAvail;
        IsAvail ->
            IsAvail
    end.

perform_cover(Config, BeamFiles) ->
    perform_cover(rebar_config:get(Config, cover_enabled, false), Config, BeamFiles).

perform_cover(false, _Config, _BeamFiles) ->
    ok;
perform_cover(true, Config, BeamFiles) ->
    perform_cover(Config, BeamFiles, rebar_config:get_global(suite, undefined));
perform_cover(Config, BeamFiles, undefined) ->
    cover_analyze(Config, BeamFiles);
perform_cover(Config, _BeamFiles, Suite) ->
    cover_analyze(Config, [filename:join([?EUNIT_DIR | string:tokens(Suite, ".")]) ++ ".beam"]).

cover_analyze(_Config, []) ->
    ok;
cover_analyze(_Config, BeamFiles) ->
    Modules = [rebar_utils:beam_to_mod(?EUNIT_DIR, N) || N <- BeamFiles],
    %% Generate coverage info for all the cover-compiled modules
    Coverage = [cover_analyze_mod(M) || M <- Modules],

    %% Write index of coverage info
    cover_write_index(lists:sort(Coverage)),

    %% Write coverage details for each file
    [{ok, _} = cover:analyze_to_file(M, cover_file(M), [html]) || {M, _, _} <- Coverage],

    Index = filename:join([rebar_utils:get_cwd(), ?EUNIT_DIR, "index.html"]),
    ?CONSOLE("Cover analysis: ~s\n", [Index]).

cover_init(false, _BeamFiles) ->
    ok;
cover_init(true, BeamFiles) ->
    %% Make sure any previous runs of cover don't unduly influence
    cover:reset(),

    ?INFO("Cover compiling ~s\n", [rebar_utils:get_cwd()]),

    Compiled = [{Beam, cover:compile_beam(Beam)} || Beam <- BeamFiles],
    case [Module || {_, {ok, Module}} <- Compiled] of
        [] ->
            %% No modules compiled successfully...fail
            ?ERROR("Cover failed to compile any modules; aborting.~n", []),
            ?FAIL;
        _ ->
            %% At least one module compiled successfully

            %% It's not an error for cover compilation to fail partially, but we do want
            %% to warn about them
            [?CONSOLE("Cover compilation warning for ~p: ~p", [Beam, Desc]) || {Beam, {error, Desc}} <- Compiled]
    end,
    ok;
cover_init(Config, BeamFiles) ->
    cover_init(rebar_config:get(Config, cover_enabled, false), BeamFiles).

cover_analyze_mod(Module) ->
    case cover:analyze(Module, coverage, module) of
        {ok, {Module, {Covered, NotCovered}}} ->
            {Module, Covered, NotCovered};
        {error, Reason} ->
            ?ERROR("Cover analyze failed for ~p: ~p ~p\n",
                   [Module, Reason, code:which(Module)]),
            {0,0}
    end.

cover_write_index(Coverage) ->
    %% Calculate total coverage %
    {Covered, NotCovered} = lists:foldl(fun({_Mod, C, N}, {CAcc, NAcc}) ->
                                                {CAcc + C, NAcc + N}
                                        end, {0, 0}, Coverage),
    TotalCoverage = percentage(Covered, NotCovered),

    %% Write the report
    {ok, F} = file:open(filename:join([?EUNIT_DIR, "index.html"]), [write]),
    ok = file:write(F, "<html><head><title>Coverage Summary</title></head>\n"
                    "<body><h1>Coverage Summary</h1>\n"),
    ok = file:write(F, ?FMT("<h3>Total: ~w%</h3>\n", [TotalCoverage])),
    ok = file:write(F, "<table><tr><th>Module</th><th>Coverage %</th></tr>\n"),

    [ok = file:write(F, ?FMT("<tr><td><a href='~s.COVER.html'>~s</a></td><td>~w%</td>\n",
                             [Module, Module, percentage(Cov, NotCov)])) ||
        {Module, Cov, NotCov} <- Coverage],
    ok = file:write(F, "</table></body></html>"),
    file:close(F).

cover_file(Module) ->
    filename:join([?EUNIT_DIR, atom_to_list(Module) ++ ".COVER.html"]).

percentage(Cov, NotCov) ->
    trunc((Cov / (Cov + NotCov)) * 100).
