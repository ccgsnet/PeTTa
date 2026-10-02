:- begin_tests(das).

:- ensure_loaded('../src/parser.pl').
:- ensure_loaded('../src/das_client.pl').
:- ensure_loaded('../src/das.pl').

:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(library(http/websocket)).
:- use_module(library(http/json)).

%%%%%%%%%% Codec %%%%%%%%%%

test(print_similarity_vars) :-
        Term = ['Similarity', _V1, _V2],
        once(das_to_command_text(Term, Text)),
        once(( sub_string(Text, _, _, _, "Similarity"),
               sub_string(Text, _, _, _, "$_") )).

test(count_only_chunk_becomes_int) :-
        once(das_answer_to_atom("42", Atom)),
        Atom == 42.

test(metta_expression_field_is_parsed) :-
        Dict = json{metta_expression: "(Similarity A B)"},
        once(das_answer_to_atom(Dict, Atom)),
        Atom = ['Similarity', 'A', 'B'].

test(metta_expressions_array_is_parsed) :-
        Dict = json{
                   handles: [["h1"]],
                   assignment: json{'_0': "hA", '_1': "hB"},
                   metta_expressions: [["(Similarity \"human\" \"ent\")"]],
                   assignment_metta: json{'_0': "\"human\"", '_1': "\"ent\""}
               },
        once(das_answer_to_atom(Dict, Atom)),
        Atom = ['Similarity', "human", "ent"].

test(populate_metta_mapping_false_shows_handles, [setup(das_reset_params)]) :-
        once('das-set'([ populate_metta_mapping, false], _)),
        Dict = json{
                   handles: [["h1"]],
                   assignment: json{'_0': "hA", '_1': "hB"},
                   metta_expressions: [["(Similarity \"human\" \"ent\")"]]
               },
        once(das_answer_to_atom(Dict, Atom)),
        Atom = [[assignment, _], [handles, _]].

test(empty_metta_expressions_falls_back_to_handles) :-
        Dict = json{
                   handles: [["h1"]],
                   assignment: json{'_0': "hA"},
                   metta_expressions: [[]]
               },
        once(das_answer_to_atom(Dict, Atom)),
        Atom = [[assignment, _], [handles, _]].

test(query_answer_text_extracts_metta) :-
        Raw = "QueryAnswer<1,2> [[(Similarity \"human\" \"ent\")]] {(V1: \"human\"), (V2: \"ent\")} (0.000000, 0.000000)",
        once(das_answer_to_atom(Raw, Atom)),
        Atom = ['Similarity', "human", "ent"].

test(non_metta_string_stays_symbol) :-
        once(das_answer_to_atom("not-metta-at-all", Atom)),
        Atom == 'not-metta-at-all'.

test(parse_metta_round_trip) :-
        once(sread("(Contains $s (Word bbb))", Parsed)),
        once(das_to_command_text(Parsed, Text)),
        once(sread(Text, Again)),
        Again = ['Contains', S, ['Word', bbb]],
        var(S).

%%%%%%%%%% Local params (das-set / das-get) %%%%%%%%%%

test(das_set_and_get, [setup(das_reset_params)]) :-
        once('das-set'([ context, 'my-ctx'], Ack)),
        once(sub_atom(Ack, _, _, _, context)),
        once('das-get'(params, Out)),
        Out = [params|Pairs],
        once(memberchk([context, 'my-ctx'], Pairs)),
        once(memberchk([use_metta_as_query_tokens, true], Pairs)),
        once(memberchk([populate_metta_mapping, true], Pairs)).

test(das_set_bool_true_false, [setup(das_reset_params)]) :-
        once('das-set'([ count_flag, 'True'], _)),
        das_param(count_flag, true),
        once('das-set'([ count_flag, 'False'], _)),
        das_param(count_flag, false).

test(build_params_merges_local_set, [setup(das_reset_params)]) :-
        once('das-set'([ context, 'my-ctx'], _)),
        once('das-set'([ max_answers, 3], _)),
        once(das_build_params(query, ['Similarity', _A, _B], Params)),
        once(get_dict(query, Params, Query)),
        once(get_dict(tokens, Query, [Token|_])),
        once(sub_string(Token, _, _, _, "Similarity")),
        once(get_dict(context, Params, 'my-ctx')),
        once(get_dict(max_answers, Params, 3)),
        once(get_dict(use_metta_as_query_tokens, Params, true)),
        once(get_dict(populate_metta_mapping, Params, true)).

