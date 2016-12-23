%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2009 Dave Smith (dizzyd@dizzyd.com)
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
-module(rebar_base_compiler).

-include("rebar.hrl").

-export([run/4,
         run/7,
         run/8,
         ok_tuple/2,
         error_tuple/4,
         format_error_source/2]).

-define(DEFAULT_COMPILER_SOURCE_FORMAT, relative).
-type desc() :: term().
-type loc() :: {line(), col()} | line().
-type line() :: integer().
-type col() :: integer().
-type err_or_warn() :: {module(), desc()} | {loc(), module(), desc()}.

-type compile_fn_ret() ::  ok | {ok, [string()]} | skipped | term().
-type compile_fn() :: fun((file:filename(), [{_,_}] | rebar_dict()) -> compile_fn_ret()).
-type compile_fn3() :: fun((file:filename(), file:filename(), [{_,_}] | rebar_dict())
                           -> compile_fn_ret()).
-type error_tuple() :: {error, [string()], [string()]}.
-export_type([compile_fn/0, compile_fn_ret/0, error_tuple/0]).


%% ===================================================================
%% Public API
%% ===================================================================

%% @doc Runs a compile job, applying `compile_fn()' to all files,
%% starting with `First' files, and then `RestFiles'.
-spec run(rebar_dict() | [{_,_}] , [First], [Next], compile_fn()) ->
    compile_fn_ret() when
      First :: file:filename(),
      Next :: file:filename().
run(Config, FirstFiles, RestFiles, CompileFn) ->
    %% Compile the first files in sequence
    compile_each(FirstFiles++RestFiles, Config, CompileFn).

