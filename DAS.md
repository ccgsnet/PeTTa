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
HTTP currently allows `command: "query"` only.

`das-set` / `das-get` keep a **local** parameter map that is merged into each
query POST (router-side HTTP get/set are not available on the current API).
Defaults: `use_metta_as_query_tokens` and `populate_metta_mapping` are `true`.

| Symbol | Role |
| --- | --- |
| `(das-get params)` | Dump local router params |
| `(das-set (<key> <value>))` | Set a local param (e.g. `context`) |
| `(das-query <pattern>)` | Pattern query; blocks until WS stream completes; multivalued answers |
| `(das-evolution <form>)` | Evolution; same blocking collect (HTTP 400 until DAS allows `evolution`) |
| `(das-query-start <pattern>)` / `(das-evolution-start <form>)` | Admit async work; returns `execution_id` |
| `(das-collect <id>)` | Collect WS answers for a started execution |
| `(das-status <id>)` / `(das-cancel <id>)` | Poll or cancel |

Example (DAS must be listening):

```metta
!(das-set (use_metta_as_query_tokens True))
!(das-set (populate_metta_mapping True))
!(das-set (context my-ctx))

!(das-get params)

!(das-query (Similarity $V1 $V2))

!(das-query (Evaluation $P (Concept "edb dce eeb bac eed")))
```

```sh
PETTA_DAS_URL=http://localhost:40009 sh run.sh ./examples/das_query.metta
```

### Fetching Atoms from DAS and storing them into a local Space

```
; Check that das-query works
!(das-query (Similarity "human" $1))

; Check that there is no result yet
!(match &self (Similarity "human" $1) (MyResult "human" $1))

; Create a help function to fetch Atoms from DAS and add them to a given Space
(= (add-atoms-from-das $space $pattern) (map-atom (collapse (das-query $pattern)) $atom (add-atom $space $atom)))

; Call the helper function
!(add-atoms-from-das &self (Similarity "human" $1))

; Now match must return the added Atoms
!(match &self (Similarity "human" $1) (MyResult "human" $1))
```