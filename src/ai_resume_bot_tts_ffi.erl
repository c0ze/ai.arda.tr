%% Small helpers for the Text-to-Speech client (ai_resume_bot/tts.gleam).
%%
%% The access token and the "TTS unavailable until" timestamp are cached in
%% persistent_term: both change at most every few minutes (the token lives an
%% hour), so the global GC a persistent_term write triggers is negligible, and
%% reads from every SSE process are free.

-module(ai_resume_bot_tts_ffi).
-export([token_get/0, token_put/2, token_forget/0,
         unavailable_until/0, set_unavailable_until/1,
         now_seconds/0, rescue/1]).

-define(TOKEN, {?MODULE, token}).
-define(DOWN, {?MODULE, unavailable_until}).

%% {ok, {Token, ExpiresAtSeconds}} | {error, nil}
token_get() ->
    case persistent_term:get(?TOKEN, undefined) of
        undefined -> {error, nil};
        Cached -> {ok, Cached}
    end.

token_put(Token, ExpiresAt) ->
    persistent_term:put(?TOKEN, {Token, ExpiresAt}),
    nil.

token_forget() ->
    _ = persistent_term:erase(?TOKEN),
    nil.

unavailable_until() ->
    persistent_term:get(?DOWN, 0).

set_unavailable_until(Seconds) ->
    persistent_term:put(?DOWN, Seconds),
    nil.

now_seconds() ->
    erlang:system_time(second).

%% Run Fun, turning any crash into {error, nil}: a TTS worker must always
%% report back, or the reply would wait for a clip that never comes.
rescue(Fun) ->
    try {ok, Fun()}
    catch _:_ -> {error, nil}
    end.
