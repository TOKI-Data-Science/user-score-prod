"""Builds t_user_score_result; requires t_user_score_inactive_tag to already exist."""
from datetime import datetime

from src.module.database import (
    oracle_export,
    oracle_import,
    oracle_table_exists,
    oracle_upsert_by_column,
)
from src.module.helper import logging_timer
from src.module.inactive_tag import INACTIVE_TAG_TABLE
from src.module.reason_code import score_and_reason

USER_SCORE_TABLE = 't_user_score_result'


@logging_timer(entry=True, exit=True)
def build_user_score():
    """Scores t_user_score_inactive_tag, snapshots the result by run month, and upserts it into t_user_score_result"""
    if not oracle_table_exists(INACTIVE_TAG_TABLE):
        raise RuntimeError(
            f'{INACTIVE_TAG_TABLE} does not exist; run build_inactive_tag() first'
        )
    df_raw = oracle_import(f'select * from {INACTIVE_TAG_TABLE}')
    df_raw.columns = df_raw.columns.str.lower()
    result = score_and_reason(df_raw)
    oracle_export(result, f'{USER_SCORE_TABLE}_{datetime.now():%Y%m}')
    oracle_upsert_by_column(result, USER_SCORE_TABLE, 'base_month')
    return result
