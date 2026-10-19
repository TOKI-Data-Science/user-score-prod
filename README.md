# User Score Deployment

Monthly batch pipeline that builds a Toki User Score and reason
codes from Oracle source tables.

## Pipeline

Entry point: `python script.py` (calls `src/main.py:main()`).

Runs 4 sequential steps, each depending on the previous step's output table:

1. **`build_target_pool()`** ([src/module/target_pool.py](src/module/target_pool.py)) - runs
   `target_pool.sql`, enriches with pandas (mob correction/grouping), writes
   `t_temp_union_pool` (one row per `user_id`, with `register_based_id` and the
   register's `mob`/`model_od`). `target_pool.sql` also builds `t_temp_user_map`
   (`register_based_id`, `user_id`), which lists every user_id a register has had.
2. **`build_feature_set()`** ([src/module/feature_set.py](src/module/feature_set.py)) - runs
   `feature_set.sql`, writes `t_user_score_feature_set_temp`. It first builds shared
   base tables (`t_us_pool_user`, `t_us_credit_user`, `t_us_credit_monthly`,
   `t_us_base_thoth`) that the feature queries reuse; they are dropped at the end
   of `inactive_tag.sql`, which still reads `t_us_credit_monthly`.
3. **`build_inactive_tag()`** ([src/module/inactive_tag.py](src/module/inactive_tag.py)) - runs
   `inactive_tag.sql`, writes `t_user_score_inactive_tag`, snapshots it as
   `t_user_score_inactive_tag_<yyyymm>`, and upserts (by `base_month`) into the
   permanent history table `t_user_score_raw`.
4. **`build_user_score()`** ([src/module/user_score.py](src/module/user_score.py)) - scores
   `t_user_score_inactive_tag` via the scorecards in `models/` and the reason
   code library in `data/`, snapshots the result as
   `t_user_score_result_<yyyymm>`, and upserts into the permanent history table
   `t_user_score_result`.

### Parallel feature set

`build_feature_set()` runs the independent statements of `feature_set.sql` at the same time, using
Python threads (`ThreadPoolExecutor`), one Oracle connection per thread. `FEATURE_WORKERS` sets how
many statements run at once (default `3`; `1` = one statement at a time). Dependencies between
statements are detected from the SQL text, so `feature_set.sql` stays a single file. If a statement
fails, no new statement starts, running ones finish, then the error is raised. Higher values put more
load on Oracle (TEMP/PGA), so raise it only after checking with the DBA. To see the detected order
without touching the database:

```bash
python -c "from src.module.feature_set import describe_feature_set; describe_feature_set()"
```

### Restartability

The DB runtime limit is 6 h, so a run can be continued instead of redone. Progress is stored in the
Oracle table `t_user_score_run_log` (`run_id, run_month, step, task, status, started_at, ended_at,
error`; `src/module/run_log.py`). It is in Oracle, not a local file, because the container runs with `--rm`.

- **Resume by default.** `python script.py` continues the latest unfinished run (status `running`,
  `partial` or `failed`) of the month; if the month's last run finished, or there is none, it starts a
  new run. Finished steps and finished statements are skipped.
- **Never reused by existence alone.** A statement is skipped only if it is logged `success` in the
  *same* run and its table still exists (a table dropped by a later statement is fine). A new run
  rebuilds everything, so last month's tables are never picked up. This replaces the old `SKIP_*` flags.
- **Deadline guard.** `DEADLINE_HOURS` (default `5.5`, `0` = off) is measured from process start. Once
  passed, no new statement or step starts, running statements finish, the run is marked `partial` and
  the process exits with code `2`. Statements that were already running are not interrupted, so keep
  some margin below the 6 h limit.
- **Atomic statements.** `create table ... as select` leaves no half-built table when killed, so
  restarting at statement level is safe. The pandas part of the target pool replaces
  `t_temp_union_pool`, so it is logged as its own task (`pandas_enrich`) and redone from the SQL if unfinished.
- **History upserts.** `oracle_upsert_by_column` deletes and appends in one transaction, so a crash can
  no longer lose a month of `t_user_score_raw` / `t_user_score_result`.
- **Windows use `SYSDATE`.** A resumed run continues with the original run month for snapshot names,
  but statements run after midnight see a later `SYSDATE`; resume the same day when possible.

Environment variables (all optional):

| Variable | Default | Meaning |
|---|---|---|
| `FEATURE_WORKERS` | `3` | statements of `feature_set.sql` run at once |
| `DEADLINE_HOURS` | `5.5` | stop starting new work after this many hours |
| `RUN_MONTH` | current month | `yyyymm` of the run to start/continue |
| `FORCE_RERUN` | `false` | ignore the unfinished run and start a new one |
| `RESUME_ONLY` | `false` | only continue an unfinished run; do nothing if there is none |

## To Run image

1. Create env file named `oracle-template.env` in `$HOME/envs/` directory
2. Run docker image

```bash
docker run --rm --env-file=$HOME/envs/oracle-template.env oracle-template:v0.1.0
```

## Scheduled/manual runs via GitHub Actions

[.github/workflows/run-pipeline.yml](.github/workflows/run-pipeline.yml) runs
the pipeline on a self-hosted runner (`production` environment):

- **Schedule**: 11:00 Asia/Ulaanbaatar (UTC+8) on the 3rd of every month
- **Resume schedule**: 17:00 Asia/Ulaanbaatar on the 3rd runs with `RESUME_ONLY=true`: it continues a
  `partial`/`failed` run and does nothing if the morning run finished
- **Manual trigger**: `workflow_dispatch` with inputs `resume`, `run_month` and `force_rerun`
- Only one pipeline run at a time (`concurrency` group); job timeout 420 min
- Pulls Oracle credentials and `LOG_LEVEL` from the environment's secrets and
  runs the `user-score-prod:v1.0.0` image

## This repo includes

- Oracle pipeline for scoring users (`src/module/target_pool.py`,
  `feature_set.py`, `inactive_tag.py`, `user_score.py`, `reason_code.py`)
- Per-run HTML timing/status report (`src/module/run_report.py`)
- Restart log and deadline guard (`src/module/run_log.py`)
- Data frame minification function and logging/timer decorator
- Oracle database connection functions (`src/module/database.py`)
- Dockerfile for deploying
- GitHub Actions workflow for scheduled/manual pipeline runs
  (`.github/workflows/run-pipeline.yml`)

