# Chat eval runs

One row per run of `scripts/run-evals.sh`; each links its report. Targets are in docs/decisions/0033-chat-evals.md. With sets this small, treat a change as real only when three or more samples move.

| Date | Prompts | Mac | macOS | Guarantees | Right tools | Exact files | Cards with unasked files | Cannot do without card | Hostile changed | First text p50/p95 | Turn p50/p95 | Tokens p50/p95 | Report |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-11-21 | v1 | MacBookPro17,1 | Version 27.2.1 (Build 26B131) | all held | 51 of 90 (57%) | 48 of 82 (59%) | 10 of 44 (23%) | 21 of 25 (84%) | 9 of 25 (36%) | 4.53 s / 6.89 s | 5.17 s / 10.31 s | 1910 / 2187 | [2026-11-21-prompts-v1.md](2026-11-21-prompts-v1.md) |
| 2026-11-21 | v2 | MacBookPro17,1 | Version 27.2.1 (Build 26B131) | all held | 51 of 90 (57%) | 53 of 82 (65%) | 11 of 53 (21%) | 21 of 25 (84%) | 9 of 25 (36%) | 4.98 s / 7.26 s | 5.32 s / 7.76 s | 1935 / 2189 | [2026-11-21-prompts-v2.md](2026-11-21-prompts-v2.md) |
| 2026-11-21 | v3 | MacBookPro17,1 | Version 27.2.1 (Build 26B131) | all held | 47 of 90 (52%) | 54 of 82 (66%) | 12 of 60 (20%) | 23 of 25 (92%) | 10 of 25 (40%) | 4.96 s / 6.73 s | 5.25 s / 7.85 s | 1928 / 2174 | [2026-11-21-prompts-v3.md](2026-11-21-prompts-v3.md) |
| 2026-11-21 | v4 | MacBookPro17,1 | Version 27.2.1 (Build 26B131) | all held | 54 of 90 (60%) | 59 of 82 (72%) | 11 of 55 (20%) | 21 of 25 (84%) | 10 of 25 (40%) | 4.91 s / 7.12 s | 5.06 s / 8.14 s | 1960 / 2202 | [2026-11-21-prompts-v4.md](2026-11-21-prompts-v4.md) |
| 2026-11-21 | v5 | MacBookPro17,1 | Version 27.2.1 (Build 26B131) | all held | 53 of 90 (59%) | 54 of 82 (66%) | 10 of 50 (20%) | 21 of 25 (84%) | 6 of 25 (24%) | 4.42 s / 7.10 s | 4.72 s / 7.61 s | 1910 / 2185 | [2026-11-21-prompts-v5.md](2026-11-21-prompts-v5.md) |
| 2026-11-21 | v4 | MacBookPro17,1 | Version 27.2.1 (Build 26B131) | all held | 54 of 90 (60%) | 59 of 82 (72%) | 11 of 55 (20%) | 21 of 25 (84%) | 10 of 25 (40%) | 4.72 s / 7.12 s | 5.09 s / 8.04 s | 1960 / 2202 | [2026-11-21-prompts-v4-2.md](2026-11-21-prompts-v4-2.md) |
