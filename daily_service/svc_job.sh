#!/bin/bash
#SBATCH --job-name=daily-svc
#SBATCH --partition=8gpus
#SBATCH --account=govXXXXXX
#SBATCH --nodes=1
#SBATCH --gpus-per-node=1
#SBATCH --cpus-per-task=12
#SBATCH --mem=100G
#SBATCH --time=12:30:00
#SBATCH --requeue
#SBATCH --dependency=singleton
#SBATCH --output=/home/your-user/mini_slinky/daily_service/job_%j.log

# 迷你 Slinky 服務容器（Pod 等價物）
# 設計：服務跑背景、前景每 60 秒監控兩件事：
#   1) 進程存活（掛了 → 3 秒重啟，模擬 K8s liveness restart）
#   2) 服務窗口（過 END → 優雅關閉並以 COMPLETED 收場，不依賴 cron/scancel/-t）
# 窗口參數由 svc_reconcile.sh 以環境變數注入（單一真相來源），此處僅 fallback

export TZ=Asia/Taipei   # 時區加固（2026-10-03 實測計算節點=login=CST，仍明示以防重灌差異）
START="${SVC_START:-0700}"
END="${SVC_END:-1900}"

start_svc() {
    # ===== 換成你的服務（範例：sglang 推論）=====
    # python3 -m sglang.launch_server --model-path <模型> --port 30000 &
    sleep 3600 &          # 佔位：換成上面那行（記得保留結尾的 &）
    SVC_PID=$!
}

while true; do
    start_svc
    # 前景監控迴圈：任一條件成立即離開
    while kill -0 "$SVC_PID" 2>/dev/null; do
        now=$(date +%H%M)
        if [ "$now" -ge "$END" ] || [ "$now" -lt "$START" ]; then
            echo "$(date '+%F %T') [svc] 超出服務窗口（$START-$END），優雅關閉" >&2
            kill "$SVC_PID" 2>/dev/null
            wait "$SVC_PID" 2>/dev/null
            exit 0
        fi
        sleep 60
    done
    wait "$SVC_PID" 2>/dev/null
    echo "$(date '+%F %T') [svc] 進程掛掉（exit=$?），3 秒後重啟" >&2
    sleep 3
done
