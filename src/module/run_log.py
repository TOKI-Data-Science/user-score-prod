"""Restartability: records per-step and per-task status of a pipeline run in an Oracle control table.

The table lives in Oracle (not a local file) because the container runs with --rm.
Rows of one run share a run_id (run_month + start stamp):
  step='_run',  task='_run'   the run itself   (running | success | partial | failed)
  step=<name>,  task='_step'  one pipeline step
  step=<name>,  task=<label>  one statement / sub-task of a step
A task is only reused when its row is 'success' in the SAME run_id (and, for tables, the table still
exists), so last month's tables are never picked up by existence alone.
"""
import time
import traceback
from contextlib import contextmanager
from datetime import datetime

from loguru import logger
from sqlalchemy import bindparam, create_engine, types
from sqlalchemy.sql import text

from src.module.database import oracle_connection_url
from src.module.helper import DeadlineExceeded
from src.module.settings import settings

RUN_LOG_TABLE = 't_user_score_run_log'
RUN_ROW = '_run'
STEP_ROW = '_step'
PROCESS_START = time.monotonic()  # the DB runtime limit applies to each invocation, so measure from here

_CREATE_TABLE = f"""
create table {RUN_LOG_TABLE} (
  run_id     varchar2(40)  not null,
  run_month  varchar2(6)   not null,
  step       varchar2(100) not null,
  task       varchar2(200) not null,
  status     varchar2(20)  not null,
  started_at date,
  ended_at   date,
  error      varchar2(4000),
  primary key (run_id, step, task)
)
"""

_WRITE = text(
    f"""
merge into {RUN_LOG_TABLE} t
using (select :run_id as run_id, :step as step, :task as task from dual) s
on (t.run_id = s.run_id and t.step = s.step and t.task = s.task)
when matched then update set
  t.status = :status, t.started_at = :started_at, t.ended_at = :ended_at, t.error = :error
when not matched then insert (run_id, run_month, step, task, status, started_at, ended_at, error)
  values (:run_id, :run_month, :step, :task, :status, :started_at, :ended_at, :error)
"""
).bindparams(
    bindparam('started_at', type_=types.DateTime()),
    bindparam('ended_at', type_=types.DateTime()),
    bindparam('error', type_=types.String()),
)


class RunLog:
    """Status of one pipeline run, persisted to RUN_LOG_TABLE so a later invocation can continue it"""

    def __init__(self, engine, run_id, run_month, resumed=False):
        self.engine = engine
        self.run_id = run_id
        self.run_month = run_month
        self.resumed = resumed
        hours = settings.deadline_hours
        self.deadline_at = PROCESS_START + hours * 3600 if hours and hours > 0 else None

    @classmethod
    def open(cls, run_month=None, force=False, resume_only=False):
        """Starts a run, or continues the latest unfinished run of the month.
        Returns None when resume_only is set and there is nothing to continue."""
        run_month = str(run_month or settings.run_month or f'{datetime.now():%Y%m}')
        engine = create_engine(oracle_connection_url)
        with engine.begin() as connection:
            exists = connection.execute(
                text('select count(*) from user_tables where table_name = :name'), {'name': RUN_LOG_TABLE.upper()}
            ).scalar()
            if not exists:
                connection.execute(text(_CREATE_TABLE))
            latest = connection.execute(
                text(
                    f'select run_id, status from (select run_id, status from {RUN_LOG_TABLE} '
                    'where run_month = :month and step = :step and task = :task order by started_at desc) '
                    'where rownum = 1'
                ),
                {'month': run_month, 'step': RUN_ROW, 'task': RUN_ROW},
            ).first()
        unfinished = latest is not None and latest.status != 'success'
        if resume_only and not unfinished:
            engine.dispose()
            return None
        if unfinished and not force:
            run_id, resumed = latest.run_id, True
        else:
            run_id, resumed = f'{run_month}_{datetime.now():%d%H%M%S}', False
        run_log = cls(engine, run_id, run_month, resumed)
        run_log._write(RUN_ROW, RUN_ROW, 'running', datetime.now())
        logger.info(f"{'Resuming' if resumed else 'Starting'} run {run_id}")
        return run_log

    def _write(self, step, task, status, started_at, ended_at=None, error=None):
        with self.engine.begin() as connection:
            connection.execute(
                _WRITE,
                {
                    'run_id': self.run_id,
                    'run_month': self.run_month,
                    'step': step,
                    'task': task,
                    'status': status,
                    'started_at': started_at,
                    'ended_at': ended_at,
                    'error': error[:3000] if error else None,
                },
            )

    def finish(self, status, error=None):
        """Marks the whole run success | partial | failed"""
        self._write(RUN_ROW, RUN_ROW, status, datetime.now(), datetime.now(), error)

    def deadline_passed(self):
        return self.deadline_at is not None and time.monotonic() >= self.deadline_at

    def check_deadline(self):
        """Call before starting new work; raises once DEADLINE_HOURS have passed since this process started"""
        if self.deadline_passed():
            raise DeadlineExceeded(f'deadline of {settings.deadline_hours} h reached; stopping before new work')

    @contextmanager
    def _track(self, step, task):
        started = datetime.now()
        self._write(step, task, 'running', started)
        try:
            yield
        except DeadlineExceeded as exc:
            self._write(step, task, 'partial', started, datetime.now(), str(exc))
            raise
        except Exception:
            self._write(step, task, 'failed', started, datetime.now(), traceback.format_exc())
            raise
        else:
            self._write(step, task, 'success', started, datetime.now())

    def track_step(self, step):
        """Context manager: checks the deadline, then logs the step as running -> success | partial | failed"""
        self.check_deadline()
        return self._track(step, STEP_ROW)

    def track_task(self, step, task):
        """Context manager: logs one task of a step as running -> success | failed"""
        return self._track(step, task)

    def done_tasks(self, step):
        """Labels of tasks of this step that finished successfully in this run"""
        with self.engine.connect() as connection:
            rows = connection.execute(
                text(f"select task from {RUN_LOG_TABLE} where run_id = :run_id and step = :step and status = 'success'"),
                {'run_id': self.run_id, 'step': step},
            )
            return {row.task for row in rows}

    def step_done(self, step):
        return STEP_ROW in self.done_tasks(step)

    def task_done(self, step, task):
        return task in self.done_tasks(step)

    def snapshot_suffix(self):
        """yyyymm used for the monthly snapshot tables of this run"""
        return self.run_month
