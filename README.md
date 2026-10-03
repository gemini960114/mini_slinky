# 迷你 Slinky（Mini-Slinky）

每天 **07:00 自動開機、19:00 自動關機**的 HPC 服務調度器 — 55 行 bash，不需要 K8s 權限。

> **⚠️ 首次部署前**：本 repo 為**去機敏化版本**，以下為佔位值，請先替換成你的環境：
> ```
> sed -i 's|/home/your-user|/home/你的帳號|g; s|govXXXXXX|你的計畫號|g' README.md daily_service/*.sh tests/*.sh
> ```
> （佔位：`your-user`=帳號、`govXXXXXX`=計畫號、`gpu-node-*`=節點名）

## 快速導覽

| 檔案 | 用途 |
|---|---|
| [`mini_slinky_plan.md`](mini_slinky_plan.md) | **主文件**：目的、設計、與 Slinky 比較、測試證據（先讀 §0 開場白） |
| `daily_service/svc_reconcile.sh` | 核心：cron 每 5 分鐘對賬（唯一要進 crontab 的檔案） |
| `daily_service/svc_job.sh` | 作業本體（**你的服務寫這裡**） |
| `daily_service/svc_start.sh` / `svc_stop.sh` | 手動開/關（備用） |
| `daily_service/svc_status.sh` | 一鍵看目前狀態 |
| `tests/` | 回歸測試（單元 8/8、E2E 5/5 已通過） |

## 部署（一行 cron）

```
*/5 * * * * /home/your-user/mini_slinky/daily_service/svc_reconcile.sh >> /home/your-user/mini_slinky/daily_service/svc.log 2>&1
```

## FAQ

- **改開關時間？** 改 `svc_reconcile.sh` 開頭的 `START=` / `END=`（作業端自動跟隨，不用改第二處）
- **換服務？** 改 `svc_job.sh` 內 `start_svc()` 的指令；隔日 19:00 關機後自動生效
- **看狀態？** `bash daily_service/svc_status.sh`
- **看服務輸出？** `daily_service/job_<JobID>.log`
- **緊急全關？** `bash daily_service/svc_stop.sh` + 註解掉 cron 那行
- **為什麼不會關不掉？** 四層保險：reconcile scancel → 作業時鐘自我退場 → `-t 12:30` 硬上限 → singleton 防重複（細節見 plan §4.5）

## 限制（誠實聲明）

不自動擴縮容、無 HTTP 健康探測、更新需斷線。適合「單一服務 × 固定時窗」；要更多請上真 Slinky（plan §5.4）。
