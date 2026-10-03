#!/bin/bash
# 每天 18:00 由 cron 呼叫（保證關機，模擬縮容到 0）
ids=$(squeue -h -n daily-svc -u "$USER" -o "%i")
if [ -n "$ids" ]; then
    scancel $ids
    echo "$(date '+%F %T') stopped: $ids"
else
    echo "$(date '+%F %T') nothing to stop"
fi
