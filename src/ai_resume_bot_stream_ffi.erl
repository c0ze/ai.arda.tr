%% Streaming HTTP client for Gemini's streamGenerateContent endpoint.
%%
%% Makes an HTTP POST request and streams the response body back to a
%% caller-provided Gleam Subject as a series of messages:
%%   {chunk, BinaryData}    — a piece of the response body
%%   done                   — stream completed successfully
%%   {stream_error, Reason} — stream failed
%%
%% Uses Erlang's built-in httpc with {sync, false} so we receive the
%% body incrementally via mailbox messages.

-module(ai_resume_bot_stream_ffi).
-export([stream_post/3]).

%% stream_post(Url, Body, Subject)
%%   Url     :: binary()  — full URL including ?key=...&alt=sse
%%   Body    :: binary()  — JSON request body
%%   Subject :: gleam Subject (an erlang process wrapped by gleam/otp)
%%
%% Spawns a process that makes the request and forwards chunks to Subject.
%% Returns {ok, nil} immediately.
stream_post(Url, Body, Subject) ->
    %% Ensure inets is started (needed for httpc)
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    spawn_link(fun() -> do_stream(Url, Body, Subject) end),
    {ok, nil}.

do_stream(Url, Body, Subject) ->
    UrlStr = binary_to_list(Url),
    Headers = [{"content-type", "application/json"}],
    Request = {UrlStr, Headers, "application/json", Body},
    HttpOpts = [{timeout, 120000}, {connect_timeout, 10000}],
    Opts = [{sync, false}, {stream, self}],
    case httpc:request(post, Request, HttpOpts, Opts) of
        {ok, RequestId} ->
            receive_loop(RequestId, Subject);
        {error, Reason} ->
            send_msg(Subject, {stream_error, iolist_to_binary(
                io_lib:format("httpc request failed: ~p", [Reason])
            )})
    end.

receive_loop(RequestId, Subject) ->
    receive
        {http, {RequestId, stream_start, _Headers}} ->
            receive_loop(RequestId, Subject);
        {http, {RequestId, stream_start, _Headers, _Pid}} ->
            receive_loop(RequestId, Subject);
        {http, {RequestId, stream, BinPart}} ->
            send_msg(Subject, {chunk, BinPart}),
            receive_loop(RequestId, Subject);
        {http, {RequestId, stream_end, _Headers}} ->
            send_msg(Subject, done);
        {http, {RequestId, {error, Reason}}} ->
            send_msg(Subject, {stream_error, iolist_to_binary(
                io_lib:format("stream error: ~p", [Reason])
            )});
        {http, {RequestId, {{_, StatusCode, _}, _Headers, ResponseBody}}} ->
            %% Non-streaming response (error case)
            case StatusCode of
                200 ->
                    send_msg(Subject, {chunk, iolist_to_binary(ResponseBody)}),
                    send_msg(Subject, done);
                _ ->
                    send_msg(Subject, {stream_error, iolist_to_binary(
                        io_lib:format("HTTP ~p: ~s", [StatusCode, ResponseBody])
                    )})
            end
    after 120000 ->
        send_msg(Subject, {stream_error, <<"stream timeout">>})
    end.

%% Send a message to a Gleam Subject.
%% gleam_erlang compiles Subject(owner, tag) to {subject, Pid, Tag}.
%% process.send(subject, msg) does raw_send(pid, {tag, msg}).
send_msg({subject, Pid, Tag}, Msg) ->
    erlang:send(Pid, {Tag, Msg}).
