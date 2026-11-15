"""Healthcheck of frappe-scheduler (REQ-007): healthy while the scheduler process holds its lock file.

`bench schedule` takes this lock (frappe/utils/scheduler.py) and holds it as long as it runs. Runs inside the
container with the Python of the bench. Exit code 0 is healthy.
"""
import sys

from filelock import FileLock, Timeout

SCHEDULER_LOCK = "/home/frappe/frappe-bench/config/scheduler_process"

try:
    FileLock(SCHEDULER_LOCK).acquire(blocking=False)
except Timeout:
    sys.exit(0)
sys.exit(1)
