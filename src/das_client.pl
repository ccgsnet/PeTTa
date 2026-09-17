%%%%%%%%%% DAS BusCommandRouter HTTP + WebSocket client %%%%%%%%%%
% Speaks the current CommandRouterHttpAPI envelope:
%   POST { "command": "...", "params": { ... } }
%   WS   { "command": "query_answers"|"execution_status", "params": { ... } }

:- use_module(library(http/http_open)).
:- use_module(library(http/http_json)).
:- use_module(library(http/json)).
:- use_module(library(http/websocket)).
:- use_module(library(error)).

:- dynamic das_config_cache/1.

%%%%%%%%%% Configuration %%%%%%%%%%

das_env_or_default(Key, Default, Value) :-
        (   getenv(Key, Raw), Raw \= ''
        ->  Value = Raw
        ;   Value = Default
        ).

das_env_int_or_default(Key, Default, N) :-
        das_env_or_default(Key, Default, Raw),
        (   number(Raw) -> N = Raw
        ;   atom_number(Raw, N) -> true
        ;   catch(number_string(N, Raw), _, N = Default)
        ).

das_config(Config) :-
        (   das_config_cache(Config)
        ->  true
        ;   das_env_or_default('PETTA_DAS_URL', 'http://localhost:40009', Url0),
            das_normalize_url(Url0, BaseUrl),
            das_env_int_or_default('PETTA_DAS_CONNECT_TIMEOUT_MS', 5000, ConnectMs),
            das_env_int_or_default('PETTA_DAS_REQUEST_TIMEOUT_MS', 0, RequestMs),
            das_env_int_or_default('PETTA_DAS_COLLECT_TIMEOUT_MS', 0, CollectMs),
            Config = das_config{
                         base_url: BaseUrl,
                         connect_timeout_ms: ConnectMs,
                         request_timeout_ms: RequestMs,
                         collect_timeout_ms: CollectMs
                     },
            retractall(das_config_cache(_)),
            assertz(das_config_cache(Config))
        ).

%% Test / reset hook (mirrors JeTTa DasClient.clearShared / config override).
das_set_config(Config) :-
        retractall(das_config_cache(_)),
        assertz(das_config_cache(Config)).

das_clear_config :-
        retractall(das_config_cache(_)).

das_normalize_url(Url0, Url) :-
        atom_string(Url0, S0),
        (   sub_string(S0, _, 1, 0, "/")
        ->  sub_string(S0, 0, _, 1, S1)
        ;   S1 = S0
        ),
        atom_string(Url, S1).

das_timeout_opts(Config, Opts) :-
        ConnectMs = Config.connect_timeout_ms,
        RequestMs = Config.request_timeout_ms,
        % SWI http_open timeout is in seconds.
        (   ConnectMs > 0
        ->  ConnectSec is ConnectMs / 1000.0,
            Opts0 = [timeout(ConnectSec)]
        ;   Opts0 = []
        ),
        (   RequestMs > 0
        ->  RequestSec is RequestMs / 1000.0,
            append(Opts0, [timeout(RequestSec)], Opts)
        ;   Opts = Opts0
        ).

%%%%%%%%%% HTTP helpers %%%%%%%%%%

das_url(Path, Full) :-
        das_config(Config),
        atomic_list_concat([Config.base_url, Path], Full).

das_ws_url(Path, Full) :-
        das_config(Config),
        Base = Config.base_url,
        (   sub_atom(Base, 0, 8, _, 'https://')
        ->  atom_concat('https://', Rest, Base),
            atomic_list_concat(['wss://', Rest, Path], Full)
        ;   sub_atom(Base, 0, 7, _, 'http://')
        ->  atom_concat('http://', Rest, Base),
            atomic_list_concat(['ws://', Rest, Path], Full)
        ;   atomic_list_concat([Base, Path], Full)
        ).

