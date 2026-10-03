#!/bin/bash
# 一鍵查看迷你 Slinky 狀態：desired、actual、窗口、下一步動作
BASE="$(cd "$(dirname "$0")" && pwd)"
JOB_NAME="daily-svc"
START="${SVC_START:-0700}"
END="${SVC_END:-1900}"
# 與 reconcile 同步讀取設定（單一真相來源）
if [ -f "$BASE/svc_reconcile.sh" ]; then
    eval "$(grep -E '^(START|END)=' "$BASE/svc_reconcile.sh" | head -2)"
fi

now=$(date +%H%M)
in_window=否; desired=0
if [ "$now" -ge "$START" ] && [ "$now" -lt "$END" ]; then in_window=是; desired=1; fi

echo "=== 迷你 Slinky 狀態 $(date '+%F %T') ==="
echo "服務窗口   : $START – $END（目前 in-window=$in_window, desired=$desired）"
jobs=$(squeue -h -n "$JOB_NAME" -u "$USER" -o "%i|%T|%M|%N" 2>/dev/null)
if [ -n "$jobs" ]; then
    echo "運行中作業 :"
    echo "$jobs" | while IFS='|' read -r id st el node; do
        echo "  Job $id  [$st]  已跑 $el  on $node"
    done
else
    echo "運行中作業 : （無）"
fi
if [ "$desired" = 1 ] && [ -z "$jobs" ]; then
    echo "下一步     : ⚠️ desired=1 但沒有作業 — reconcile 下次觸發（每 5 分）會自動補開"
elif [ "$desired" = 0 ] && [ -n "$jobs" ]; then
    echo "下一步     : ⚠️ 窗口外仍有作業 — reconcile 下次觸發會自動關機"
else
    echo "下一步     : ✅ 狀態符合 desired，不需動作"
fi
