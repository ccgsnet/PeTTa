; Live DAS sample — requires Command Router HTTP API on PETTA_DAS_URL
; (default http://localhost:40009). Skipped by test.sh.

!(das-set (use_metta_as_query_tokens True))
!(das-set (populate_metta_mapping True))
!(das-set (context my-ctx))

!(das-get params)

!(das-query (Similarity $V1 $V2))

!(das-query (Evaluation $P (Concept "edb dce eeb bac eed")))