das_http_error(Status, Body, Error) :-
        (   is_dict(Body), get_dict(error, Body, Msg)
        ->  true
        ;   ( atom(Body) ; string(Body) )
        ->  Msg = Body
        ;   Msg = Body
        ),
        Error = error(das_http(Status, Msg), _).

%%%%%%%%%% Public client API %%%%%%%%%%

das_ping(Text) :-
        das_url('/ping', Url),
        das_config(Config),
        das_timeout_opts(Config, Opts),
        setup_call_cleanup(
            http_open(Url, In, [status_code(Code)|Opts]),
            read_string(In, _, Text),
            close(In)
        ),
        (   Code == 200
        ->  true
        ;   das_http_error(Code, Text, Error),
            throw(Error)
        ).

%% POST /command-router/executions — returns StatusCode and decoded JSON Body.
das_post_execution(Command, Params, StatusCode, Body) :-
        must_be(atom, Command),
        must_be(dict, Params),
        das_url('/command-router/executions', Url),
        das_config(Config),
        das_timeout_opts(Config, TOpts),
        Request = json{command: Command, params: Params},
        append(TOpts, [post(json(Request)),
                       status_code(StatusCode)], Opts),
        setup_call_cleanup(
            http_open(Url, In, Opts),
            das_read_json_or_text(In, Body),
            close(In)
        ).

das_read_json_or_text(In, Body) :-
        read_string(In, _, S),
        (   S == ""
        ->  Body = json{}
        ;   catch(atom_json_dict(S, Body, []), _, Body = S)
        ).

%% Async start: expects HTTP 202 with execution_id.
das_start_async(Command, Params, ExecutionId) :-
        das_post_execution(Command, Params, StatusCode, Body),
        (   StatusCode == 202,
            is_dict(Body),
            get_dict(execution_id, Body, Id0)
        ->  das_json_atom(Id0, ExecutionId)
        ;   das_http_error(StatusCode, Body, Error),
            throw(Error)
        ).

%% GET /command-router/executions/{id}
das_status(ExecutionId, StatusDict) :-
        atomic_list_concat(['/command-router/executions/', ExecutionId], Path),
        das_url(Path, Url),
        das_config(Config),
        das_timeout_opts(Config, TOpts),
        append(TOpts, [status_code(Code)], Opts),
        setup_call_cleanup(
            http_open(Url, In, Opts),
            das_read_json_or_text(In, Body),
            close(In)
        ),
        (   Code == 200, is_dict(Body)
        ->  StatusDict = Body
        ;   das_http_error(Code, Body, Error),
            throw(Error)
        ).

%% POST /command-router/executions/{id}/cancel
das_cancel(ExecutionId, CancelDict) :-
        atomic_list_concat(['/command-router/executions/', ExecutionId, '/cancel'], Path),
        das_url(Path, Url),
        das_config(Config),
        das_timeout_opts(Config, TOpts),
        append(TOpts, [post(json(json{})), status_code(Code)], Opts),
        setup_call_cleanup(
            http_open(Url, In, Opts),
            das_read_json_or_text(In, Body),
            close(In)
        ),
        (   Code == 200
        ->  ( is_dict(Body) -> CancelDict = Body ; CancelDict = json{result: Body} )
        ;   das_http_error(Code, Body, Error),
            throw(Error)
        ).

%% Open WS, fold events until terminal lifecycle, return answer list.
%% Answers are the raw JSON elements from params.answers arrays.
das_collect(ExecutionId, Answers) :-
        atomic_list_concat(['/command-router/ws/', ExecutionId], Path),
        das_ws_url(Path, WsUrl),
        das_config(Config),
        CollectMs = Config.collect_timeout_ms,
        (   CollectMs > 0
        ->  CollectSec is CollectMs / 1000.0,
            catch(call_with_time_limit(CollectSec, das_collect_ws(WsUrl, Answers)),
                  time_limit_exceeded,
                  throw(error(das_collect_timeout(ExecutionId, CollectMs), _)))
        ;   das_collect_ws(WsUrl, Answers)
        ).

