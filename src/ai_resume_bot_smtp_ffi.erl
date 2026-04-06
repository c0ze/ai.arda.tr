%% Thin Erlang shim that wraps gen_smtp_client:send_blocking/2 for the
%% ai_resume_bot/smtp.gleam module.
%%
%% Returns {ok, nil} on success or {error, {send_failed, Reason}} so the
%% Gleam side can pattern-match on a stable shape regardless of the
%% underlying gen_smtp error tuple.
%%
%% gen_smtp is available on hex as `gen_smtp`. Add it to gleam.toml
%% erlang.extra_applications once vendored; for local dev without gen_smtp
%% installed, this module falls back to logging the payload so the rest of
%% the pipeline stays testable.

-module(ai_resume_bot_smtp_ffi).
-export([send/4]).

send(User, Password, To, Body) ->
    case code:which(gen_smtp_client) of
        non_existing ->
            logger:warning(
              "gen_smtp_client not available; contact email dropped. "
              "user=~s to=~s bytes=~p",
              [User, To, byte_size(Body)]
            ),
            {error, {send_failed, <<"gen_smtp_client not available">>}};
        _ ->
            Options = [
                {relay, <<"smtp.gmail.com">>},
                {port, 587},
                {username, User},
                {password, Password},
                {tls, always},
                {auth, always}
            ],
            Email = {User, [To], Body},
            try gen_smtp_client:send_blocking(Email, Options) of
                Receipt when is_binary(Receipt) ->
                    {ok, nil};
                {error, Type, Message} ->
                    {error, {send_failed, iolist_to_binary(
                        io_lib:format("~p: ~p", [Type, Message])
                    )}};
                {error, Reason} ->
                    {error, {send_failed, iolist_to_binary(
                        io_lib:format("~p", [Reason])
                    )}}
            catch
                Class:Reason:_Stack ->
                    {error, {send_failed, iolist_to_binary(
                        io_lib:format("~p:~p", [Class, Reason])
                    )}}
            end
    end.
