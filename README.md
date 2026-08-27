# User Score Deployment

Monthly batch pipeline that builds a Toki User Score and reason
codes from Oracle source tables.

## Pipeline

Entry point: `python script.py` (calls `src/main.py:main()`).

Runs 4 sequential steps, each depending on the previous step's output table:

1. **`build_target_pool()`** ([src/module/target_pool.py](src/module/target_pool.py)) - runs
   `target_pool.sql`, enriches with pandas (mob correction/grouping), writes
   `t_temp_union_pool`.
2. **`build_feature_set()`** ([src/module/feature_set.py](src/module/feature_set.py)) - runs
   `feature_set.sql`, writes `t_user_score_feature_set_temp`.
3. **`build_inactive_tag()`** ([src/module/inactive_tag.py](src/module/inactive_tag.py)) - runs
   `inactive_tag.sql`, writes `t_user_score_inactive_tag`, snapshots it as
   `t_user_score_inactive_tag_<yyyymm>`, and upserts (by `base_month`) into the
   permanent history table `t_user_score_raw`.
4. **`build_user_score()`** ([src/module/user_score.py](src/module/user_score.py)) - scores
   `t_user_score_inactive_tag` via the scorecards in `models/` and the reason
   code library in `data/`, snapshots the result as
   `t_user_score_result_<yyyymm>`, and upserts into the permanent history table
   `t_user_score_result`.

Each run also renders an HTML report to `reports/run_report_<timestamp>.html`
via [src/module/run_report.py](src/module/run_report.py), showing every step
and, for the SQL-driven steps, every individual table/statement with its
start/end time, duration, and status - including the full traceback for any
failure.

## To Run image

1. Create env file named `oracle-template.env` in `$HOME/envs/` directory
2. Run docker image

```bash
docker run --rm --env-file=$HOME/envs/oracle-template.env oracle-template:v0.1.0
```

## Scheduled/manual runs via GitHub Actions

[.github/workflows/run-pipeline.yml](.github/workflows/run-pipeline.yml) runs
the pipeline on a self-hosted runner (`production` environment):

- **Schedule**: 11:00 Asia/Ulaanbaatar (UTC+8) on the 2nd of every month
- **Manual trigger**: `workflow_dispatch`
- Pulls Oracle credentials and `LOG_LEVEL` from the environment's secrets and
  runs the `user-score-prod:v1.0.0` image

## This repo includes

- Oracle pipeline for scoring users (`src/module/target_pool.py`,
  `feature_set.py`, `inactive_tag.py`, `user_score.py`, `reason_code.py`)
- Per-run HTML timing/status report (`src/module/run_report.py`)
- Data frame minification function and logging/timer decorator
- Oracle database connection functions (`src/module/database.py`)
- Dockerfile for deploying
- GitHub Actions workflow for scheduled/manual pipeline runs
  (`.github/workflows/run-pipeline.yml`)

