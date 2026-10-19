"""
You can create a file called `.env` in the root of the repo, containing your local env vars.
"""
from dotenv import load_dotenv
from pydantic_settings import BaseSettings

# Load environment variables
load_dotenv(verbose=True)


class Settings(BaseSettings):
    """.env variables have priority over following default values"""

    oracle_username: str
    oracle_password: str
    oracle_service: str
    oracle_hostname: str
    oracle_port: str = '1521'
    log_level: str = 'INFO'
    feature_workers: int = 3  # >1 runs independent feature_set.sql statements in parallel; 1 = one at a time
    deadline_hours: float = 5.5  # stop starting new work after this many hours (DB runtime limit is 6h); 0 = off
    run_month: str | None = None  # yyyymm; month of the run to start/resume, default = current month
    force_rerun: bool = False  # ignore any unfinished run for the month and start a new one
    resume_only: bool = False  # only continue an unfinished run; do nothing if there is none

    class Config:
        """.env file location"""

        env_file = ".env"


settings = Settings()
