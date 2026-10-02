%%%%%%%%%% DAS MeTTa-facing ops + answer codec %%%%%%%%%%
% Ports JeTTa DasOps / DasAtomCodec over the current DAS HTTP API.
% das-set / das-get use a local param map (HTTP get/set are not allowed).

:- ensure_loaded(das_client).

:- dynamic das_param/2.

%%%%%%%%%% Known DAS query params (sent on POST; others stored locally only) %%%%%%%%%%

das_known_param_key(use_metta_as_query_tokens).
das_known_param_key(populate_metta_mapping).
das_known_param_key(context).
das_known_param_key(max_answers).
das_known_param_key(max_bundle_size).
das_known_param_key(unique_assignment_flag).
das_known_param_key(attention_update).
das_known_param_key(attention_correlation).
das_known_param_key(attention_focus_strictness).
das_known_param_key(allow_incomplete_chain_path).
das_known_param_key(public_key_tokens).
das_known_param_key(positive_importance_flag).
das_known_param_key(disregard_importance_flag).
das_known_param_key(unique_value_flag).
das_known_param_key(count_flag).
das_known_param_key(population_size).
das_known_param_key(max_generations).
das_known_param_key(elitism_rate).
das_known_param_key(selection_rate).

%% Client-side scorer for fitness tag remote_fitness_function.
%% das_remote_fitness(+AnswerJson, -Float). Assert or define a clause to handle eval_fitness.
:- multifile das_remote_fitness/2.

%%%%%%%%%% Defaults (MeTTa-friendly) %%%%%%%%%%

das_init_defaults :-
        (   das_param(use_metta_as_query_tokens, _) -> true
        ;   assertz(das_param(use_metta_as_query_tokens, true))
        ),
        (   das_param(populate_metta_mapping, _) -> true
        ;   assertz(das_param(populate_metta_mapping, true))
        ).

:- das_init_defaults.

das_reset_params :-
        retractall(das_param(_, _)),
        das_init_defaults.

%%%%%%%%%% Local param store %%%%%%%%%%

'das-set'(Command, Out) :-
        das_parse_set_command(Command, Key, Value),
        retractall(das_param(Key, _)),
        assertz(das_param(Key, Value)),
        format(atom(Out), "Parameter updated: '~w': ~w", [Key, Value]).

'das-get'(What, Out) :-
        das_key_atom(What, Target),
        (   Target == params
        ->  findall([Key, Value], das_param(Key, Value), Pairs),
            Out = [params|Pairs]
        ;   format(atom(Msg), "das-get expects params, got: ~w", [Target]),
            throw(error(das_bad_get(Msg), _))
        ).

das_parse_set_command([Key, Value], KeyAtom, NormValue) :- !,
        das_key_atom(Key, KeyAtom),
        das_normalize_param_value(Value, NormValue).
das_parse_set_command(Other, _, _) :-
        swrite(Other, S),
        format(atom(Msg), "das-set expects (<key> <value>), got: ~w", [S]),
        throw(error(das_bad_set(Msg), _)).

das_key_atom(Key, Atom) :-
        (   atom(Key) -> Atom = Key
        ;   string(Key) -> atom_string(Atom, Key)
        ;   term_to_atom(Key, Atom)
        ).

das_normalize_param_value(true, true) :- !.
das_normalize_param_value(false, false) :- !.
das_normalize_param_value('True', true) :- !.
das_normalize_param_value('False', false) :- !.
das_normalize_param_value(V, V).

%%%%%%%%%% Build query/evolution params dict %%%%%%%%%%

das_build_params(CommandKey, PatternOrForm, Params) :-
        das_to_command_text(PatternOrForm, Text),
        findall(K-V, (das_param(K, V), das_known_param_key(K), K \== CommandKey), Pairs),
        dict_create(Base, json, Pairs),
        Query = json{syntax: "metta", tokens: [Text]},
        put_dict(CommandKey, Base, Query, Params).

