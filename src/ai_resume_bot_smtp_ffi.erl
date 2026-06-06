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
                %% Verify the server certificate (gen_smtp's default does not),
                %% pin modern TLS, and check the hostname. Without this the
                %% STARTTLS session is open to a MITM on outbound credentials.
                {tls_options, [
                    {verify, verify_peer},
                    {cacerts, public_key:cacerts_get()},
                    {versions, ['tlsv1.2', 'tlsv1.3']},
                    {customize_hostname_check, [
                        {match_fun,
                            public_key:pkix_verify_hostname_match_fun(https)}
                    ]}
                ]},
                {auth, always}
            ],
            Email = {User, [To], Body},
            send_with_timeout(Email, Options, 30000)
    end.

%% Run the (blocking) send in a worker process so a hung SMTP connection can't
%% block the chat reply indefinitely. The result is still returned
%% synchronously, so the server / stream handlers can report success vs failure
%% honestly (rather than a fire-and-forget that always claims success).
send_with_timeout(Email, Options, TimeoutMs) ->
    Parent = self(),
    {Pid, Mon} = spawn_monitor(fun() ->
        Parent ! {smtp_result, self(), do_send(Email, Options)}
    end),
    receive
        {smtp_result, Pid, Result} ->
            erlang:demonitor(Mon, [flush]),
            Result;
        {'DOWN', Mon, process, Pid, DownReason} ->
            {error, {send_failed, iolist_to_binary(
                io_lib:format("smtp worker crashed: ~p", [DownReason])
            )}}
    after TimeoutMs ->
        erlang:demonitor(Mon, [flush]),
        exit(Pid, kill),
        {error, {send_failed, <<"smtp send timed out">>}}
    end.

do_send(Email, Options) ->
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
    end.
