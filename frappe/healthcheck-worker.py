"""Healthcheck of frappe-worker (REQ-007): healthy while a worker is registered in the Redis of the queue.

Runs inside the container with the Python of the bench. Exit code 0 is healthy. An unreachable Redis raises
an error and so counts as unhealthy.
"""
import json
import sys

import redis
from rq import Worker

BENCH_CONFIG = "/home/frappe/frappe-bench/sites/common_site_config.json"

with open(BENCH_CONFIG) as config_file:
    queue_url = json.load(config_file)["redis_queue"]

registered_workers = Worker.count(connection=redis.from_url(queue_url))
sys.exit(0 if registered_workers > 0 else 1)
