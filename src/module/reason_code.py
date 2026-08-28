"""
Scorecard scoring + customer-facing reason code generation.
"""

from pathlib import Path

import numpy as np
import pandas as pd
import joblib
import importlib
import re
import warnings
import scorecardpy as sc
import scorecardpy.woebin as _woebin_mod


def _apply_scorecardpy_patches():
    condition_fun = importlib.import_module("scorecardpy.condition_fun")
    woebin_mod = importlib.import_module("scorecardpy.woebin")

    def rep_blank_na_compat(dat):
        dat = dat.copy(deep=True)
        if dat.index.duplicated().any():
            dat = dat.reset_index(drop=True)
        blank_cols = [
            c for c in dat.columns
            if dat[c].dtype == object and dat[c].astype(str).str.match(r'^\s*$').any()
        ]
        if blank_cols:
            dat[blank_cols] = dat[blank_cols].replace(r'^\s*$', np.nan, regex=True)
        return dat

    condition_fun.rep_blank_na = rep_blank_na_compat
    for mod_name in ['scorecardpy.split_df', 'scorecardpy.var_filter',
                     'scorecardpy.woebin', 'scorecardpy.scorecard']:
        mod = importlib.import_module(mod_name)
        if hasattr(mod, 'rep_blank_na'):
            mod.rep_blank_na = rep_blank_na_compat

    def check_datetime_cols_compat(dat):
        def _to_dt(s):
            if s.dtype == object:
                try:
                    return pd.to_datetime(s, errors='coerce')
                except Exception:
                    return s
            return s
        dt_cols = [
            c for c in dat.columns
            if dat[c].dtype == object and pd.api.types.is_datetime64_any_dtype(_to_dt(dat[c]))
        ]
        if dt_cols:
            dat = dat.drop(columns=dt_cols)
        return dat

    condition_fun.check_datetime_cols = check_datetime_cols_compat
    _woebin_mod.check_datetime_cols = check_datetime_cols_compat

    def check_empty_bins_compat(dtm, binning):
        bin_list = np.unique(dtm.bin.astype(str)).tolist()
        if 'nan' in bin_list:
            bin_list.remove('nan')
        binleft = set(re.match(r'\[(.+),(.+)\)', v).group(1) for v in bin_list).difference({'-inf', 'inf'})
        binright = set(re.match(r'\[(.+),(.+)\)', v).group(2) for v in bin_list).difference({'-inf', 'inf'})
        if binleft != binright:
            bstbrks = sorted(map(float, ['-inf', *binright, 'inf']))
            labels = [f'[{bstbrks[i]},{bstbrks[i+1]})' for i in range(len(bstbrks) - 1)]
            dtm = dtm.copy()
            dtm['bin'] = pd.cut(dtm['value'], bstbrks, right=False, labels=labels).astype('object')
            binning = (
                dtm.groupby(['variable', 'bin'], group_keys=False)['y']
                .agg([woebin_mod.n0, woebin_mod.n1])
                .reset_index()
                .rename(columns={'n0': 'good', 'n1': 'bad'})
            )
        return binning

    woebin_mod.check_empty_bins = check_empty_bins_compat


_apply_scorecardpy_patches()

PROJECT_ROOT = Path(__file__).resolve().parents[2]
MODELS_DIR = PROJECT_ROOT / 'models'
REASON_LIB_PATH = PROJECT_ROOT / 'data' / 'reason_code_library_2.xlsx'
MODEL_GROUPS = ['mob0', 'mob1-6', 'mob7-12', 'mob12+', 'od', 'inactive']
MODEL_FILES = {
    'mob1-6': 'mob1-6-baseline-new-4.pkl',
    'mob7-12': 'mob7-12-baseline-new-4.pkl',
    'mob12+': 'mob12+-baseline-new-4.pkl',
}
REF_MONTH = 202201
SCORE_ADJUSTMENT = {'mob0': 40, 'od': -10, 'inactive': -50}
SCORE_BINS = [-np.inf, 245, 310, 370, 425, 470, 510, 545, 585, 630, np.inf]
SCORE_BIN_LABELS = ['10', '9', '8', '7', '6', '5', '4', '3', '2', '1']

GENERIC_FALLBACK = "Overall credit and usage pattern"
GENERIC_SIGNAL = "negative"
TOP_POSITIVE = 2
TOP_NEGATIVE = 2
SEVERITY_THRESHOLD = 10
N_REASONS = TOP_POSITIVE + TOP_NEGATIVE