%% POST query/evolution and collect answers over WebSocket.
das_execute_and_collect(Command, Params, Answers) :-
        das_start_async(Command, Params, Id),
        das_collect(Id, Answers).

%%%%%%%%%% WebSocket fold %%%%%%%%%%

das_collect_ws(WsUrl, Answers) :-
        http_open_websocket(WsUrl, WS, []),
        setup_call_cleanup(
            true,
            das_ws_fold(WS, [], Answers),
            ignore(ws_close(WS, 1000, "done"))
        ).

das_ws_fold(WS, Acc, Answers) :-
        ws_receive(WS, Message, [format(json)]),
        (   is_dict(Message),
            get_dict(opcode, Message, Opcode0)
        ->  das_json_atom(Opcode0, Opcode),
            (   Opcode == close
            ->  throw(error(das_ws_ended_without_terminal, _))
            ;   Opcode == text,
                get_dict(data, Message, Event)
            ->  das_ws_handle_event(Event, Acc, Acc1, Done, Outcome),
                (   Done == true
                ->  (   Outcome = ok
                    ->  Answers = Acc1
                    ;   Outcome = error(Msg)
                    ->  throw(error(das_execution_error(Msg), _))
                    ;   Outcome = aborted
                    ->  throw(error(das_execution_aborted, _))
                    )
                ;   das_ws_fold(WS, Acc1, Answers)
                )
            ;   % ignore ping/pong/binary
                das_ws_fold(WS, Acc, Answers)
            )
        ;   Message = close(_)
        ->  throw(error(das_ws_ended_without_terminal, _))
        ;   das_ws_fold(WS, Acc, Answers)
        ).

%% Handle one WS event dict. Acc accumulates answer JSON elements (newest first).
das_ws_handle_event(Event, Acc, Acc1, Done, Outcome) :-
        (   is_dict(Event),
            get_dict(command, Event, Cmd0)
        ->  das_json_atom(Cmd0, Cmd),
            das_ws_handle_command(Cmd, Event, Acc, Acc1, Done, Outcome)
        ;   Acc1 = Acc, Done = false, Outcome = ok
        ).

das_ws_handle_command(query_answers, Event, Acc, Acc1, false, ok) :- !,
        das_ws_extract_answers(Event, Items),
        append(Acc, Items, Acc1).
das_ws_handle_command(execution_status, Event, Acc, Acc, Done, Outcome) :- !,
        das_ws_status(Event, Status0, Msg),
        das_json_atom(Status0, Status),
        (   Status == completed
        ->  Done = true, Outcome = ok
        ;   Status == error
        ->  Done = true,
            (   Msg == '' -> Outcome = error('DAS execution error')
            ;   Outcome = error(Msg)
            )
        ;   Status == aborted
        ->  Done = true, Outcome = aborted
        ;   Done = false, Outcome = ok
        ).
das_ws_handle_command(_, _Event, Acc, Acc, false, ok).

%% Normalize JSON string/atom keys to atoms for == comparisons.
das_json_atom(V, A) :-
        (   atom(V) -> A = V
        ;   string(V) -> atom_string(A, V)
        ;   A = V
        ).

das_ws_extract_answers(Event, Items) :-
        (   get_dict(params, Event, Params),
            is_dict(Params),
            get_dict(answers, Params, Raw)
        ->  (   is_list(Raw) -> Items = Raw ; Items = [Raw] )
        ;   Items = []
        ).

das_ws_status(Event, Status, Msg) :-
        (   get_dict(params, Event, Params), is_dict(Params)
        ->  (   get_dict(status, Params, Status) -> true ; Status = '' ),
            (   get_dict(message, Params, Msg0) -> true
            ;   get_dict(error_message, Params, Msg0) -> true
            ;   Msg0 = ''
            ),
            (   string(Msg0) -> atom_string(Msg, Msg0) ; Msg = Msg0 )
        ;   Status = '', Msg = ''
        ).