%% Evolution POST body matches CommandRouter HTTP (sentence_evolution.cc):
%%   params.evolution = { query, fitness_function_tag, correlation_* }
%%   plus scalar router params (context, population_size, ...).
%% MeTTa form is a list of labeled clauses:
%%   (query <expr>|"(Contains $sentence1 ...)")
%%   (ff <tag>)
%%   (cq (<expr> ...))
%%   (cr (((from to) ...)))
%%   (cm (((from to) ...)))
%% String expressions keep $names; structured terms are printed with swrite.
das_build_evolution_params(Form, Params) :-
        (   is_list(Form)
        ->  true
        ;   throw(error(das_bad_evolution('evolution form must be a list of labeled clauses'), _))
        ),
        das_evolution_object(Form, Evo),
        findall(K-V, (das_param(K, V), das_known_param_key(K)), Pairs),
        dict_create(Base, json, Pairs),
        put_dict(evolution, Base, Evo, Params0),
        % Query objects use syntax "metta"; the flag must agree or DAS rejects the POST.
        put_dict(use_metta_as_query_tokens, Params0, true, Params).

das_evolution_object(Clauses, Evo) :-
        das_evolution_query_text(Clauses, QueryText),
        das_evolution_fitness_tag(Clauses, Tag),
        Evo0 = json{query: json{syntax: "metta", tokens: [QueryText]},
                    fitness_function_tag: Tag},
        das_evolution_optional(Clauses, cq, correlation_queries, das_cq_json, Evo0, Evo1),
        das_evolution_optional(Clauses, cr, correlation_replacements, das_pair_groups_json, Evo1, Evo2),
        das_evolution_optional(Clauses, cm, correlation_mappings, das_pair_groups_json, Evo2, Evo).

das_evolution_optional(Clauses, Label, Key, Builder, In, Out) :-
        (   das_evolution_clause(Clauses, Label, Body)
        ->  call(Builder, Body, Json),
            put_dict(Key, In, Json, Out)
        ;   Out = In
        ).

das_evolution_query_text(Clauses, Text) :-
        (   das_evolution_clause(Clauses, query, Expr)
        ->  das_metta_text(Expr, Text)
        ;   throw(error(das_bad_evolution('evolution form requires (query <expr>) or (q <expr>)'), _))
        ).

das_evolution_fitness_tag(Clauses, Tag) :-
        (   das_evolution_clause(Clauses, ff, Tag0)
        ->  das_key_atom(Tag0, Tag),
            (   atom_chars(Tag, Cs), member(C, Cs), memberchk(C, [' ', '\t', '\n', '\r', '(', ')', '"'])
            ->  throw(error(das_bad_evolution('fitness tag must not contain whitespace, parentheses, or quotes'), _))
            ;   true
            )
        ;   throw(error(das_bad_evolution('evolution form requires (ff <tag>)'), _))
        ).

das_evolution_clause(Clauses, Kind, Body) :-
        member(Clause, Clauses),
        Clause = [Label, Body],
        das_evolution_label(Label, Kind),
        !.

das_evolution_label(Label0, Kind) :-
        das_key_atom(Label0, Label),
        (   (Label == query ; Label == q) -> Kind = query
        ;   (Label == ff ; Label == fitness_function_tag ; Label == 'fitness-function-tag') -> Kind = ff
        ;   (Label == cq ; Label == correlation_queries ; Label == 'correlation-queries') -> Kind = cq
        ;   (Label == cr ; Label == correlation_replacements ; Label == 'correlation-replacements') -> Kind = cr
        ;   (Label == cm ; Label == correlation_mappings ; Label == 'correlation-mappings') -> Kind = cm
        ).

das_metta_text(S, S) :- string(S), !.
das_metta_text(A, S) :- atom(A), !, atom_string(A, S).
das_metta_text(Term, Text) :- das_to_command_text(Term, Text).