test(unknown_param_stored_but_not_sent, [setup(das_reset_params)]) :-
        once('das-set'([ totally_unknown_key, foo], _)),
        das_param(totally_unknown_key, foo),
        once(das_build_params(query, ['Similarity', x, y], Params)),
        \+ get_dict(totally_unknown_key, Params, _).

%%%%%%%%%% WS event fold %%%%%%%%%%

test(ws_fold_query_answers_then_completed) :-
        E1 = json{command: "query_answers",
                  params: json{answers: ["(Similarity A B)", "(Similarity C D)"],
                               seq: 1}},
        E2 = json{command: "execution_status",
                  params: json{status: "completed", execution_id: "exec-1"}},
        das_ws_handle_event(E1, [], Acc1, false, ok),
        das_ws_handle_event(E2, Acc1, Acc2, true, ok),
        Acc2 = ["(Similarity A B)", "(Similarity C D)"].

test(ws_fold_error) :-
        E = json{command: "execution_status",
                 params: json{status: "error", message: "boom"}},
        das_ws_handle_event(E, [], [], true, error(boom)).

test(ws_fold_aborted) :-
        E = json{command: "execution_status",
                 params: json{status: "aborted"}},
        das_ws_handle_event(E, [], [], true, aborted).

%%%%%%%%%% Mock HTTP + WebSocket server %%%%%%%%%%

:- dynamic mock_last_post/1.
:- dynamic mock_ws_answers/1.
:- dynamic mock_server_port/1.

mock_ping(_Request) :-
        format('Content-type: text/plain~n~n'),
        format('PONG!').

mock_executions(Request) :-
        http_read_json_dict(Request, Body),
        retractall(mock_last_post(_)),
        assertz(mock_last_post(Body)),
        (   get_dict(command, Body, Cmd0),
            ( atom(Cmd0) -> Cmd = Cmd0 ; atom_string(Cmd, Cmd0) ),
            (Cmd == query ; Cmd == evolution)
        ->  reply_json_dict(json{execution_id: "exec-abc", status: "pending"},
                            [status(202)])
        ;   reply_json_dict(json{error: "Invalid command. Allowed values: query, evolution"},
                            [status(400)])
        ).

mock_status(Id, _Request) :-
        reply_json_dict(json{execution_id: Id,
                             status: "completed",
                             received_count: 2,
                             total_items: 2,
                             duration_ms: 12}).

mock_cancel(Id, _Request) :-
        reply_json_dict(json{execution_id: Id, status: "aborted"}).

mock_ws(_Id, WebSocket) :-
        (   mock_ws_answers(Answers) -> true ; Answers = ["(Similarity A B)"] ),
        ws_send(WebSocket, json(json{command: "execution_status",
                                     params: json{status: "running",
                                                  execution_id: "exec-abc"}})),
        ws_send(WebSocket, json(json{command: "query_answers",
                                     params: json{seq: 1,
                                                  answers: Answers,
                                                  received_count: 1}})),
        ws_send(WebSocket, json(json{command: "execution_status",
                                     params: json{status: "completed",
                                                  execution_id: "exec-abc",
                                                  duration_ms: 5,
                                                  total_items: 1}})),
        ws_close(WebSocket, 1000, "stream complete").

install_mock_handlers :-
        http_handler(root(ping), mock_ping, []),
        http_handler(root('command-router'/executions),
                     mock_executions, [method(post)]),
        http_handler(root('command-router'/executions/Id),
                     mock_status(Id), [method(get)]),
        http_handler(root('command-router'/executions/Id/cancel),
                     mock_cancel(Id), [method(post)]),
        http_handler(root('command-router'/ws/Id),
                     http_upgrade_to_websocket(mock_ws(Id), []),
                     [spawn([])]).

remove_mock_handlers :-
        ignore(http_delete_handler(root(ping))),
        ignore(http_delete_handler(root('command-router'/executions))),
        ignore(forall(http_current_handler(Path, _),
                      (   path_starts_command_router(Path)
                      ->  ignore(http_delete_handler(Path))
                      ;   true
                      ))).

path_starts_command_router(root('command-router'/_)).
path_starts_command_router(root('command-router'/_/_)).
path_starts_command_router(root('command-router'/_/_/_)).

start_mock_server(Port) :-
        retractall(mock_last_post(_)),
        retractall(mock_server_port(_)),
        remove_mock_handlers,
        install_mock_handlers,
        % Unbound Port → SWI picks a free port and unifies it.
        http_server(http_dispatch, [port(Port), workers(2), ip(localhost)]),
        assertz(mock_server_port(Port)).

stop_mock_server :-
        (   mock_server_port(Port)
        ->  ignore(http_stop_server(Port, []))
        ;   true
        ),
        remove_mock_handlers,
        das_clear_config,
        retractall(mock_last_post(_)),
        retractall(mock_ws_answers(_)),
        retractall(mock_server_port(_)).

