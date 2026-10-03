#!/bin/bash
# mini-Slinky reconciler：由 cron 每 5 分鐘呼叫一次
# 宣告式 desired state：
#   07:00–19:00（12 小時）→ 應該有 1 個 daily-svc 在跑
#   其他時間           → 應該有 0 個
# 不在的補齊、多的砍掉、掛了重開 —— 跟 K8s controller 同一套邏輯

BASE="$(cd "$(dirname "$0")" && pwd)"
JOB_NAME="daily-svc"
START=0700   # 每天 07:00 開
END=1900     # 每天 19:00 關（共 12 小時）

now=$(date +%H%M)
running=$(squeue -h -n "$JOB_NAME" -u "$USER" -o "%i")

if [ "$now" -ge "$START" ] && [ "$now" -lt "$END" ]; then
    # desired = 1
    if [ -z "$running" ]; then
        # 窗口參數注入作業（單一真相來源；svc_job.sh 端僅 fallback）
        SVC_START="$START" SVC_END="$END" sbatch "$BASE/svc_job.sh" >/dev/null
        echo "$(date '+%F %T') [reconcile] 開機（desired=1, actual=0）"
    fi
else
    # desired = 0
    if [ -n "$running" ]; then
        scancel $running
        echo "$(date '+%F %T') [reconcile] 關機（desired=0, actual=1）"
    fi
fi
