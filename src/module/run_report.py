"""Tracks per-step and per-table start/end/status/error for a pipeline run and renders an HTML report."""
import traceback
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path

REPORTS_DIR = Path(__file__).resolve().parents[2] / 'reports'

STATUS_COLORS = {'success': '#4caf50', 'failed': '#f44336', 'running': '#ffb300'}


def _fmt(dt):
    return dt.strftime('%Y-%m-%d %H:%M:%S') if dt else '-'


class RunReport:
    """Collects per-step and per-table timing/status for one pipeline run"""

    def __init__(self):
        self.run_started_at = datetime.now()
        self.steps = []
        self.tables = []

    @contextmanager
    def _record(self, records, name, extra=None):
        record = {
            'name': name,
            'started_at': datetime.now(),
            'ended_at': None,
            'duration_sec': None,
            'status': 'running',
            'error': None,
            **(extra or {}),
        }
        records.append(record)
        try:
            yield
            record['status'] = 'success'
        except Exception:
            record['status'] = 'failed'
            record['error'] = traceback.format_exc()
            raise
        finally:
            record['ended_at'] = datetime.now()
            record['duration_sec'] = round((record['ended_at'] - record['started_at']).total_seconds(), 2)

    def track(self, step_name):
        """Records start/end/duration/status/error around a whole pipeline step"""
        return self._record(self.steps, step_name)

    def track_table(self, step_name, table_name):
        """Records start/end/duration/status/error around a single table/statement within a step"""
        return self._record(self.tables, table_name, {'step': step_name})

    def write_html(self, path=None):
        """Renders the collected steps and tables to a standalone dark-themed HTML report"""
        REPORTS_DIR.mkdir(parents=True, exist_ok=True)
        path = path or REPORTS_DIR / f'run_report_{self.run_started_at:%Y%m%d_%H%M%S}.html'

        def status_badge(status):
            color = STATUS_COLORS.get(status, '#ccc')
            return f'<span style="color:{color}; font-weight:bold">{status}</span>'

        sections = []
        for s in self.steps:
            step_tables = [t for t in self.tables if t['step'] == s['name']]
            table_rows = []
            for t in step_tables:
                error_html = f"<pre>{t['error']}</pre>" if t['error'] else ''
                table_rows.append(f"""
                    <tr>
                        <td class="indent">{t['name']}</td>
                        <td>{_fmt(t['started_at'])}</td>
                        <td>{_fmt(t['ended_at'])}</td>
                        <td>{t['duration_sec'] if t['duration_sec'] is not None else '-'}</td>
                        <td>{status_badge(t['status'])}</td>
                    </tr>
                    {f'<tr><td colspan="5">{error_html}</td></tr>' if error_html else ''}
                """)

            step_error_html = f"<pre>{s['error']}</pre>" if s['error'] else ''
            sections.append(f"""
                <tr class="step-row">
                    <td><strong>{s['name']}</strong></td>
                    <td>{_fmt(s['started_at'])}</td>
                    <td>{_fmt(s['ended_at'])}</td>
                    <td>{s['duration_sec'] if s['duration_sec'] is not None else '-'}</td>
                    <td>{status_badge(s['status'])}</td>
                </tr>
                {f'<tr><td colspan="5">{step_error_html}</td></tr>' if step_error_html else ''}
                {''.join(table_rows)}
            """)

        html = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Pipeline run report - {self.run_started_at:%Y-%m-%d %H:%M:%S}</title>
<style>
  body {{ font-family: Consolas, 'Segoe UI', Arial, sans-serif; margin: 24px; background: #1e1e1e; color: #d4d4d4; }}
  h2 {{ color: #ffffff; }}
  table {{ border-collapse: collapse; width: 100%; }}
  th, td {{ border: 1px solid #3c3c3c; padding: 8px; text-align: left; }}
  th {{ background: #2d2d2d; color: #ffffff; }}
  tr.step-row td {{ background: #252526; }}
  td.indent {{ padding-left: 32px; color: #9cdcfe; }}
  pre {{ white-space: pre-wrap; background: #3a1f1f; color: #f48771; padding: 8px; margin: 0; }}
</style>
</head>
<body>
  <h2>Pipeline run report</h2>
  <p>Run started: {_fmt(self.run_started_at)}</p>
  <table>
    <tr><th>Step / Table</th><th>Started</th><th>Ended</th><th>Duration (sec)</th><th>Status</th></tr>
    {''.join(sections)}
  </table>
</body>
</html>"""

        path.write_text(html, encoding='utf-8')
        return path