%% @doc Runs a compile job, applying `compile_fn3()' to all files,
%% starting with `First' files, and then the other content of `SourceDir'.
%% Files looked for are those ending in `SourceExt'. Results of the
%% compilation are put in `TargetDir' with the base file names
%% postfixed with `SourceExt'.
-spec run(rebar_dict() | [{_,_}] , [First], SourceDir, SourceExt,
      TargetDir, TargetExt, compile_fn3()) -> compile_fn_ret() when
      First :: file:filename(),
      SourceDir :: file:filename(),
      TargetDir :: file:filename(),
      SourceExt :: string(),
      TargetExt :: string().
run(Config, FirstFiles, SourceDir, SourceExt, TargetDir, TargetExt,
    Compile3Fn) ->
    run(Config, FirstFiles, SourceDir, SourceExt, TargetDir, TargetExt,
        Compile3Fn, [check_last_mod]).

%% @doc Runs a compile job, applying `compile_fn3()' to all files,
%% starting with `First' files, and then the other content of `SourceDir'.
%% Files looked for are those ending in `SourceExt'. Results of the
%% compilation are put in `TargetDir' with the base file names
%% postfixed with `SourceExt'.
%% Additional compile options can be passed in the last argument as
%% a proplist.
-spec run(rebar_dict() | [{_,_}] , [First], SourceDir, SourceExt,
      TargetDir, TargetExt, compile_fn3(), [term()]) -> compile_fn_ret() when
      First :: file:filename(),
      SourceDir :: file:filename(),
      TargetDir :: file:filename(),
      SourceExt :: string(),
      TargetExt :: string().
run(Config, FirstFiles, SourceDir, SourceExt, TargetDir, TargetExt,
    Compile3Fn, Opts) ->
    %% Convert simple extension to proper regex
    SourceExtRe = "^(?!\\._).*\\" ++ SourceExt ++ [$$],

    Recursive = proplists:get_value(recursive, Opts, true),
    %% Find all possible source files
    FoundFiles = rebar_utils:find_files(SourceDir, SourceExtRe, Recursive),
    %% Remove first files from found files
    RestFiles = [Source || Source <- FoundFiles,
                           not lists:member(Source, FirstFiles)],

    %% Check opts for flag indicating that compile should check lastmod
    CheckLastMod = proplists:get_bool(check_last_mod, Opts),

    run(Config, FirstFiles, RestFiles,
        fun(S, C) ->
                Target = target_file(S, SourceDir, SourceExt,
                                     TargetDir, TargetExt),
                simple_compile_wrapper(S, Target, Compile3Fn, C, CheckLastMod)
        end).

%% @doc Format good compiler results with warnings to work with
%% module internals. Assumes that warnings are not treated as errors.
-spec ok_tuple(file:filename(), [string()]) -> {ok, [string()]}.
ok_tuple(Source, Ws) ->
    {ok, format_warnings(Source, Ws)}.

%% @doc format error and warning strings for a given source file
%% according to user preferences.
-spec error_tuple(file:filename(), [Err], [Warn], rebar_dict() | [{_,_}]) ->
    error_tuple() when
      Err :: string(),
      Warn :: string().
error_tuple(Source, Es, Ws, Opts) ->
    {error, format_errors(Source, Es),
     format_warnings(Source, Ws, Opts)}.

%% @doc from a given path, and based on the user-provided options,
%% format the file path according to the preferences.
-spec format_error_source(file:filename(), rebar_dict() | [{_,_}]) ->
    file:filename().
format_error_source(Path, Opts) ->
    Type = case rebar_opts:get(Opts, compiler_source_format,
                               ?DEFAULT_COMPILER_SOURCE_FORMAT) of
        V when V == absolute; V == relative; V == build ->
            V;
        Other ->
            ?WARN("Invalid argument ~p for compiler_source_format - "
                  "assuming ~s~n", [Other, ?DEFAULT_COMPILER_SOURCE_FORMAT]),
            ?DEFAULT_COMPILER_SOURCE_FORMAT
    end,
    case Type of
        absolute -> resolve_linked_source(Path);
        build -> Path;
        relative ->
            Cwd = rebar_dir:get_cwd(),
            rebar_dir:make_relative_path(resolve_linked_source(Path), Cwd)
    end.

%% @private takes a filename and canonicalizes its path if it is a link.
-spec resolve_linked_source(file:filename()) -> file:filename().
resolve_linked_source(Src) ->
    {Dir, Base} = rebar_file_utils:split_dirname(Src),
    filename:join(rebar_file_utils:resolve_link(Dir), Base).

%% ===================================================================
%% Internal functions
%% ===================================================================

%% @private if a check for last modifications is required, do the verification
%% and possibly skip the compile job.
-spec simple_compile_wrapper(Source, Target, compile_fn3(), [{_,_}] | rebar_dict(), boolean()) -> compile_fn_ret() when
      Source :: file:filename(),
      Target :: file:filename().
simple_compile_wrapper(Source, Target, Compile3Fn, Config, false) ->
    Compile3Fn(Source, Target, Config);
simple_compile_wrapper(Source, Target, Compile3Fn, Config, true) ->
    case filelib:last_modified(Target) < filelib:last_modified(Source) of
        true ->
            Compile3Fn(Source, Target, Config);
        false ->
            skipped
    end.

%% @private take a basic source set of file fragments and a target location,
%% create a file path and name for a compile artifact.
-spec target_file(SourceFile, SourceDir, SourceExt, TargetDir, TargetExt) -> File when
      SourceFile :: file:filename(),
      SourceDir :: file:filename(),
      TargetDir :: file:filename(),
      SourceExt :: string(),
      TargetExt :: string(),
      File :: file:filename().
target_file(SourceFile, SourceDir, SourceExt, TargetDir, TargetExt) ->
    BaseFile = remove_common_path(SourceFile, SourceDir),
    filename:join([TargetDir, filename:basename(BaseFile, SourceExt) ++ TargetExt]).

%% @private removes the common prefix between two file paths.
%% The remainder of the first file path passed will have its ending returned
%% when either path starts diverging.
-spec remove_common_path(file:filename(), file:filename()) -> file:filename().
remove_common_path(Fname, Path) ->
    remove_common_path1(filename:split(Fname), filename:split(Path)).

%% @private given two lists of file fragments, discard the identical
%% prefixed sections, and return the final bit of the first operand
%% as a filename.
-spec remove_common_path1([string()], [string()]) -> file:filename().
remove_common_path1([Part | RestFilename], [Part | RestPath]) ->
    remove_common_path1(RestFilename, RestPath);
remove_common_path1(FilenameParts, _) ->
    filename:join(FilenameParts).

%% @private runs the compile function `CompileFn' on every file
%% passed internally, along with the related project configuration.
%% If any errors are encountered, they're reported to stdout.
-spec compile_each([file:filename()], Config, CompileFn) -> Ret | no_return() when
      Config :: [{_,_}] | rebar_dict(),
      CompileFn :: compile_fn(),
      Ret :: compile_fn_ret().
