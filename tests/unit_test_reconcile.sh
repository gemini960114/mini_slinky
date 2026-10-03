#!/bin/bash
# svc_reconcile.sh 決策邏輯單元測試（mock 全部叢集指令，零資源）
# 用法：bash mini_slinky/tests/unit_test_reconcile.sh

HERE="$(cd "$(dirname "$0")" && pwd)"
MOCK="$HERE/mock"
RECONCILE="$HERE/../daily_service/svc_reconcile.sh"
LOG=$(mktemp)
PASS=0; FAIL=0

run_case() {
    # $1=時間(HHMM) $2=作業存在(y/n) $3=期望動作(none/sbatch/scancel) $4=說明
    local t=$1 hasjob=$2 expect=$3 desc=$4
    : > "$LOG"
    if [ "$hasjob" = y ]; then echo "123456" > "$LOG.queue"; else : > "$LOG.queue"; fi
    TEST_HM=$t TEST_TS="${t:0:2}:${t:2:2}:00" SQUEUE_MOCK="$LOG.queue" MOCK_LOG="$LOG" \
        PATH="$MOCK:$PATH" bash "$RECONCILE" >/dev/null 2>&1
    local acted=none
    grep -q "SBATCHcalled"  "$LOG" && acted=sbatch
    grep -q "SCANCELcalled" "$LOG" && acted=scancel
    if [ "$acted" = "$expect" ]; then
        echo "  PASS  t=$t job=$hasjob → $acted  ($desc)"; PASS=$((PASS+1))
    else
        echo "  FAIL  t=$t job=$hasjob → 實際=$acted 期望=$expect  ($desc)"; FAIL=$((FAIL+1))
    fi
}

echo "=== 單元測試：reconcile 決策表（7 案例）==="
run_case 0655 n none "開機前 5 分，無作業 → 不動"
run_case 0700 n sbatch "窗口開起點，無作業 → 提交"
run_case 0730 y none  "窗口中，作業存在 → 不動（冪等）"
run_case 1859 y none  "窗口關前 1 分 → 不動"
run_case 1900 y scancel "窗口關起點，作業存在 → 取消"
run_case 2359 n none  "深夜無作業 → 不動"
run_case 0000 y scancel "跨午夜殘留作業 → 取消"

echo ""
echo "=== 單元測試：環境變數注入（窗口單一真相來源）==="
: > "$LOG"; : > "$LOG.queue"
TEST_HM=0700 SQUEUE_MOCK="$LOG.queue" MOCK_LOG="$LOG" PATH="$MOCK:$PATH" \
    bash "$RECONCILE" >/dev/null 2>&1
if grep -q "SBATCHcalled env=\[0700-1900\]" "$LOG"; then
    echo "  PASS  sbatch 收到 SVC_START=0700 SVC_END=1900"; PASS=$((PASS+1))
else
    echo "  FAIL  環境變數未正確注入：$(cat "$LOG")"; FAIL=$((FAIL+1))
fi

echo ""
echo "結果：PASS=$PASS FAIL=$FAIL"
rm -f "$LOG" "$LOG.queue"
[ "$FAIL" -eq 0 ]
