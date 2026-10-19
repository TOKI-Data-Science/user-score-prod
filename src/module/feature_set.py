"""Builds t_user_score_feature_set_temp; requires t_temp_union_pool to already exist."""
from pathlib import Path

from src.module.database import (
    describe_script,
    oracle_execute_script_parallel,
    oracle_table_exists,
)
from src.module.helper import logging_timer
from src.module.settings import settings
from src.module.target_pool import TARGET_POOL_TABLE

FEATURE_SET_SQL = Path(__file__).parent / 'queries' / 'feature_set.sql'
FEATURE_SET_TABLE = 't_user_score_feature_set_temp'


@logging_timer(entry=True, exit=True)
def build_feature_set(report=None, run_log=None):
    """Runs feature_set.sql after verifying t_temp_union_pool exists.
    With a run_log, statements already finished in this run are skipped (restart)."""
    if not oracle_table_exists(TARGET_POOL_TABLE):
        raise RuntimeError(
            f'{TARGET_POOL_TABLE} does not exist; run build_target_pool() first'
        )
    oracle_execute_script_parallel(
        FEATURE_SET_SQL,
        report=report,
        step='build_feature_set',
        max_workers=max(1, settings.feature_workers),
        run_log=run_log,
    )


def describe_feature_set():
    """Prints the statement dependency order of feature_set.sql without touching the database"""
    print(describe_script(FEATURE_SET_SQL))