AUTO_REASONS = {
    'mob0': ("Идэвхтэй зээлгүй", "negative"),
    'od': ("Зээлийн түүх муу", "negative"),
    'inactive': ("Идэвхтэй зээлгүй", "negative"),
    'mob12+': ("Үнэнч харилцагч ", "positive"),
}
MAX_REASONS = N_REASONS + 1


def _add_dynamic_tenure_pct(df, ref_month=REF_MONTH):
    """Normalize tenure columns to a 0-1 pct of the max possible tenure as of base_month"""
    out = df.copy()
    bm = out['base_month'].astype(int)
    bm_year, bm_month = bm // 100, bm % 100
    ref_year, ref_m = ref_month // 100, ref_month % 100
    month_diff = (bm_year - ref_year) * 12 + (bm_month - ref_m)
    max_tenure = (month_diff * 30).clip(lower=1)
    out['dynamic_toki_tenure'] = (out['dynamic_toki_tenure'].fillna(0) / max_tenure).clip(0, 1)
    out['dynamic_sign_tenure'] = (out['dynamic_sign_tenure'].fillna(0) / max_tenure).clip(0, 1)
    return out


def _load_lookup():
    lib = pd.read_excel(REASON_LIB_PATH)
    lib['points'] = lib['points'].astype(float)
    lookup = {}
    for _, row in lib.iterrows():
        key = (row['model_group'], row['variable'], round(row['points'], 4))
        if str(row['customer_facing']).strip().lower() in ('true', '1', 'yes'):
            lookup[key] = (row['reason_code_mn'], row['signal'])
        else:
            lookup[key] = None
    return lookup


_LOOKUP = _load_lookup()

_POINTS_BY_VAR = {}
for (grp, var, pts) in _LOOKUP:
    _POINTS_BY_VAR.setdefault((grp, var), []).append(pts)

_MAX_POINTS_BY_VAR = {
    key: max(pts_list) for key, pts_list in _POINTS_BY_VAR.items()
}

DIMENSIONS = [
    'Identity characteristic',
    'Credit history',
    'Fullfillment capacity',
    'Behavioral preference',
]
DIMENSION_COL_MAP = {
    'Identity characteristic': 'identity_characteristic_rank',
    'Credit history': 'credit_history_rank',
    'Fullfillment capacity': 'fullfillment_capacity_rank',
    'Behavioral preference': 'behavioral_preference_rank',
}


def _load_dimension_lib():
    lib = pd.read_excel(REASON_LIB_PATH)
    lib['points'] = lib['points'].astype(float)
    var_dim = {
        (row['model_group'], row['variable']): row['dimension']
        for _, row in lib.iterrows()
    }
    var_bounds = lib.groupby(['model_group', 'variable'])['points'].agg(['min', 'max'])
    var_bounds['dimension'] = var_bounds.index.map(var_dim)
    dim_bounds = var_bounds.groupby('dimension')[['min', 'max']].sum()
    min_dim_points = dim_bounds['min'].to_dict()
    max_dim_points = dim_bounds['max'].to_dict()
    model_group_dims = set(zip(lib['model_group'], lib['dimension']))
    return var_dim, min_dim_points, max_dim_points, model_group_dims


_VAR_DIM, _MIN_DIM_POINTS, _MAX_DIM_POINTS, _MODEL_GROUP_DIMS = _load_dimension_lib()


def _dimension_scores(model_group, feat_names, pts):
    """Sum points by dimension for each row, min-max normalize against the
    dimension's overall attainable point range (summed across all model
    groups, not just this one), scale to 0-5, and clip to a minimum of 1.
    Dimensions the model group has no variables for are left as NaN."""
    sums = {dim: np.zeros(len(pts)) for dim in DIMENSIONS}
    for idx in range(len(feat_names)):
        dim = _VAR_DIM.get((model_group, feat_names[idx]))
        if dim is None:
            continue
        sums[dim] += pts[:, idx]

    out = {}
    for dim in DIMENSIONS:
        col = DIMENSION_COL_MAP[dim]
        min_pts = _MIN_DIM_POINTS.get(dim)
        max_pts = _MAX_DIM_POINTS.get(dim)
        rng = None if min_pts is None or max_pts is None else max_pts - min_pts
        if rng and (model_group, dim) in _MODEL_GROUP_DIMS:
            rank = np.round((sums[dim] - min_pts) / rng * 5, 1)
            out[col] = np.clip(rank, 1, None)
        else:
            out[col] = np.full(len(pts), np.nan)
    return out


