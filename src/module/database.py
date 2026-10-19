import math
import re
import time
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from contextlib import nullcontext

import pandas as pd
from loguru import logger
from sqlalchemy import URL, create_engine, types
from sqlalchemy.sql import text

from src.module.helper import elapsed_time, logging_timer
from src.module.settings import settings

oracle_connection_url = URL.create(
    drivername='oracle+oracledb',
    password=settings.oracle_password,
    username=settings.oracle_username,
    port=settings.oracle_port,
    host=settings.oracle_hostname,
    query={'service_name': settings.oracle_service},
)


def col_length(str_len):
    """Calculate column lengths. Used for allocating column size"""
    # threshold = 2**(pw-1)
    pw = int(math.log(str_len, 2))
    return int(math.ceil((str_len + 2 ** (pw - 1)) / 2 ** (pw - 1)) * 2 ** (pw - 1))


def sql_col(data_frame):
    """Convert python data types to sql data types"""
    dtypes_dict = {}
    for column, dtype in zip(data_frame.columns, data_frame.dtypes):
        if "object" in str(dtype) or "category" in str(dtype):
            lengths = data_frame[column].dropna().astype(str).str.len()
            str_max_len = col_length(lengths.max() if not lengths.empty else 1)
            dtypes_dict.update({column: types.VARCHAR(length=str_max_len)})
        if "datetime" in str(dtype):
            dtypes_dict.update({column: types.DateTime()})
        if "float" in str(dtype):
            dtypes_dict.update({column: types.FLOAT})
        if "int" in str(dtype):
            dtypes_dict.update({column: types.INT()})
    return dtypes_dict


def sql_open(filepath):
    """Load sql file
    Do not include ; in a query
    Only one query in a file is allowed
    """
    query = open(filepath, encoding='utf-8').read()
    return query


@logging_timer()
def oracle_export(data_frame, table_name, index=False, if_exists='replace'):
    """Export to oracle DB"""
    engine = create_engine(oracle_connection_url)
    output_dtypes_dict = sql_col(data_frame)
    data_frame.to_sql(
        table_name.lower(),
        con=engine,
        if_exists=if_exists,
        index=index,
        dtype=output_dtypes_dict,
    )


@logging_timer()
def oracle_upsert_by_column(data_frame, table_name, key_column):
    """Append to a history table, replacing any existing rows for the same key_column values.
    Creates the table on first run since it won't exist yet."""
    if oracle_table_exists(table_name):
        keys = ', '.join(str(int(v)) for v in data_frame[key_column].unique())
        engine = create_engine(oracle_connection_url)
        with engine.connect() as connection:
            connection.execute(text(f'delete from {table_name} where {key_column} in ({keys})'))
            connection.commit()
        oracle_export(data_frame, table_name, if_exists='append')
    else:
        oracle_export(data_frame, table_name, if_exists='replace')


@logging_timer()
def oracle_execute(query):
    """Executes query"""
    engine = create_engine(oracle_connection_url)
    with engine.connect() as connection:
        connection.execute(text(query))
        connection.commit()


@logging_timer()
def oracle_execute_script(filepath, report=None, step=None):
    """Execute a ';'-separated multi-statement sql file, one statement at a time.
    'drop table' statements are best-effort so reruns don't fail on a missing table.
    Before each 'create table' statement, the target table is dropped if it already exists.
    If 'report' (a RunReport) and 'step' are given, each statement is tracked as its own
    table-level row (named after its target table, or 'statement N' if not a create/drop).
    """
    statements = [s.strip() for s in sql_open(filepath).split(';') if s.strip()]
    engine = create_engine(oracle_connection_url)
    with engine.connect() as connection:
        for i, statement in enumerate(statements, start=1):
            body_lines = [line for line in statement.splitlines() if not line.strip().startswith('--')]
            body = '\n'.join(body_lines).strip()
            if not body:
                continue
            lowered = body.lower()
            tokens = body.split()
            lowered_tokens = [t.lower() for t in tokens[:4]]
            is_create = lowered.startswith('create table') or lowered.startswith('create or replace table')
            is_drop = lowered.startswith('drop table')
            if is_create or is_drop:
                table_name = tokens[lowered_tokens.index('table') + 1] if 'table' in lowered_tokens else None
            else:
                table_name = None
            label = table_name or f'statement {i}'
            if is_drop:
                label = f'drop {label}'

            tracker = report.track_table(step, label) if report else nullcontext()
            with tracker:
                if is_create and table_name and oracle_table_exists(table_name):
                    connection.execute(text(f'drop table {table_name}'))
                    connection.commit()
                try:
                    connection.execute(text(statement))
                    connection.commit()
                except Exception:
                    if is_drop:
                        continue
                    raise


