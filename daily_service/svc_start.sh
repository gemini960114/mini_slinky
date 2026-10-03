#!/bin/bash
# 每天 08:00 由 cron 呼叫（冪等：已在跑就不重複提交，模擬 K8s desired-state）
BASE="$(cd "$(dirname "$0")" && pwd)"
if squeue -h -n daily-svc -u "$USER" | grep -q .; then
    echo "$(date '+%F %T') already running, skip"
    exit 0
fi
sbatch "$BASE/svc_job.sh"
