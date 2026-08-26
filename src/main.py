from src.module.helper import logging_timer
from src.module.target_pool import build_target_pool


@logging_timer(entry=True, exit=True)
def main():
    """main method to run"""
    build_target_pool()