_SQL_COMMENT = re.compile(r'--[^\n]*|/\*.*?\*/', re.S)


def parse_script(filepath):
    """Split a ';'-separated sql file into statements and work out which statements depend on which.

    Each task is a dict: index, kind ('create' | 'drop' | 'other'), table, label, statement, deps.
    Dependencies are detected from the statement text, so nothing has to be maintained by hand:
      - a statement waits for the latest earlier statement that creates any script table it mentions
      - a create/drop of table X also waits for every earlier statement that mentions X
        (so a drop runs after the final join that reads the table)
      - any other kind of statement (insert, update, ...) is a barrier: it waits for everything
        before it and everything after it waits for it
    A dependency is always on an earlier statement, so file order is itself a valid run order.
    """
    tasks = []
    for position, statement in enumerate((s.strip() for s in sql_open(filepath).split(';')), start=1):
        body = _SQL_COMMENT.sub(' ', statement).strip()
        if not body:
            continue
        lowered = body.lower()
        tokens = body.split()
        lowered_tokens = [t.lower() for t in tokens[:4]]
        is_create = lowered.startswith('create table') or lowered.startswith('create or replace table')
        is_drop = lowered.startswith('drop table')
        table = None
        if (is_create or is_drop) and 'table' in lowered_tokens:
            table = tokens[lowered_tokens.index('table') + 1].lower()
        kind = 'create' if is_create else 'drop' if is_drop else 'other'
        label = table or f'statement {position}'
        if is_drop:
            label = f'drop {label}'
        tasks.append(
            {
                'index': len(tasks),
                'kind': kind,
                'table': table,
                'label': label,
                'statement': statement,
                'text': lowered,
                'deps': set(),
            }
        )

    script_tables = {t['table'] for t in tasks if t['table']}
    for task in tasks:
        task['mentions'] = {
            name
            for name in script_tables
            if re.search(rf'(?<![\w$#]){re.escape(name)}(?![\w$#])', task['text'])
        }

    latest_creator = {}
    barrier = None
    for task in tasks:
        deps = task['deps']
        if barrier is not None:
            deps.add(barrier)
        for name in task['mentions']:
            if name in latest_creator:
                deps.add(latest_creator[name])
        if task['table']:
            deps.update(u['index'] for u in tasks[: task['index']] if task['table'] in u['mentions'])
        if task['kind'] == 'other':
            deps.update(range(task['index']))
            barrier = task['index']
        if task['kind'] == 'create' and task['table']:
            latest_creator[task['table']] = task['index']
        deps.discard(task['index'])
    return tasks


def _schedule_info(tasks, weights=None):
    """Level of each task and the longest remaining chain ('rank') that starts at it.
    weights maps a task label to an estimated duration; unknown tasks count as 1."""
    weight = {t['index']: (weights or {}).get(t['label'], 1) for t in tasks}
    level = {}
    finish = {}
    for task in tasks:
        i = task['index']
        level[i] = 1 + max((level[d] for d in task['deps']), default=-1)
        finish[i] = weight[i] + max((finish[d] for d in task['deps']), default=0)
    rank = {t['index']: weight[t['index']] for t in tasks}
    for task in reversed(tasks):
        for d in task['deps']:
            rank[d] = max(rank[d], weight[d] + rank[task['index']])
    return level, finish, rank