def _get_reason(model_group: str, variable: str, points: float):
    """Returns (reason_code, signal) or None if variable is excluded."""
    key = (model_group, variable, round(float(points), 4))
    if key in _LOOKUP:
        return _LOOKUP[key]
    candidates = _POINTS_BY_VAR.get((model_group, variable))
    if not candidates:
        return None
    same_sign = [p for p in candidates if (p >= 0) == (points >= 0)]
    pool = same_sign if same_sign else candidates
    nearest = min(pool, key=lambda p: abs(p - points))
    return _LOOKUP[(model_group, variable, nearest)]


def _severity(model_group: str, variable: str, points: float, signal: str) -> float:
    """Higher severity = stronger driver. Positive signal ranks by raw points
    (closer to the variable's max is more positive); negative signal ranks by
    the gap from that max (further below max is more negative)."""
    if str(signal).strip().lower() == 'positive':
        return points
    max_pts = _MAX_POINTS_BY_VAR.get((model_group, variable))
    return (max_pts - points) if max_pts is not None else abs(points)


ANTONYM_PAIRS = {
    ("сайн", "муу"),
    ("тогтвортой", "тогтворгүй"),
    ("бага", "өндөр"),
}
_ANTONYM_WORDS = {w for pair in ANTONYM_PAIRS for w in pair}


def _is_opposite_pair(code_a: str, code_b: str) -> bool:
    """True only if two reason codes share the same words except the last
    one, and that last word pair is a known antonym pair (e.g. "... сайн"
    vs "... муу"). Differing last words that aren't known antonyms (e.g.
    "бага" vs "тогтвортой") are treated as unrelated, not contradictory."""
    words_a, words_b = code_a.split(), code_b.split()
    if len(words_a) < 2 or len(words_b) < 2:
        return False
    if words_a[:-1] != words_b[:-1] or words_a[-1] == words_b[-1]:
        return False
    last_a, last_b = words_a[-1], words_b[-1]
    if last_a not in _ANTONYM_WORDS or last_b not in _ANTONYM_WORDS:
        return False
    return (last_a, last_b) in ANTONYM_PAIRS or (last_b, last_a) in ANTONYM_PAIRS


def _drop_contradictory_positives(positive, negative):
    """When a positive and a negative reason are opposite phrasings of the
    same statement, drop the positive one and keep only the negative."""
    return [
        p for p in positive
        if not any(_is_opposite_pair(p[1], n[1]) for n in negative)
    ]


def _top_reasons(model_group, feat_names, pts_row):
    positive, negative = [], []
    for idx in range(len(feat_names)):
        variable, points = feat_names[idx], pts_row[idx]
        result = _get_reason(model_group, variable, points)
        if result is None:
            continue
        code, sig = result
        severity = _severity(model_group, variable, points, sig)
        if str(sig).strip().lower() == 'positive':
            positive.append((severity, code, sig))
        else:
            negative.append((severity, code, sig))

    positive.sort(key=lambda c: -c[0])
    negative.sort(key=lambda c: -c[0])
    positive = [c for c in positive if c[0] > SEVERITY_THRESHOLD]
    negative = [c for c in negative if c[0] > SEVERITY_THRESHOLD]
    positive = _drop_contradictory_positives(positive, negative)

    def _fixed_slots(items, n_slots):
        codes, signals, seen = [], [], set()
        for _, code, sig in items:
            if len(codes) == n_slots:
                break
            if code not in seen:
                seen.add(code)
                codes.append(code)
                signals.append(sig)
        while len(codes) < n_slots:
            codes.append(None)
            signals.append(None)
        return codes, signals

    pos_codes, pos_signals = _fixed_slots(positive, TOP_POSITIVE)
    neg_codes, neg_signals = _fixed_slots(negative, TOP_NEGATIVE)
    codes = pos_codes + neg_codes
    signals = pos_signals + neg_signals

    if not any(codes):
        codes[0] = GENERIC_FALLBACK
        signals[0] = GENERIC_SIGNAL

    auto = AUTO_REASONS.get(model_group)
    if auto and auto[0] not in codes:
        codes.append(auto[0])
        signals.append(auto[1])
    return codes, signals