with_mock_server(Goal) :-
        setup_call_cleanup(
            start_mock_server(Port),
            ( format(atom(Url), 'http://localhost:~w', [Port]),
              das_set_config(das_config{base_url: Url,
                                        connect_timeout_ms: 5000,
                                        request_timeout_ms: 5000,
                                        collect_timeout_ms: 5000}),
              call(Goal)
            ),
            stop_mock_server
        ).

test(http_ping) :-
        with_mock_server((
            once(das_ping(Text)),
            once(( Text == "PONG!" ; Text == 'PONG!' ))
        )).

test(http_start_async_returns_id, [setup(das_reset_params)]) :-
        with_mock_server((
            once(das_build_params(query, ['Similarity', a, b], Params)),
            once(das_start_async(query, Params, Id)),
            once(( Id == 'exec-abc' ; Id == "exec-abc" )),
            once(mock_last_post(Body)),
            once(get_dict(command, Body, Cmd0)),
            once(( atom(Cmd0) -> Cmd = Cmd0 ; atom_string(Cmd, Cmd0) )),
            Cmd == query
        )).

test(evolution_body_matches_sentence_shape, [setup(das_reset_params)]) :-
        once('das-set'([population_size, 50], _)),
        once('das-set'([context, 'my-ctx'], _)),
        Form = [[query, "(Contains $sentence1 (Word \"bbb\"))"],
                [ff, count_letter],
                [cq, ["(Contains $placeholder1 $word1)"]],
                [cr, [[[placeholder1, sentence1]]]],
                [cm, [[[sentence1, word1]]]]],
        once(das_build_evolution_params(Form, Params)),
        once(get_dict(evolution, Params, Evo)),
        once(get_dict(fitness_function_tag, Evo, Tag)),
        Tag == count_letter,
        once(get_dict(query, Evo, Query)),
        once(get_dict(tokens, Query, ["(Contains $sentence1 (Word \"bbb\"))"])),
        once(get_dict(correlation_queries, Evo, [CQ])),
        once(get_dict(tokens, CQ, ["(Contains $placeholder1 $word1)"])),
        once(get_dict(correlation_replacements, Evo, [[["placeholder1", "sentence1"]]])),
        once(get_dict(correlation_mappings, Evo, [[["sentence1", "word1"]]])),
        once(get_dict(population_size, Params, 50)),
        once(get_dict(context, Params, 'my-ctx')),
        once(get_dict(use_metta_as_query_tokens, Params, true)).

test(http_evolution_post, [setup(das_reset_params)]) :-
        Form = [[query, "(Contains $sentence1 (Word \"bbb\"))"],
                [ff, count_letter]],
        with_mock_server((
            once(das_build_evolution_params(Form, Params)),
            once(das_start_async(evolution, Params, Id)),
            once(( Id == 'exec-abc' ; Id == "exec-abc" )),
            once(mock_last_post(Body)),
            once(get_dict(command, Body, Cmd0)),
            once(( atom(Cmd0) -> Cmd = Cmd0 ; atom_string(Cmd, Cmd0) )),
            Cmd == evolution,
            once(get_dict(params, Body, P)),
            once(get_dict(evolution, P, Evo)),
            once(get_dict(fitness_function_tag, Evo, Tag0)),
            once(( atom(Tag0) -> Tag = Tag0 ; atom_string(Tag, Tag0) )),
            Tag == count_letter
        )).

test(http_status_poll) :-
        with_mock_server((
            once(das_status('exec-abc', Status)),
            get_dict(status, Status, St0),
            ( atom(St0) -> St = St0 ; atom_string(St, St0) ),
            St == completed
        )).

test(http_cancel) :-
        with_mock_server((
            once(das_cancel('exec-abc', Body)),
            get_dict(status, Body, St0),
            ( atom(St0) -> St = St0 ; atom_string(St, St0) ),
            St == aborted
        )).

test(http_query_collect_answers, [setup(das_reset_params)]) :-
        retractall(mock_ws_answers(_)),
        assertz(mock_ws_answers(["(Similarity A B)"])),
        with_mock_server((
            findall(A, 'das-query'(['Similarity', _X, _Y], A), As),
            As = [['Similarity', 'A', 'B']],
            once(mock_last_post(Body)),
            once(get_dict(params, Body, Params)),
            once(get_dict(use_metta_as_query_tokens, Params, Flag)),
            once(( Flag == true ; Flag == @(true) ))
        )).

:- end_tests(das).