das_cq_json(Exprs, Json) :-
        must_be(list, Exprs),
        maplist(das_metta_token_object, Exprs, Json).

das_metta_token_object(Expr, json{syntax: "metta", tokens: [Text]}) :-
        das_metta_text(Expr, Text).

das_pair_groups_json(Groups, Json) :-
        must_be(list, Groups),
        maplist(das_pair_group_json, Groups, Json).

das_pair_group_json(Pairs, JsonPairs) :-
        must_be(list, Pairs),
        maplist(das_pair_json, Pairs, JsonPairs).

das_pair_json([A, B], [AS, BS]) :- !,
        das_metta_text(A, AS),
        das_metta_text(B, BS).
das_pair_json(Other, _) :-
        throw(error(das_bad_evolution('correlation pair must be (from to)'), Other)).

%%%%%%%%%% Multivalued query / evolution %%%%%%%%%%

'das-query'(Pattern, Out) :-
        das_build_params(query, Pattern, Params),
        das_execute_and_collect(query, Params, Answers),
        member(Raw, Answers),
        das_answer_to_atom(Raw, Out).

'das-evolution'(Form, Out) :-
        das_build_evolution_params(Form, Params),
        das_execute_and_collect(evolution, Params, Answers),
        member(Raw, Answers),
        das_answer_to_atom(Raw, Out).

'das-query-start'(Pattern, Out) :-
        das_build_params(query, Pattern, Params),
        das_start_async(query, Params, Id),
        Out = Id.

'das-evolution-start'(Form, Out) :-
        das_build_evolution_params(Form, Params),
        das_start_async(evolution, Params, Id),
        Out = Id.

'das-collect'(ExecutionId0, Out) :-
        das_execution_id(ExecutionId0, Id),
        das_collect(Id, Answers),
        member(Raw, Answers),
        das_answer_to_atom(Raw, Out).

'das-status'(ExecutionId0, Out) :-
        das_execution_id(ExecutionId0, Id),
        das_status(Id, StatusDict),
        das_status_to_atom(StatusDict, Out).

'das-cancel'(ExecutionId0, Out) :-
        das_execution_id(ExecutionId0, Id),
        das_cancel(Id, CancelDict),
        das_cancel_to_atom(CancelDict, Out).

das_execution_id(Id, Atom) :-
        (   atom(Id) -> Atom = Id
        ;   string(Id) -> atom_string(Atom, Id)
        ;   number(Id) -> atom_number(Atom, Id)
        ;   swrite(Id, S), atom_string(Atom, S)
        ).

%%%%%%%%%% Codec: atom -> command text %%%%%%%%%%

das_to_command_text(Term, Text) :-
        once(swrite(Term, Text0)),
        (   string(Text0) -> Text = Text0
        ;   atom(Text0) -> atom_string(Text0, Text)
        ;   term_to_atom(Text0, A), atom_string(A, Text)
        ).

%%%%%%%%%% Codec: answer JSON -> MeTTa atom %%%%%%%%%%

das_answer_to_atom(Element, Atom) :-
        (   string(Element)
        ->  das_answer_string(Element, Atom)
        ;   atom(Element)
        ->  atom_string(Element, S),
            das_answer_string(S, Atom)
        ;   number(Element)
        ->  Atom = Element
        ;   is_dict(Element)
        ->  das_answer_dict(Element, Atom)
        ;   is_list(Element)
        ->  maplist(das_answer_to_atom, Element, Parts),
            Atom = Parts
        ;   term_to_atom(Element, A),
            Atom = A
        ).

das_answer_string(S, Atom) :-
        (   number_string(N, S)
        ->  Atom = N
        ;   das_parse_query_answer_text(S, Atom)
        ->  true
        ;   das_looks_like_metta(S),
            catch(sread(S, Atom), _, fail)
        ->  true
        ;   atom_string(Atom, S)
        ).