def describe_script(filepath, weights=None):
    """Human readable run plan for a script (levels and critical path). Does not touch the database."""
    tasks = parse_script(filepath)
    level, finish, _ = _schedule_info(tasks, weights)
    by_index = {t['index']: t for t in tasks}
    lines = [f'{filepath}: {len(tasks)} statements']
    for lvl in range(max(level.values(), default=-1) + 1):
        names = [t['label'] for t in tasks if level[t['index']] == lvl]
        lines.append(f'  level {lvl}: {len(names)} -> ' + ', '.join(names))
    lines.append('  dependencies:')
    for task in tasks:
        deps = ', '.join(by_index[d]['label'] for d in sorted(task['deps'])) or '-'
        lines.append(f"    {task['label']} <- {deps}")
    end = max(finish, key=finish.get) if finish else None
    path = []
    while end is not None:
        path.append(by_index[end]['label'])
        end = max(by_index[end]['deps'], key=finish.get, default=None)
    lines.append('  critical path: ' + ' -> '.join(reversed(path)))
    return '\n'.join(lines)


def _run_task(engine, task, report, step):
    """Runs one statement on its own connection (one connection per thread)"""
    tracker = report.track_table(step, task['label']) if report else nullcontext()
    started = time.time()
    logger.log(settings.log_level, f"Starting '{task['label']}'")
    with tracker, engine.connect() as connection:
        table = task['table']
        if task['kind'] == 'create' and table:
            exists = connection.execute(
                text('select count(*) from user_tables where table_name = :name'), {'name': table.upper()}
            ).scalar()
            if exists:
                connection.execute(text(f'drop table {table}'))
                connection.commit()
        try:
            connection.execute(text(task['statement']))
            connection.commit()
        except Exception:
            if task['kind'] != 'drop':  # drops are best-effort so reruns don't fail on a missing table
                raise
    logger.log(settings.log_level, f"Finished '{task['label']}' in {elapsed_time(time.time() - started)}")


@logging_timer()
def oracle_execute_script_parallel(filepath, report=None, step=None, max_workers=3, weights=None):
    """Like oracle_execute_script, but runs statements that do not depend on each other at the same time.
    Dependencies come from parse_script. With a failure, no new statement is started, statements already
    running are allowed to finish (their tables stay in place), then the first error is raised.
    weights (task label -> estimated seconds) makes the longest chains start first.
    """
    tasks = parse_script(filepath)
    by_index = {t['index']: t for t in tasks}
    _, _, rank = _schedule_info(tasks, weights)
    pending = set(by_index)
    done = set()
    running = {}
    error = None
    engine = create_engine(oracle_connection_url, pool_size=max_workers, max_overflow=0)
    try:
        with ThreadPoolExecutor(max_workers=max_workers) as pool:
            while pending or running:
                if error is None:
                    ready = sorted((i for i in pending if by_index[i]['deps'] <= done), key=lambda i: (-rank[i], i))
                    for i in ready[: max_workers - len(running)]:
                        pending.discard(i)
                        running[pool.submit(_run_task, engine, by_index[i], report, step)] = i
                if not running:
                    break
                finished, _ = wait(running, return_when=FIRST_COMPLETED)
                for future in finished:
                    i = running.pop(future)
                    try:
                        future.result()
                        done.add(i)
                    except Exception as exc:
                        logger.error(f"'{by_index[i]['label']}' failed: {exc}")
                        error = error or exc
    finally:
        engine.dispose()
    if error:
        raise error
    if pending:
        raise RuntimeError(f'could not schedule: {[by_index[i]["label"] for i in sorted(pending)]}')


@logging_timer()
def oracle_table_exists(table_name):
    """Check whether a table exists in the connected Oracle schema"""
    query = f"select count(*) from user_tables where table_name = '{table_name.upper()}'"
    return oracle_import(query).iloc[0, 0] > 0


@logging_timer()
def oracle_import(query):
    """Import from oracle DB"""
    engine = create_engine(oracle_connection_url).raw_connection()
    data_frame = pd.read_sql(query, engine)
    return data_frame


@logging_timer()
def oracle_sysdate(before_today=0):
    """Get current sysdate from Oracle DB"""
    query = f"SELECT TO_CHAR(SYSDATE - {before_today}, 'YYYYMMDD') FROM dual"
    return oracle_import(query).iloc[0, 0]
