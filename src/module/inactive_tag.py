"""Builds t_user_score_inactive_tag; requires t_temp_union_pool and t_user_score_feature_set_temp to already exist."""
from datetime import datetime
from pathlib import Path

from src.module.database import (
    oracle_execute_script,
    oracle_export,
    oracle_import,
    oracle_table_exists,
    oracle_upsert_by_column,
)
from src.module.helper import logging_timer
from src.module.target_pool import TARGET_POOL_TABLE
from src.module.feature_set import FEATURE_SET_TABLE

INACTIVE_TAG_SQL = Path(__file__).parent / 'queries' / 'inactive_tag.sql'
INACTIVE_TAG_TABLE = 't_user_score_inactive_tag'
RAW_HISTORY_TABLE = 't_user_score_raw'

@logging_timer(entry=True, exit=True)
def build_inactive_tag(report=None):
    """Runs inactive_tag.sql, snapshots the result by run month, and upserts it into t_user_score_raw"""
    if not oracle_table_exists(TARGET_POOL_TABLE):
        raise RuntimeError(
            f'{TARGET_POOL_TABLE} does not exist; run build_target_pool() first'
        )
    if not oracle_table_exists(FEATURE_SET_TABLE):
        raise RuntimeError(
            f'{FEATURE_SET_TABLE} does not exist; run build_feature_set() first'
        )
    oracle_execute_script(INACTIVE_TAG_SQL, report=report, step='build_inactive_tag')

    df = oracle_import(f'select * from {INACTIVE_TAG_TABLE}')
    df.columns = df.columns.str.lower()
    df = df.drop(columns=['register_based_id'], errors='ignore')
    oracle_export(df, f'{INACTIVE_TAG_TABLE}_{datetime.now():%Y%m}')
    oracle_upsert_by_column(df, RAW_HISTORY_TABLE, 'base_month')
    return df