das_answer_dict(Dict, Atom) :-
        (   das_want_metta_answers,
            das_dict_metta(Dict, Metta),
            Metta \= "",
            catch(sread(Metta, Atom), _, fail)
        ->  true
        ;   (   get_dict(assignment, Dict, Asg) ; get_dict(assignments, Dict, Asg) )
        ->  das_json_to_atom(Asg, AsgAtom),
            (   ( get_dict(handles, Dict, H) ; get_dict(handle, Dict, H) )
            ->  das_json_to_atom(H, HAtom),
                Atom = [[assignment, AsgAtom], [handles, HAtom]]
            ;   Atom = [assignment, AsgAtom]
            )
        ;   (   get_dict(handles, Dict, H) ; get_dict(handle, Dict, H) )
        ->  das_json_to_atom(H, HAtom),
            Atom = [handles, HAtom]
        ;   atom_json_dict(JsonText, Dict, []),
            atom_string(Atom, JsonText)
        ).

%% When populate_metta_mapping is false, skip MeTTa fields and keep handles.
das_want_metta_answers :-
        (   das_param(populate_metta_mapping, V)
        ->  V \== false, V \== 'False'
        ;   true
        ).

%% Prefer DAS QueryAnswer::to_json MeTTa fields, then legacy JeTTa-style keys.
das_dict_metta(Dict, Metta) :-
        get_dict(metta_expressions, Dict, Groups),
        das_metta_expressions_first(Groups, Metta),
        !.
das_dict_metta(Dict, Metta) :-
        (   get_dict(metta, Dict, M) ; get_dict(metta_expression, Dict, M)
        ;   get_dict(mettaExpression, Dict, M) ; get_dict(expression, Dict, M)
        ;   get_dict(metta_mapping, Dict, M)
        ),
        !,
        das_metta_value_string(M, Metta).

%% metta_expressions is [[expr, ...], ...] — one group per handle group.
das_metta_expressions_first(Groups, Metta) :-
        is_list(Groups),
        member(Group, Groups),
        is_list(Group),
        Group \= [],
        (   Group = [One]
        ->  das_metta_value_string(One, Metta)
        ;   maplist(das_metta_value_string, Group, Strs),
            atomic_list_concat(Strs, ' ', Joined0),
            format(string(Metta), "(~w)", [Joined0])
        ),
        !.

das_metta_value_string(M, Metta) :-
        (   string(M) -> Metta = M
        ;   atom(M) -> atom_string(M, Metta)
        ;   is_list(M) ->
            maplist(das_metta_value_string, M, Parts),
            atomic_list_concat(Parts, ' ', Joined),
            format(string(Metta), "(~w)", [Joined])
        ;   atom_json_dict(A, M, []), atom_string(Metta, A)
        ).

%% QueryAnswer<...> [[(MeTTa...)]] ...
das_parse_query_answer_text(Text, Atom) :-
        (   string(Text) -> S = Text
        ;   atom(Text) -> atom_string(Text, S)
        ;   term_to_atom(Text, A), atom_string(A, S)
        ),
        sub_string(S, 0, _, _, "QueryAnswer"),
        das_extract_double_bracket(S, Metta),
        catch(sread(Metta, Atom), _, fail).

das_extract_double_bracket(Text, Content) :-
        sub_string(Text, Start, 2, _, "[["),
        After is Start + 2,
        sub_string(Text, After, _, 0, Rest),
        sub_string(Rest, End, 2, _, "]]"),
        sub_string(Rest, 0, End, _, Content0),
        normalize_space(string(Content), Content0).

das_looks_like_metta(Text) :-
        normalize_space(string(T), Text),
        (   sub_string(T, 0, 1, _, "(")
        ;   sub_string(T, 0, 1, _, "!")
        ;   sub_string(T, 0, 1, _, "$")
        ;   sub_string(T, 0, 1, _, "\"")
        ).

