%% Single-slot in-memory cache for the latest "recent blog posts" snippet.
%%
%% One public, named ETS table holding exactly one entry under a fixed key.
%% Each refresh overwrites that entry, so the cache can never grow (addresses
%% the "don't let it pile up" requirement). Lives only in the running BEAM
%% instance — Cloud Run is stateless/ephemeral, so a fresh instance just
%% re-populates it from the background refresher. No persistent storage.

-module(blog_cache_ffi).
-export([init/0, put/1, get/0, spawn_loop/1]).

-define(TABLE, blog_cache).
-define(KEY, snippet).

%% Create the table if absent. Idempotent; guards against a creation race.
init() ->
    case ets:whereis(?TABLE) of
        undefined ->
            try
                ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]),
                nil
            catch
                error:badarg -> nil
            end;
        _ ->
            nil
    end.

%% Overwrite the single cached snippet. Fixed key => bounded, never piles up.
put(Snippet) ->
    ets:insert(?TABLE, {?KEY, Snippet}),
    nil.

%% Current snippet, or empty binary if nothing has been cached yet.
get() ->
    case ets:lookup(?TABLE, ?KEY) of
        [{?KEY, Snippet}] -> Snippet;
        [] -> <<>>
    end.

%% Spawn an UNLINKED process (erlang:spawn, not spawn_link) running the given
%% zero-arity fun, so a crash in the refresh loop can never bring down the
%% server. Returns immediately.
spawn_loop(Fun) ->
    spawn(Fun),
    nil.