def _prepare(df_raw):
    df = _add_dynamic_tenure_pct(df_raw, ref_month=REF_MONTH)

    excluded_cols = [c for c in df.columns if 'days_since' in c.lower() or 'loan' in c.lower()]
    numeric_cols = df.select_dtypes(include='number').columns
    fill_cols = [c for c in numeric_cols if c not in excluded_cols]
    df[fill_cols] = df[fill_cols].fillna(0)

    conditions = [
        (df['mob_group'] == '0') & (df['model_od'] < 90) & (df['is_inactive_w_12m'] == 1),
        (df['mob_group'] == '1-6') & (df['model_od'] < 90) & (df['is_inactive_w_12m'] == 0),
        (df['mob_group'] == '7-12') & (df['model_od'] < 90) & (df['is_inactive_w_12m'] == 0),
        (df['mob_group'] == '12+') & (df['model_od'] < 90) & (df['is_inactive_w_12m'] == 0),
        (df['model_od'] >= 90) & (df['is_inactive_w_12m'] == 0),
        (df['mob_group'] == '12+') & (df['model_od'] < 90) & (df['is_inactive_w_12m'] == 1),
    ]
    choices = ['mob0', 'mob1-6', 'mob7-12', 'mob12+', 'od', 'inactive']
    df['model_group'] = np.select(conditions, choices, default=None)
    return df


def score_and_reason(df_raw):
    """Accept raw data, derive model_group, score, and attach reason codes."""
    df = _prepare(df_raw)
    score_cols = []
    rc_cols = [f'reason-code-{i+1}' for i in range(MAX_REASONS)]
    sig_cols = [f'reason-code-{i+1}-signal' for i in range(MAX_REASONS)]
    dim_cols = [DIMENSION_COL_MAP[d] for d in DIMENSIONS]
    for c in rc_cols + sig_cols + dim_cols:
        df[c] = None

    for grp in MODEL_GROUPS:
        col = f'{grp}_score'
        score_cols.append(col)
        df[col] = np.nan

        mask = df['model_group'] == grp
        if not mask.any():
            continue

        model_file = MODEL_FILES.get(grp, f'{grp}-baseline-new-3.pkl')
        model = joblib.load(MODELS_DIR / model_file)
        ply = sc.scorecard_ply(
            df[mask], model, only_total_score=False, replace_blank_na=False
        )
        df.loc[mask, col] = ply['score'].values

        pts_cols = [c for c in ply.columns if c.endswith('_points') and c != 'basepoints']
        feat_names = np.array([c[: -len('_points')] for c in pts_cols])
        pts = ply[pts_cols].to_numpy(dtype=float)

        results = [_top_reasons(grp, feat_names, row) for row in pts]
        codes_arr = np.array([
            r[0] + [None] * (MAX_REASONS - len(r[0])) for r in results
        ])
        sigs_arr = np.array([
            r[1] + [None] * (MAX_REASONS - len(r[1])) for r in results
        ])
        for i, (rc, sc_) in enumerate(zip(rc_cols, sig_cols)):
            df.loc[mask, rc] = codes_arr[:, i]
            df.loc[mask, sc_] = sigs_arr[:, i]

        dim_scores = _dimension_scores(grp, feat_names, pts)
        for col in dim_cols:
            df.loc[mask, col] = dim_scores[col]

    raw_score = df['mob0_score']
    for grp in MODEL_GROUPS[1:]:
        raw_score = raw_score.fillna(df[f'{grp}_score'])

    adjustment_conditions = [df['model_group'].eq(grp) for grp in SCORE_ADJUSTMENT]
    adjustment_choices = [raw_score + delta for delta in SCORE_ADJUSTMENT.values()]
    df['user_score'] = pd.Series(
        np.select(adjustment_conditions, adjustment_choices, default=raw_score),
        index=df.index,
    ).clip(lower=200)
    df['user_score_bin'] = pd.cut(
        df['user_score'], bins=SCORE_BINS, right=False, labels=SCORE_BIN_LABELS
    )

    return df[
        ['user_id', 'base_month', 'model_group', 'user_score', 'user_score_bin']
        + rc_cols
        + sig_cols
        + dim_cols
    ]