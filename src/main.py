from src.module.helper import logging_timer
from src.module.target_pool import build_target_pool
from src.module.feature_set import build_feature_set
from src.module.inactive_tag import build_inactive_tag
from src.module.user_score import build_user_score
from src.module.run_report import RunReport

SKIP_TARGET_POOL = False
SKIP_FEATURE_SET = False
SKIP_INACTIVE_TAG = False


@logging_timer(entry=True, exit=True)
def main():
    """main method to run"""
    report = RunReport()
    try:

        if not SKIP_TARGET_POOL:
            with report.track('build_target_pool'):
                build_target_pool(report=report)

        if not SKIP_FEATURE_SET:
            with report.track('build_feature_set'):
                build_feature_set(report=report)

        if not SKIP_INACTIVE_TAG:
            with report.track('build_inactive_tag'):
                build_inactive_tag(report=report)
        with report.track('build_user_score'):
            build_user_score()
    finally:
        report.write_html()
