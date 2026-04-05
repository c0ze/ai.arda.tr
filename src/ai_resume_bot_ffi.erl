%% Tiny FFI helpers for ai_resume_bot.gleam that cannot be expressed
%% directly as a single @external call.

-module(ai_resume_bot_ffi).
-export([halt_flush/1, shell/2]).

%% Flush stdio then halt. Without the flush option, io:format output from
%% right before halt can be lost before it reaches the terminal.
halt_flush(Code) ->
    erlang:halt(Code, [{flush, true}]).

%% Run a shell command in the given working directory, streaming its stdout
%% and stderr to the current group leader so the user sees it live. Returns
%% {ok, nil} on exit status 0, {error, ExitCode} otherwise.
shell(Cwd, Cmd) ->
    CwdStr = binary_to_list(Cwd),
    CmdStr = binary_to_list(Cmd),
    Port = erlang:open_port(
        {spawn, "/bin/sh -c '" ++ escape(CmdStr) ++ "'"},
        [stream, exit_status, stderr_to_stdout, {cd, CwdStr}, binary]
    ),
    collect(Port).

collect(Port) ->
    receive
        {Port, {data, Data}} ->
            io:put_chars(Data),
            collect(Port);
        {Port, {exit_status, 0}} ->
            {ok, nil};
        {Port, {exit_status, Code}} ->
            {error, Code}
    end.

escape(S) ->
    lists:flatten(lists:map(fun($') -> "'\\''"; (C) -> C end, S)).
