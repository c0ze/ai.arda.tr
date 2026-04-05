%% Tiny FFI helpers for ai_resume_bot.gleam that cannot be expressed
%% directly as a single @external call.

-module(ai_resume_bot_ffi).
-export([halt_flush/1]).

%% Flush stdio then halt. Without the flush option, io:format output from
%% right before halt can be lost before it reaches the terminal.
halt_flush(Code) ->
    erlang:halt(Code, [{flush, true}]).
