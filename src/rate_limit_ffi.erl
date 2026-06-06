%% Fixed-window per-key rate limiter backed by ETS.
%%
%% A single public, named ETS table holds one counter per {Key, WindowStart}
%% bucket. `ets:update_counter/4` is atomic, so this is safe to call from many
%% request processes concurrently without an actor/serialization bottleneck.
%%
%% Old buckets (from elapsed windows) are swept opportunistically (~1% of
%% calls) so memory stays bounded by the number of distinct active clients.

-module(rate_limit_ffi).
-export([init/0, allow/4, now_ms/0]).

-define(TABLE, rate_limit_buckets).

%% Create the table if it does not already exist. Idempotent.
init() ->
    case ets:whereis(?TABLE) of
        undefined ->
            %% Guard against a race where two processes create it at once.
            try
                ets:new(?TABLE, [
                    named_table, public, set, {write_concurrency, true}
                ]),
                nil
            catch
                error:badarg -> nil
            end;
        _ ->
            nil
    end.

%% allow(Key, Limit, WindowMs, NowMs) -> boolean()
%%   Returns true if the request is within the limit for the current window.
allow(Key, Limit, WindowMs, NowMs) when WindowMs > 0 ->
    WindowStart = NowMs - (NowMs rem WindowMs),
    BucketKey = {Key, WindowStart},
    %% Atomically bump (and create-with-default) the counter at position 2.
    Count = ets:update_counter(?TABLE, BucketKey, {2, 1}, {BucketKey, 0}),
    maybe_sweep(WindowStart),
    Count =< Limit.

%% Current wall-clock time in milliseconds.
now_ms() ->
    erlang:system_time(millisecond).

%% Occasionally drop buckets from windows older than the current one.
maybe_sweep(WindowStart) ->
    case rand:uniform(100) of
        1 ->
            %% delete every object whose key's WindowStart is < the current one
            ets:select_delete(
                ?TABLE,
                [{{{'_', '$1'}, '_'}, [{'<', '$1', WindowStart}], [true]}]
            ),
            ok;
        _ ->
            ok
    end.
