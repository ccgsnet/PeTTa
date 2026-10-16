## DAS integration

PeTTa can call a running [DAS](https://github.com/singnet/das) BusCommandRouter HTTP API
(`command_router.http_api`, default `localhost:40009`) via grounded MeTTa symbols.
Point the client with environment variables (defaults shown):

| Variable | Default | Meaning |
| --- | --- | --- |
| `PETTA_DAS_URL` | `http://localhost:40009` | Base URL of the Command Router HTTP API |
| `PETTA_DAS_CONNECT_TIMEOUT_MS` | `5000` | Connect timeout (`0` = unset) |
| `PETTA_DAS_REQUEST_TIMEOUT_MS` | `0` | Request timeout (`0` = wait indefinitely) |
| `PETTA_DAS_COLLECT_TIMEOUT_MS` | `0` | WebSocket collect timeout (`0` = wait indefinitely) |

PeTTa speaks the **current** HTTP envelope `{ "command", "params" }` and WebSocket
events `{ "command": "query_answers"|"execution_status", "params": ... }`.
HTTP allows `command: "query"`, `command: "evolution"`, `command: "add_atom"`, and `command: "delete_atom"`.

`das-set` / `das-get` keep a **local** parameter map that is merged into each
query POST (router-side HTTP get/set are not available on the current API).
Defaults: `use_metta_as_query_tokens` and `populate_metta_mapping` are `true`.

| Symbol | Role |
| --- | --- |
| `(das-get params)` | Dump local router params |
| `(das-set (<key> <value>))` | Set a local param (e.g. `context`) |
| `(bind! &das (new-das! <endpoint>))` | Bind a space to a Command Router |
| `(match &das <pattern> <template>)` | Query that endpoint; multivalued template instances |
| `(das-evolution <form>)` | Evolution; blocks until the WS stream completes; multivalued answers |
| `(das-query-start <pattern>)` / `(das-evolution-start <form>)` | Admit async work; returns `execution_id` |
| `(das-collect <id>)` | Collect WS answers for a started execution |
| `(das-status <id>)` / `(das-cancel <id>)` | Poll or cancel |

Example (DAS must be listening):

```metta
!(das-set (use_metta_as_query_tokens True))
!(das-set (populate_metta_mapping True))
!(das-set (context my-ctx))

!(das-get params)

!(bind! &das (new-das! (localhost:40009)))
!(match &das (Similarity $V1 $V2) (Similarity $V1 $V2))
!(match &das (Evaluation $P (Concept "edb dce eeb bac eed")) (Evaluation $P (Concept "edb dce eeb bac eed")))

; Evolution (string expressions keep $names for correlation slots).
; Scalar knobs are local das-set params: population_size, max_generations,
; elitism_rate, selection_rate.
!(das-set (population_size 50))
!(das-set (max_generations 5))
!(das-evolution (
    (query "(Contains $sentence1 (Word \"bbb\"))")
    (ff count_letter)
    (cq ("(Contains $placeholder1 $word1)"))
    (cr (((placeholder1 sentence1))))
    (cm (((sentence1 word1))))))
```

`(ff remote_fitness_function)` asks DAS to score on the client. PeTTa answers each `eval_fitness` WebSocket event by calling `das_remote_fitness(+AnswerJson, -Float)`. A server-side tag such as `count_letter` is scored by DAS and does not use that hook.

```sh
PETTA_DAS_URL=http://localhost:40009 sh run.sh ./examples/das_query.metta
```

### Binding a space to DAS

`bind!` attaches a space name to a Command Router endpoint. `match` on that
space queries the endpoint and instantiates the template. `das-evolution` and
`das-query-start` still use `PETTA_DAS_URL`. A host:port with no scheme
becomes `http://host:port`.

```metta
!(bind! &das (new-das! (localhost:40009)))
!(match &das (Similarity "human" $1) (MyResult "human" $1))
```

`add-atom` and `remove-atom` on a DAS space send `add_atom` and `delete_atom`.
The expression is posted as `params.<command>.metta`. `add-atom` returns `true`
when DAS replies with a handle. `remove-atom` returns `true` for `deleted` and
`false` for `not_found`. `get-atoms` and a variable pattern
such as `(match &das $x $x)` throw `das_space_no_dump` because DAS has no
full-space dump. `populate_metta_mapping` must stay true; handle-only answers
do not unify with the pattern and are skipped. Comma-conjunction patterns are
not sent to DAS.

### Fetching Atoms from DAS and storing them into a local Space

```
; Check that the bound space answers
!(bind! &das (new-das! (localhost:40009)))
!(match &das (Similarity "human" $1) (Similarity "human" $1))

; Check that there is no result yet
!(match &self (Similarity "human" $1) (MyResult "human" $1))

; Create a help function to fetch Atoms from DAS and add them to a given Space
(= (add-atoms-from-das $space $pattern) (map-atom (collapse (match &das $pattern $pattern)) $atom (add-atom $space $atom)))

; Call the helper function
!(add-atoms-from-das &self (Similarity "human" $1))

; Now match must return the added Atoms
!(match &self (Similarity "human" $1) (MyResult "human" $1))
```