compile_each([], _Config, _CompileFn) ->
    ok;
compile_each([Source | Rest], Config, CompileFn) ->
    case CompileFn(Source, Config) of
        ok ->
            ?DEBUG("~sCompiled ~s", [rebar_utils:indent(1), filename:basename(Source)]);
        {ok, Warnings} ->
            report(Warnings),
            ?DEBUG("~sCompiled ~s", [rebar_utils:indent(1), filename:basename(Source)]);
        skipped ->
            ?DEBUG("~sSkipped ~s", [rebar_utils:indent(1), filename:basename(Source)]);
        Error ->
            NewSource = format_error_source(Source, Config),
            ?ERROR("Compiling ~s failed", [NewSource]),
            maybe_report(Error),
            ?DEBUG("Compilation failed: ~p", [Error]),
            ?FAIL
    end,
    compile_each(Rest, Config, CompileFn).

%% @private Formats and returns errors ready to be output.
-spec format_errors(string(), [err_or_warn()]) -> [string()].
format_errors(Source, Errors) ->
    format_errors(Source, "", Errors).

%% @private Formats and returns warning strings ready to be output.
-spec format_warnings(string(), [err_or_warn()]) -> [string()].
format_warnings(Source, Warnings) ->
    format_warnings(Source, Warnings, []).

%% @private Formats and returns warnings; chooses the distinct format they
%% may have based on whether `warnings_as_errors' option is on.
-spec format_warnings(string(), [err_or_warn()], rebar_dict() | [{_,_}]) -> [string()].
format_warnings(Source, Warnings, Opts) ->
    %% `Opts' can be passed in both as a list or a dictionary depending
    %% on whether the first call to rebar_erlc_compiler was done with
    %% the type `rebar_dict()' or `rebar_state:t()'.
    LookupFn = if is_list(Opts) -> fun lists:member/2
                ; true          -> fun dict:is_key/2
               end,
    Prefix = case LookupFn(warnings_as_errors, Opts) of
                 true -> "";
                 false -> "Warning: "
             end,
    format_errors(Source, Prefix, Warnings).

%% @private output compiler errors if they're judged to be reportable.
-spec maybe_report(Reportable | term()) -> ok when
      Reportable :: {{error, error_tuple()}, Source} | error_tuple() | ErrProps,
      ErrProps :: [{error, string()} | Source, ...],
      Source :: {source, string()}.
maybe_report({{error, {error, _Es, _Ws}=ErrorsAndWarnings}, {source, _}}) ->
    maybe_report(ErrorsAndWarnings);
maybe_report([{error, E}, {source, S}]) ->
    report(["unexpected error compiling " ++ S, io_lib:fwrite("~n~p", [E])]);
maybe_report({error, Es, Ws}) ->
    report(Es),
    report(Ws);
maybe_report(_) ->
    ok.

%% @private Outputs a bunch of strings, including a newline
-spec report([string()]) -> ok.
report(Messages) ->
    lists:foreach(fun(Msg) -> io:format("~s~n", [Msg]) end, Messages).

%% private format compiler errors into proper outputtable strings
-spec format_errors(_, Extra, [err_or_warn()]) -> [string()] when
      Extra :: string().
format_errors(_MainSource, Extra, Errors) ->
    [begin
         [format_error(Source, Extra, Desc) || Desc <- Descs]
     end
     || {Source, Descs} <- Errors].

%% @private format compiler errors into proper outputtable strings
-spec format_error(file:filename(), Extra, err_or_warn()) -> string() when
      Extra :: string().
format_error(Source, Extra, {{Line, Column}, Mod, Desc}) ->
    ErrorDesc = Mod:format_error(Desc),
    ?FMT("~s:~w:~w: ~s~s~n", [Source, Line, Column, Extra, ErrorDesc]);
format_error(Source, Extra, {Line, Mod, Desc}) ->
    ErrorDesc = Mod:format_error(Desc),
    ?FMT("~s:~w: ~s~s~n", [Source, Line, Extra, ErrorDesc]);
format_error(Source, Extra, {Mod, Desc}) ->
    ErrorDesc = Mod:format_error(Desc),
    ?FMT("~s: ~s~s~n", [Source, Extra, ErrorDesc]).