das_json_to_atom(null, null) :- !.
das_json_to_atom(true, true) :- !.
das_json_to_atom(false, false) :- !.
das_json_to_atom(N, N) :- number(N), !.
das_json_to_atom(S, Atom) :-
        string(S), !,
        (   number_string(N, S) -> Atom = N
        ;   das_looks_like_metta(S), catch(sread(S, Atom), _, fail) -> true
        ;   atom_string(Atom, S)
        ).
das_json_to_atom(A, A) :- atom(A), !.
das_json_to_atom(List, Atom) :-
        is_list(List), !,
        maplist(das_json_to_atom, List, Atom).
das_json_to_atom(Dict, Atom) :-
        is_dict(Dict), !,
        dict_pairs(Dict, _, Pairs),
        findall([K, V],
                ( member(K0-V0, Pairs),
                  das_key_atom(K0, K),
                  das_json_to_atom(V0, V)
                ),
                Flat),
        append(Flat, FlatList),
        Atom = FlatList.

%%%%%%%%%% Status / cancel -> MeTTa atoms %%%%%%%%%%

das_status_to_atom(Dict, Out) :-
        das_dict_get(Dict, status, Status, unknown),
        das_dict_get(Dict, execution_id, ExecId, ''),
        das_dict_get(Dict, received_count, Recv, 0),
        das_dict_get(Dict, total_items, Total, 0),
        das_dict_get(Dict, duration_ms, Dur, 0),
        Base = [status, Status, execution_id, ExecId,
                received_count, Recv, total_items, Total, duration_ms, Dur],
        (   get_dict(error_message, Dict, Err)
        ->  append(Base, [error_message, Err], Out)
        ;   Out = Base
        ).

das_cancel_to_atom(Dict, Out) :-
        das_dict_get(Dict, execution_id, ExecId, ''),
        das_dict_get(Dict, status, Status, ''),
        Base = [execution_id, ExecId, status, Status],
        (   get_dict(error, Dict, Err)
        ->  append(Base, [error, Err], Out)
        ;   Out = Base
        ).

das_dict_get(Dict, Key, Value, Default) :-
        (   get_dict(Key, Dict, V)
        ->  (   string(V) -> atom_string(Value, V) ; Value = V )
        ;   Value = Default
        ).

%%%%%%%%%% Registration helpers (called from metta.pl) %%%%%%%%%%

das_register_ops :-
        maplist(register_fun,
                ['das-get', 'das-set', 'das-query', 'das-evolution',
                 'das-query-start', 'das-evolution-start',
                 'das-collect', 'das-status', 'das-cancel']),
        (   arity('das-get', 2) -> true ; assertz(arity('das-get', 2)) ),
        maplist([N]>>(arity(N, 2) -> true ; assertz(arity(N, 2))),
                ['das-set', 'das-query', 'das-evolution',
                 'das-query-start', 'das-evolution-start',
                 'das-collect', 'das-status', 'das-cancel']),
        maplist(das_assert_type,
                [ ['das-get', [->, 'Atom', 'Atom']],
                  ['das-set', [->, 'Atom', 'Atom']],
                  ['das-query', [->, 'Atom', 'Atom']],
                  ['das-evolution', [->, 'Atom', 'Atom']],
                  ['das-query-start', [->, 'Atom', 'Atom']],
                  ['das-evolution-start', [->, 'Atom', 'Atom']],
                  ['das-collect', [->, 'Atom', 'Atom']],
                  ['das-status', [->, 'Atom', 'Atom']],
                  ['das-cancel', [->, 'Atom', 'Atom']]
                ]).

das_assert_type([Name, TypeChain]) :-
        (   catch(match('&self', [:, Name, TypeChain], TypeChain, TypeChain), _, fail)
        ->  true
        ;   'add-atom'('&self', [:, Name, TypeChain], true)
        ).
