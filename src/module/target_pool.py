"""Builds t_temp_union_pool, the target pool feature queries join on."""
from pathlib import Path

import pandas as pd

from src.module.database import oracle_execute_script, oracle_export, oracle_import
from src.module.helper import logging_timer

TARGET_POOL_SQL = Path(__file__).parent / 'queries' / 'target_pool.sql'
TARGET_POOL_TABLE = 't_temp_union_pool'


def mob_to_group(mob):
    """Bucket month-on-book into reporting groups"""
    if mob == 0:
        return '0'
    elif mob <= 6:
        return '1-6'
    elif mob <= 12:
        return '7-12'
    else:
        return '12+'


def mob_rank_from_value(mob):
    """Rank used to detect a mob downgrade between consecutive months"""
    if mob <= 0:
        return 0
    elif mob <= 6:
        return 1
    elif mob <= 12:
        return 2
    else:
        return 3


def enforce_non_downgrade(df, mob_col):
    """A user's mob should never decrease month over month; correct data glitches that imply it did"""
    df = df.sort_values(['user_id', 'base_month']).copy()
    month_dt = pd.to_datetime(df['base_month'].astype(str), format='%Y%m', errors='coerce').dt.to_period('M')
    corrected = df[mob_col].astype(float).copy()

    for _, idx in df.groupby('user_id', sort=False).groups.items():
        idx = list(idx)
        for j in range(1, len(idx)):
            i_prev = idx[j - 1]
            i_curr = idx[j]

            prev_mob = corrected.loc[i_prev]
            curr_mob = corrected.loc[i_curr]

            if pd.isna(prev_mob) or pd.isna(curr_mob):
                continue

            prev_month = month_dt.loc[i_prev]
            curr_month = month_dt.loc[i_curr]
            if pd.isna(prev_month) or pd.isna(curr_month):
                continue

            month_gap = curr_month - prev_month
            step = month_gap.n if pd.notna(month_gap) else 0
            if step <= 0:
                continue

            prev_rank = mob_rank_from_value(prev_mob)
            curr_rank = mob_rank_from_value(curr_mob)

            if curr_rank < prev_rank:
                corrected.loc[i_curr] = max(curr_mob, prev_mob + step)

    df[mob_col] = corrected.astype(int)
    return df


@logging_timer(entry=True, exit=True)
def build_target_pool():
    """Runs target_pool.sql, enriches the result in pandas, and writes it back to Oracle"""
    oracle_execute_script(TARGET_POOL_SQL)

    target = oracle_import(
        f'select user_id, base_month, product, mob, model_od from {TARGET_POOL_TABLE}'
    )
    target.columns = target.columns.str.lower()
    target = target.dropna(subset=['user_id'])
    target.drop_duplicates(inplace=True)
    target['model_od'] = target['model_od'].fillna(0)

    target_agg = (
        target.groupby(['user_id', 'base_month'], as_index=False)
        .agg(
            mob=('mob', 'max'),
            model_od=('model_od', 'max'),
        )
    )

    target_agg = enforce_non_downgrade(target_agg, 'mob')
    target_agg['mob_group'] = target_agg['mob'].apply(mob_to_group)

    target_agg = target_agg[target_agg['mob'] >= 0]
    target_agg['model_event'] = (target_agg['model_od'] > 90).astype(int)

    oracle_export(target_agg, TARGET_POOL_TABLE)
    return target_agg
