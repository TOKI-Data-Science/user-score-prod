"""Builds t_user_score_feature_set_temp; requires t_temp_union_pool to already exist."""
from pathlib import Path

from src.module.database import oracle_execute_script, oracle_table_exists
from src.module.helper import logging_timer
from src.module.target_pool import TARGET_POOL_TABLE

FEATURE_SET_SQL = Path(__file__).parent / 'queries' / 'feature_set.sql'
FEATURE_SET_TABLE = 't_user_score_feature_set_temp'


@logging_timer(entry=True, exit=True)
def build_feature_set(report=None):
    """Runs feature_set.sql after verifying t_temp_union_pool exists"""
    if not oracle_table_exists(TARGET_POOL_TABLE):
        raise RuntimeError(
            f'{TARGET_POOL_TABLE} does not exist; run build_target_pool() first'
        )
    oracle_execute_script(FEATURE_SET_SQL, report=report, step='build_feature_set')
