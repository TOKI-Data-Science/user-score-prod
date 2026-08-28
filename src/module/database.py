import math
from contextlib import nullcontext

import pandas as pd
from sqlalchemy import URL, create_engine, types
from sqlalchemy.sql import text

from src.module.helper import logging_timer
from src.module.settings import settings

# oracle connection string for SQL alchemy engine
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
            # strip leading '--' comment lines so 'create table' detection isn't fooled by them
            body_lines = [line for line in statement.splitlines() if not line.strip().startswith('--')]
            body = '\n'.join(body_lines).strip()
            if not body:
                # entire statement is commented out, nothing to execute
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
