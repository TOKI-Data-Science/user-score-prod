import sys
import traceback

from loguru import logger

from src.module.helper import DeadlineExceeded, logging_timer
from src.module.target_pool import build_target_pool
from src.module.feature_set import build_feature_set
from src.module.inactive_tag import build_inactive_tag
from src.module.user_score import build_user_score
from src.module.run_log import RunLog
from src.module.run_report import RunReport
from src.module.settings import settings

STEPS = [
    ('build_target_pool', build_target_pool),
    ('build_feature_set', build_feature_set),
    ('build_inactive_tag', build_inactive_tag),
    ('build_user_score', build_user_score),
]


@logging_timer(entry=True, exit=True)
def main():
    """Runs the pipeline steps in order.

    Progress is logged in Oracle (t_user_score_run_log), so a run that stopped (failure, DB runtime limit,
    DEADLINE_HOURS) is continued by the next invocation: finished steps and statements are skipped.
    RUN_MONTH picks the month, FORCE_RERUN starts over, RESUME_ONLY does nothing if there is no unfinished run.
    Exits non-zero when the run is not complete.
    """
    report = RunReport()
    run_log = RunLog.open(force=settings.force_rerun, resume_only=settings.resume_only)
    if run_log is None:
        logger.info('No unfinished run to resume; nothing to do')
        return
    exit_code = 0
    try:
        for name, build in STEPS:
            if run_log.step_done(name):
                logger.info(f"Skipping '{name}' (already done in run {run_log.run_id})")
                continue
            with report.track(name), run_log.track_step(name):
                build(report=report, run_log=run_log)
        run_log.finish('success')
    except DeadlineExceeded as exc:
        logger.warning(f'Run {run_log.run_id} is partial: {exc}. Run again to continue it.')
        run_log.finish('partial', str(exc))
        exit_code = 2
    except Exception:
        run_log.finish('failed', traceback.format_exc())
        raise
    finally:
        report.write_html()
    if exit_code:
        sys.exit(exit_code)
