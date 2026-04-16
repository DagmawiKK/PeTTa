:- use_module(library(gensym)).
:- use_module(library(http/http_open)).
:- use_module(library(http/http_json)).
:- use_module(library(option)).

:- dynamic http_job/2.

% Public API (function convention: last argument is output)
http_get(Url, Out) :- http_request_sync(Url, get, [], [], Out).
http_head(Url, Out) :- http_request_sync(Url, head, [], [], Out).
http_options(Url, Out) :- http_request_sync(Url, options, [], [], Out).
http_delete(Url, Out) :- http_request_sync(Url, delete, [], [], Out).
http_post(Url, Body, Out) :- http_request_sync(Url, post, Body, [], Out).
http_put(Url, Body, Out) :- http_request_sync(Url, put, Body, [], Out).
http_patch(Url, Body, Out) :- http_request_sync(Url, patch, Body, [], Out).

http_request(Url, Method, Body, Options, Out) :-
    normalize_method(Method, M),
    normalize_body(Body, B),
    normalize_http_options(Options, O),
    http_request_sync(Url, M, B, O, Out).

http_submit(Url, Method, Body, Options, JobId) :-
    normalize_method(Method, M),
    normalize_body(Body, B),
    normalize_http_options(Options, O),
    gensym(http_job_, JobId),
    message_queue_create(Q),
    thread_create(http_worker(JobId, Q, Url, M, B, O), _, [detached(false)]),
    asserta(http_job(JobId, Q)).

http_poll(JobId, Out) :-
    ( http_job(JobId, Q)
    -> ( thread_get_message(Q, Msg, [timeout(0)])
       -> finalize_job(JobId, Msg, Out)
       ; Out = pending
       )
    ; Out = err(error(not_found, "job_not_found", []))
    ).

http_await(JobId, TimeoutSeconds, Out) :-
    ( http_job(JobId, Q)
    -> ( number(TimeoutSeconds), TimeoutSeconds >= 0
       -> true
       ; TimeoutSeconds = 30
       ),
       ( thread_get_message(Q, Msg, [timeout(TimeoutSeconds)])
       -> finalize_job(JobId, Msg, Out)
       ; Out = err(error(timeout, "await_timeout", [job_id-JobId]))
       )
    ; Out = err(error(not_found, "job_not_found", []))
    ).

http_cancel(JobId, Out) :-
    ( retract(http_job(JobId, Q))
    -> catch(message_queue_destroy(Q), _, true),
       Out = ok(cancelled)
    ; Out = err(error(not_found, "job_not_found", []))
    ).

http_is_ok(ok(_), true).
http_is_ok(err(_), false).

http_status(ok(response(Fields)), Status) :-
    memberchk(status-Status, Fields), !.
http_status(_, -1).

http_body(ok(response(Fields)), Body) :-
    memberchk(body-Body, Fields), !.
http_body(_, "").

http_error_kind(err(error(Kind, _, _)), Kind) :- !.
http_error_kind(_, none).

http_worker(JobId, Queue, Url, Method, Body, Options) :-
    catch(
        http_request_sync(Url, Method, Body, Options, Result),
        Error,
        classify_exception(Error, Result)
    ),
    thread_send_message(Queue, done(Result)),
    ( http_job(JobId, Queue) -> true ; true ).

http_request_sync(Url, Method, Body, Options, Out) :-
    get_time(T0),
    build_http_options(Method, Body, Options, HttpOptions),
    catch(
        do_http_request(Url, HttpOptions, StatusCode, ResponseBody),
        Error,
        ( classify_exception(Error, Out), ! )
    ),
    ( var(Out)
    -> get_time(T1),
       DurationMs is round((T1 - T0) * 1000),
       Headers = [],
       Status = StatusCode,
       FinalUrl = Url,
       Out = ok(response([
           status-Status,
           headers-Headers,
           body-ResponseBody,
           duration_ms-DurationMs,
           final_url-FinalUrl,
           method-Method
       ]))
    ; true
    ).

do_http_request(Url, HttpOptions, StatusCode, ResponseBody) :-
    setup_call_cleanup(
        http_open(Url, Stream, [status_code(StatusCode)|HttpOptions]),
        read_string(Stream, _, ResponseBody),
        close(Stream)
    ).

build_http_options(Method, Body, Options, HttpOptions) :-
    option(timeout(Timeout), Options, 30),
    option(max_redirect(MaxRedirect), Options, 10),
    option(headers(Headers), Options, []),
    option(query(Query), Options, []),
    body_option(Body, BodyOpts),
    append([
        [method(Method), timeout(Timeout), max_redirect(MaxRedirect)],
        BodyOpts,
        [request_header(Headers), search(Query)]
    ], HttpOptions).

body_option([], []) :- !.
body_option(json(JsonTerm), [json(JsonTerm)]) :- !.
body_option(form(FormPairs), [form_data(FormPairs)]) :- !.
body_option(raw(Text), [post(string(Text))]) :- !.
body_option(Text, [post(string(Text))]) :-
    ( string(Text) ; atom(Text) ), !.
body_option(_, []).

normalize_method(MethodIn, MethodOut) :-
    ( atom(MethodIn)
    -> downcase_atom(MethodIn, MethodOut)
    ; MethodOut = get
    ),
    memberchk(MethodOut, [get,post,put,patch,delete,head,options]), !.
normalize_method(_, get).

normalize_body(none, []) :- !.
normalize_body([], []) :- !.
normalize_body(Body, Body).

normalize_http_options(OptionsIn, OptionsOut) :-
    ( is_list(OptionsIn) -> OptionsOut = OptionsIn ; OptionsOut = [] ).

classify_exception(error(io_error(read, _), _), err(error(read_error, "io_read_error", []))) :- !.
classify_exception(error(io_error(write, _), _), err(error(write_error, "io_write_error", []))) :- !.
classify_exception(error(existence_error(host, Host), _), err(error(dns_error, "host_not_found", [host-Host]))) :- !.
classify_exception(error(socket_error(eai_noname, _), _), err(error(dns_error, "host_not_found", []))) :- !.
classify_exception(error(socket_error(ehostunreach, _), _), err(error(dns_error, "host_unreachable", []))) :- !.
classify_exception(error(socket_error(econnrefused, _), _), err(error(connect_error, "connection_refused", []))) :- !.
classify_exception(error(socket_error(etimedout, _), _), err(error(connect_timeout, "connection_timeout", []))) :- !.
classify_exception(error(syntax_error(_), _), err(error(malformed_url, "malformed_url", []))) :- !.
classify_exception(error(http_reply(not_found(_)), _), err(error(http_not_found, "http_not_found", []))) :- !.
classify_exception(error(http_reply(forbidden(_)), _), err(error(http_forbidden, "http_forbidden", []))) :- !.
classify_exception(error(http_reply(unavailable(_)), _), err(error(http_unavailable, "http_unavailable", []))) :- !.
classify_exception(error(http_reply(bad_request(_)), _), err(error(http_bad_request, "http_bad_request", []))) :- !.
classify_exception(Error, err(error(unknown, Msg, [raw-Error]))) :-
    term_string(Error, Msg).

finalize_job(JobId, done(Result), Result) :-
    ( retract(http_job(JobId, Q))
    -> catch(message_queue_destroy(Q), _, true)
    ; true
    ).
