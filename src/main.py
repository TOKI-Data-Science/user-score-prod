from src.module.helper import logging_timer
from src.module.target_pool import build_target_pool
from src.module.feature_set import build_feature_set
from src.module.inactive_tag import build_inactive_tag
from src.module.user_score import build_user_score
from src.module.run_report import RunReport

SKIP_TARGET_POOL = True  # TEMPORARY, see main()
SKIP_FEATURE_SET = True  # TEMPORARY, see main()
SKIP_INACTIVE_TAG = True  # TEMPORARY, see main()


@logging_timer(entry=True, exit=True)
def main():
    """main method to run"""
    report = RunReport()
    try:
        # TEMPORARY: t_temp_union_pool and t_temp_user_map already exist, so skip target_pool.sql.
        # Remove this flag once the target pool step is fixed.
        if not SKIP_TARGET_POOL:
            with report.track('build_target_pool'):
                build_target_pool(report=report)
        # TEMPORARY: t_user_score_feature_set_temp already exists, so skip feature_set.sql.
        if not SKIP_FEATURE_SET:
            with report.track('build_feature_set'):
                build_feature_set(report=report)
        # TEMPORARY: t_user_score_inactive_tag already exists, so skip inactive_tag.sql.
        if not SKIP_INACTIVE_TAG:
            with report.track('build_inactive_tag'):
                build_inactive_tag(report=report)
        with report.track('build_user_score'):
            build_user_score()
    finally:
        report.write_html()
