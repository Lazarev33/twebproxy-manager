#!/usr/bin/env bash
source /usr/local/sbin/twebproxy
MANAGER_API_URL="$TEST_BASE/api"; MANAGER_RAW_URL="$TEST_BASE/raw"
manager_update_cmd "$@"
