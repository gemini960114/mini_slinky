# 迷你 Slinky（Mini-Slinky）規劃報告

- **文件版本**：v1.3（Plan 階段；含網路查證、deep review、全套實測）
- **撰寫日期**：2026-10-03
- **設計者**：your-user（一般使用者帳號）
- **部署環境**：國家級 HPC 叢集（GPU 節點群）/ 8gpus 分區 / govXXXXXX 計畫
- **專案資料夾**：`mini_slinky/`（本報告 + `daily_service/` 腳本）
- **文件目的**：在「無 K8s 權限、僅有 Slurm 介面、每日 12 小時服務窗口」的約束下，規劃一套模仿 NVIDIA Slinky desired-state 精神的輕量級服務調度器，並與原生 Slinky 做完整比較，說明其適用邊界。
- **狀態**：☐ 規劃中 → ☐ 已驗證 → ☐ 上線

---

## 0. 為什麼要做這個（寫給使用者的開場白）

**你的困擾**：想在 HPC 上跑一個每天早上 7 點開、晚上 7 點關的推論服務。但手動 sbatch/scancel 又笨又容易忘；看到別人（user-a）用 K8s Slinky 全自動管理幾百張 GPU，自己卻只是一般 user —— 沒有 K8s 權限、只有 Slurm。

**這個專案給你的**：一套 55 行 bash 的「迷你 Slinky」。**每天 07:00 服務自動開機、19:00 自動關機**，中途掛了自己爬起來，你什麼都不用管。不需要任何 K8s 權限，只需要你本來就有的 Slurm 帳號。

```
   07:00                        19:00
    ├──────────── 服務窗口 ────────────┤
    ▲ cron 自動提交                     ▲ cron 自動關機
      掛了 → 自動重啟                      就算 cron 全掛 → 作業自己關
```

**與 Slinky 速覽比較**（詳細版見 §5）：

| | 💡 迷你 Slinky（你） | 🏭 真 Slinky（user-a） |
|---|---|---|
| 需要的權限 | 一般 Slurm 帳號 | K8s 叢集憑證（我們沒有） |
| 基礎設施 | 55 行 bash + cron | 整套 K8s + controller + CNI |
| 每天 07–19 定時開關 | ✅ | ✅（要寫 CRD/程式） |
| 掛掉自動重啟 | ✅ | ✅ |
| 自動擴縮容 | ❌ | ✅ |
| 排程確定性 | ✅ 零震盪 | ⚠️ 設定量超容量時會 churn（當日實測 132 筆死單） |
| 適合規模 | 1 個服務 | 數十個服務 |

**它跟 Slinky 的關係**：借用它的好觀念（宣告目標狀態、自動維持），丟掉它的重型基礎設施。不是要取代它 —— 單一服務、固定時窗、一般權限，迷你版反而更穩（細見 §5、§6）。

**可信度**：本設計已通過單元測試 8/8 與真實叢集 E2E 5/5（含「精確於 14:48:04 自行結束」的實證，見附錄 D）。

**下一步**：看 §11 Check List，加一行 cron 就能用。

---

## 目錄

0. [為什麼要做這個（開場白）](#0-為什麼要做這個寫給使用者的開場白)
1. [摘要](#1-摘要)
2. [背景與現況](#2-背景與現況)
3. [需求定義](#3-需求定義)
4. [迷你 Slinky 架構設計](#4-迷你-slinky-架構設計)
5. [與 Slinky 的完整比較](#5-與-slinky-的完整比較)
6. [一般使用者「被保護」的價值分析](#6-一般使用者被保護的價值分析)
7. [應用場景適配](#7-應用場景適配)
8. [資源與數量限制盤點](#8-資源與數量限制盤點)
9. [分階段實施計畫](#9-分階段實施計畫)
10. [風險登記冊](#10-風險登記冊)
11. [實施 Check List](#11-實施-check-list)

---

## 1. 摘要（技術摘要）

**一句話**：用 50 行 bash（cron + sbatch + scancel）實作一個「宣告式狀態 + 週期對賬」的服務調度器，在一般使用者權限與 Slurm 規範內，達成 NVIDIA Slinky 的核心價值（desired state 維持），並避開其在此規模下的已知缺陷（churn 震盪）。

**核心結論**：

| 問題 | 答案 |
|---|---|
| 為什麼不用真的 Slinky？ | 它需要 K8s 控制平面權限（kubeconfig/namespace），我們沒有，且短期內不需要 |
| 迷你版比 Slinky 好在哪？ | 確定性排程（無 churn）、零基礎設施、單人可維護、帳務透明 |
| 迷你版輸 Slinky 什麼？ | 自動擴縮容、秒級對賬、健康探測、滾動更新 |
| 適合誰？ | 需求 = 單一服務 × 固定時窗 × 一般 user 權限的人 |
| 何時該升級到真 Slinky？ | 服務數量 > 5、需要依負載擴縮、有 K8s 權限時 |

---

## 2. 背景與現況

### 2.1 叢集現況（2026-10-03 實測）

- `slinky` 分區（gpu-node-122–172，51 節點 × 8 H200）由 K8s Slinky 橋接佔用，AllowAccounts 白名單：`govYYYYY1, govYYYYY2, govYYYYY3`
- 帳號 `user-a`（govYYYYY3）當日配置 **265 GPU / 39 節點 / 3086 CPU**，運行 Kimi K3（Mene-M3）等多模型推論服務
- 一般帳號 `your-user` 可用：`dev`（4 小時上限）、`8gpus`（**2 天上限**）、ngs 系列（14 天）等分區，節點群與 slinky 有重疊（gpu-node-[122-124, 141-172]）
- K8s API 匿名僅能查 `/version`；SSH 直上節點被 `pam_slurm_adopt` 阻擋 → **一般 user 的唯一程式化介面就是 Slurm**

### 2.2 Slinky 實際行為觀察（本日量測，作為設計依據）

| 時間 | 事件 | 資料 |
|---|---|---|
| 12:45 | 帳號本人批次取消 lws-5/6 | ~15 筆作業 |
| 14:10–14:19 | Controller（系統服務）大量取消 | **132 筆**（其中 114 筆 0 秒未起跑） |
| 14:21 | 重新提交 replica 3–6 | Job 491592–491596，冷啟動重載 10–20 分 |
| 全日 2 小時窗口 | 帳號本人累計取消 | 300+ 筆 |
| 2026-10-01（內部調查筆記紀錄） | 同模式更大規模 | **758 筆** pending 塞爆後批次清理 |

**根因**：LWS desired replicas（>8）> 叢集容量上限（33 節點 ÷ 4 節點/replica = 8）→ controller 的 reconcile loop 永遠補不滿 → 提交→排不進→取消→重提交的**永久震盪**，每次震盪浪費 10–20 分鐘的模型載入 GPU 時間。

### 2.3 我們的限制（一切設計的出發點）

1. **無 K8s 權限**：不能部署 LWS/pod，不能讀 controller log
2. **只有 Slurm**：sbatch / srun / scancel / squeue / sacct
3. **分區時限**：8gpus 2 天、dev 4 小時
4. **計畫帳號**：govXXXXXX（govZZZZZZ 被 NANO4 拒用）
5. **cron 環境**：login node（可能重開機、無 root）

---

## 3. 需求定義

| 編號 | 需求 | 驗收條件 |
|---|---|---|
| R1 | 每日定時開機 | 07:00 服務在線 |
| R2 | 每日定時關機 | 19:00 前資源釋放（GPU 不計費） |
| R3 | 服務窗口 12 小時 | 07:00–19:00 |
| R4 | 故障自癒 | 进程崩潰 1 分鐘內重啟；節點故障自動重排 |
| R5 | 不重複開機 | 冪等：對賬 N 次結果相同 |
| R6 | 保險絲 | 所有自動化失效時，作業最遲 19:30 自行結束 |
| R7 | 完全符合 Slurm 規範 | 不繞過 fairshare、時限、帳務 |
| R8 | 單人可維護 | 總程式碼 < 100 行 bash，無外部依賴 |

---

## 4. 迷你 Slinky 架構設計

### 4.1 設計理念

借用 Slinky/K8s 的兩個核心思想，丟掉它的重型基礎設施：

1. **宣告式狀態（Desired State）**：不寫「開機指令」與「關機指令」，只宣告「07:00–19:00 之間應該存在 1 個名為 daily-svc 的作業」
2. **週期對賬（Reconcile Loop）**：每 5 分鐘比對「宣告」與「現實」（squeue），差什麼補什麼 —— 補齊（sbatch）或多砍（scancel）

### 4.2 系統架構

```
login node                          compute node (8gpus 分區)
┌─────────────────────┐             ┌──────────────────────────┐
│ crontab             │             │ Slurm Job "daily-svc"    │
│  */5 * * * *        │   sbatch    │  ┌────────────────────┐  │
│  svc_reconcile.sh ──┼────────────▶│  │ while true 迴圈    │  │
│    │                │             │  │   服務進程          │  │
│    │ squeue 查現實   │◀────────────┼──│   (掛了 3 秒重啟)   │  │
│    │ (desired vs    │   scancel   │  └────────────────────┘  │
│    │  actual)       │────────────▶│  保險絲: -t 12:30:00     │
└─────────────────────┘             │  自癒:   --requeue       │
                                    └──────────────────────────┘
```

### 4.3 核心組件（已實作於 `daily_service/`）

| 檔案 | 行數 | 職責 | Slinky 對應物 |
|---|---|---|---|
| `svc_reconcile.sh` | ~25 | 宣告 desired（時間窗）、對賬、補齊/砍除 | K8s controller + LWS operator |
| `svc_job.sh` | ~40 | 作業本體；**背景服務+前景 60 秒監控**（進程存活/時鐘窗口）；`--requeue`；`--dependency=singleton` 提交層冪等；`-t 12:30` + 時鐘自我退場雙保險絲；TZ 加固 | Pod + restartPolicy |
| `svc_start.sh` / `svc_stop.sh` | ~10 | 手動備用開關（冪等） | kubectl scale |

### 4.4 狀態機

```
            reconcile 每 5 分鐘
                  │
     ┌──── 時間在 07:00–19:00? ────┐
     ▼ 是                          ▼ 否
  desired=1                     desired=0
     │                             │
  squeue 有 daily-svc?         squeue 有 daily-svc?
   ├─ 有 → 不動（滿足）           ├─ 有 → scancel（縮容）
   └─ 沒有 → sbatch（擴容）        └─ 沒有 → 不動
```

### 4.5 五層錯誤防護（由外到內）

| 層 | 機制 | 防什麼 | K8s 對應 |
|---|---|---|---|
| L0 | `--dependency=singleton` | **提交層原子冪等**：兩個 reconcile 同時搶提交也不會開出第二個（Slurm 排程器保證，免疫 race condition） | replica 數量語意 |
| L1 | `while true` + 進程重啟 | 服務進程 crash | livenessProbe + restart |
| L2 | `--requeue` | 節點故障/搶佔 | pod 重調度 |
| L3 | cron 5 分鐘對賬 | 作業整個消失（L1/L2 都失效） | controller reconcile |
| L4 | `-t 12:30:00` 硬上限 + 作業內時鐘自我退場 | **全部自動化死亡**（cron 掛、login node 重開機） | 無對應（K8s 靠外部監控） |

> L4 是迷你版特有的「失敗安全（fail-safe）」設計：寧可服務中斷，也絕不會變成孤兒作業吃兩天 GPU 計費。
>
> **查證註記（v1.2）**：依 Slurm 官方 sbatch 手冊，`--requeue` 只在「管理員手動、節點故障、被搶佔」三種情況觸發；**時限到期（TIMEOUT）不會 requeue**，故 L4 保險絲可靠，作業到 19:30 必永久結束。
>
> **L4 實作細節（v1.2 deep review 修正）**：服務進程跑**背景**、前景每 **60 秒**監控（存活 + 時鐘），確保自我退場不因服務長時間不退出而失效（前景式寫法的陷阱）；計算節點時區已實測 = login = CST（Asia/Taipei），作業內仍 `export TZ=Asia/Taipei` 加固。窗口參數由 reconcile 以環境變數注入（單一真相來源），作業端僅留 fallback。

---

## 5. 與 Slinky 的完整比較

### 5.1 功能對照

| 能力 | Slinky（K8s） | 迷你 Slinky | 備註 |
|---|---|---|---|
| 維持 desired state | ✅ 秒級 | ✅ 5 分鐘級 | 對賬粒度差 300 倍 |
| 故障重啟（進程） | ✅ liveness probe | ✅ while 迴圈 | 迷你版不探測健康，只探測存活 |
| 故障重排（節點） | ✅ | ✅ `--requeue` | 等價 |
| 自動擴縮容 | ✅ HPA/LWS replicas | ❌ 固定 1 | 需求內不需要 |
| 健康探測（HTTP） | ✅ readiness/liveness | ❌（可加 curl /health） | Phase 3 可選 |
| 滾動更新 | ✅ | ❌（重啟即斷線） | 迷你版需停機更新 |
| 多副本負載平衡 | ✅ Service/DNS | ❌ | — |
| 基礎設施需求 | K8s 叢集+CNI+etcd+controller | **cron + bash** | 差 4 個數量級 |
| 使用者權限需求 | K8s kubeconfig/namespace | **一般 Slurm 帳號** | 核心差異 |
| 代碼量 | 數十萬行（含相依） | ~55 行 | 單人可讀完 |
| 排隊/公平性 | 走 Slurm（同） | 走 Slurm | 等價 |

### 5.2 迷你版優勢（在什麼情境下「反而」比 Slinky 好）

1. **確定性排程，零 churn**
   - 迷你版每天就 1 次 submit + 1 次 cancel，狀態轉移可預測
   - Slinky 在 desired > capacity 時會**永久震盪**（本日 132 筆、10-01 758 筆死單）；迷你版 desired=1 遠低於容量，數學上不可能 churn
2. **零基礎設施、零額外失敗面**
   - 沒有 controller crash、etcd 故障、CNI 路由、版本升級這些 K8s 特有風險
   - login node 的 cron 是全系統最穩的服務之一
3. **審計與帳務透明**
   - `sacct` 一條指令看到每天誰提交、跑多久、多少 GPU 時；K8s 側的計費要對賬兩個系統
4. **fail-safe 設計**
   - `-t 12:30` 硬上限保證最壞情況 19:30 必停；Slinky 沒有等價機制（它的「關機」依賴 controller 活著）
5. **除錯時間以分鐘計**
   - 55 行 bash，出事 `cat svc.log` 三分鐘定位；Slinky 出事要跨 K8s+Slurm 兩層查（本報告 §2.2 的根因分析就是示範，需要 AdminComment、sacct、DNS 三方交叉）
6. **被 fairshare 保護而非對抗**
   - 迷你版排隊就排隊（反正 desired 終會滿足）；Slinky 的 controller 會「不斷重試」變相施壓調度器

### 5.3 迷你版劣勢（誠實面對）

1. 對賬粒度 5 分鐘：服務掛掉最長 5 分鐘沒人理（可縮短 cron，但 login node cron 太頻繁不禮貌）
2. 無 HTTP 健康探測：進程活著 ≠ 服務正常（可於 Phase 3 補 curl /health）
3. 無滾動更新：更新服務必斷線
4. 無擴縮容：流量尖峰只能手動改 desired
5. 單點依賴 login node 的 cron：login node 重開機當天就停擺（L4 保險絲防止失控，但不會自癒——需手動或 at job 補）
6. 只支援「時間驅動」的 desired，不支援事件驅動（佇列深度、負載）

### 5.4 適用邊界（一句話）

> **單服務、時間驅動、一般權限 → 迷你版；多服務、負載驅動、有 K8s 權限 → Slinky。**

---

## 6. 一般使用者「被保護」的價值分析

我們不是叢集管理員，某種程度上「被 Slurm 規範保護」反而是優勢：

| 保護機制 | 對一般 user 的意義 | 迷你版如何順勢利用 |
|---|---|---|
| 分區時限（8gpus 2 天） | 再糟也不會無限佔用 | `-t 12:30` 主動更緊 |
| Fairshare 排隊 | 不會被報復性 Kill，系統公平 | desired=1 早晚会滿足 |
| 帳務綁計畫（govXXXXXX） | 費用上限可預估 | 每天 12h × 1 GPU 固定 |
| AllowAccounts 白名單 | 隔離 Slinky 的 churn 波及 | 用 8gpus 不碰 slinky |
| pam_slurm_adopt | 節點不被亂 SSH | 全走 sbatch，合規 |

**深層觀點**：Slinky 的 churn（本日 132 筆死單）本質是「自動化對賬邏輯」與「資源硬限制」的對抗；一般 user 的迷你版把 desired 設在限制內，是**與系統合作**而不是對抗 —— 這是它「在某方面比 Slinky 好」的根本原因：**在受限環境中，簡單確定的系統比強大但震盪的系統更穩定。**

---

## 7. 應用場景適配

### 7.1 迷你版明確勝出的場景

| 場景 | 為什麼 |
|---|---|
| 定時推論服務（07:00–19:00） | 業務時間固定，無需 24h，churn 零容忍 |
| 批次 + 服務混合（白天服務、夜間批次） | 時間窗互相錯開，兩個 job 名各自 desired |
| 開發/驗證期模型服務 | 需要常開常關試 error，55 行碼改起來快 |
| 資源計畫有限（≤ 8 GPU） | desired 設在限額內，永遠排得到 |
| 無 K8s 權限的團隊 | 唯一選項 |

### 7.2 應使用真 Slinky 的場景

- 服務數量 > 5（每個服務一套迷你碼會開始失序）
- 需依流量自動擴縮（LWS replicas + HPA）
- 需要滾動更新不斷線（生產級 SLO）
- 團隊已有 K8s 維運能量

---

## 8. 資源與數量限制盤點

| 項目 | 限制 | 本設計的用量 | 餘裕 |
|---|---|---|---|
| 分區時限 | 8gpus 2 天 | 每日 12.5h（含保險絲） | 73% |
| 每作業 GPU | 依申請 | 1–8（依服務調 `--gpus-per-node`） | — |
| **CPU:GPU 綁定** | **實測：1 GPU 最多 12 CPU**（gres.conf 核心綁定） | `--cpus-per-task=12`（已實測 `sbatch --test-only` 通過） | 已貼上限 |
| 計畫帳號 | govXXXXXX | 每日 12h × N GPU | 依計畫核可 |
| cron 頻率 | 建議 ≥ 5 分鐘 | 5 分鐘 | — |
| 併發 desired | 無硬限（自律） | 1 | — |
| login node | cron 存活 | 依賴 | L4 保險絲兜底 |
| 報告/日誌空間 | home 配額 | ~10 KB/天 + 作業 log | 極小 |

---

## 9. 分階段實施計畫

### Phase 0 — 規劃（本文件）
- [x] 需求訪談（R1–R8）
- [x] 與 Slinky 比較分析
- [ ] 本報告審閱簽核

### Phase 1 — 乾跑驗證（1 週）
- 目標：證明調度行為正確，不跑真服務（`sleep infinity` 佔位）
- 驗證項目：07:00 自動開、19:00 自動關、手動砍掉後 5 分內自癒、cron 停 1 天不會暴走
- 退出條件：連續 5 個工作日無異常

### Phase 2 — 真服務上線
- 將 `svc_job.sh` 的 sleep 換成實際服務（如 sglang/vLLM）
- 驗證：服務進程 kill -9 後 3 秒重啟、節點維修後 `--requeue` 生效

### Phase 3 — 強化（可選）
- [ ] HTTP 健康探測：while 迴圈內加 `curl -f localhost:30000/health`，失敗計數 3 次才重啟
- [ ] 通知：reconcile 異常時寫 log + mail
- [ ] 日誌輪替：`svc.log` 超過 1 MB 自動 rotate
- [ ] 多服務參數化：desired 由設定檔驅動（job 名、時窗、GPU 數）

### Phase 4 — 量產評估
- 若服務成長到 > 3 個：評估整合或轉申請 K8s 權限

---

## 10. 風險登記冊

| # | 風險 | 機率 | 衝擊 | 緩解 | 殘留 |
|---|---|---|---|---|---|
| 1 | login node 重開機，cron 停擺 | 低 | 服務整天不開 | L4 保險絲防失控；重開後 cron 自動恢復 | 當天服務中斷 |
| 2 | 排隊塞車（尖峰） | 中 | 07:00 開不了機 | desired 會持續補交直至成功 | 開機延遲 |
| 3 | 服務進程殭屍（活著但不服務） | 中 | 服務失效無人知 | Phase 3 健康探測 | Phase 1–2 存在 |
| 4 | 作業 log 無限長 | 低 | home 爆量 | `%j` 命名 + Phase 3 輪替 | — |
| 5 | 帳號額度不足 | 低 | sbatch 被拒 | reconcile 會於額度恢復後補齊 | 延遲 |
| 6 | cron 被誤刪 | 低 | 不開不關 | L4 保險絲；sacct 每日對賬 | 需人員發現 |
| 7 | 迷你版被誤判為異常行為 | 低 | 帳號被關注 | 頻率極低（每日 2 次狀態轉移），完全走正規 sbatch | — |
| 8 | 兩個 reconcile 重疊執行，同時補交兩個作業 | 低 | 重複開機、計費翻倍 | `--dependency=singleton` 由 Slurm 排程器原子性擋下（v1.1 新增） | — |

---

## 11. 實施 Check List

> 依本 plan 編寫，作為部署與驗收的逐項勾選清單。全部打勾才算 Phase 完成。

### 11.1 部署前（環境檢查）

- [x] 確認帳號可提交 8gpus：`sbatch --test-only` 已通過（2026-10-03，Node gpu-node-026）— 過程中發現並修正 CPU 上限：**1 GPU 綁 12 CPU**（原設定 16 會被拒）
- [ ] 確認目標節點群可用：`sinfo -p 8gpus -h -o "%t %N"`
- [ ] 確認 `daily_service/` 三腳本語法：`bash -n svc_*.sh`
- [ ] 確認腳本可執行：`chmod +x daily_service/*.sh`
- [ ] 確認無同名舊作業：`squeue -u $USER -n daily-svc`（應為空）
- [ ] 確認服務指令在計算節點可執行（先手動 `srun -p 8gpus ... --pty` 測過）

### 11.2 部署（安裝 crontab）

- [ ] `crontab -e` 加入：`*/5 * * * * /home/your-user/mini_slinky/daily_service/svc_reconcile.sh >> /home/your-user/mini_slinky/daily_service/svc.log 2>&1`
- [ ] 驗證 cron 生效：`crontab -l` 看得到該行
- [ ] 手動觸發一次：`bash daily_service/svc_reconcile.sh; tail daily_service/svc.log`
- [ ] 確認時間窗參數：`START=0700`、`END=1900`（如需調整先改檔）
- [ ] 確認保險絲：`svc_job.sh` 內 `#SBATCH --time=12:30:00`

### 11.3 驗證（Phase 1 驗收，乾跑一週）

**開機**
- [ ] 07:00–07:05 之間 `squeue -n daily-svc` 出現作業（狀態 R 或 PD）
- [ ] `sacct -n -o JobID,State,Elapsed -j <id>` 顯示正常 RUNNING

**冪等**
- [ ] 07:10 再看：仍只有 **1** 個 `daily-svc`（沒有重複開）
- [ ] 手動 `bash svc_start.sh` 兩次：作業數仍 1
- [ ] **Singleton 競態測試**：作業運行中手動 `sbatch svc_job.sh` → 新作業應停在 PENDING（等舊的結束），不會並行第二個；測完 `scancel` 掉 PENDING 那筆

**自癒**
- [ ] `scancel` 砍掉作業 → 5 分鐘內 reconcile 重新提交
- [ ] 進入計算節點 `kill -9` 服務進程 → while 迴圈 3 秒內重啟（檢查 job log）

**關機**
- [ ] 19:00–19:05 作業被 scancel，`squeue -n daily-svc` 為空
- [ ] `sacct` 顯示該日 Elapsed ≈ 12h（非 12.5h，證明是 reconcile 關的不是保險絲）

**保險絲**
- [ ] 測試法（擇一）：暫停 cron 一整天，確認作業最遲 19:30 自行結束、無孤兒
- [ ] 確認結束原因是 COMPLETED（時鐘自我退場）而非 TIMEOUT（-t 硬上限）— 前者為正常路徑
- [ ] 測完恢復 cron，log 無報錯

**連續性**
- [ ] 連續 5 個工作日，`sacct -S <週一> -E <週五> -n daily-svc` 每天恰好 1 筆作業（或自癒後 2 筆且皆有紀錄）

### 11.4 日常維運（上線後）

- [ ] 每日：`tail -20 daily_service/svc.log`（看有無異常開關）
- [ ] 每週：`grep -c reconcile daily_service/svc.log` 對賬次數合理（≈ 每天 288 次減去安靜時段）
- [ ] 每月：檢查 `job_*.log` 大小，超過 100 MB 清理
- [ ] 變更服務時：改 `svc_job.sh` → 隔日 19:00 關機後自動生效（或手動 stop→start）

### 11.5 退場機制

- [ ] 停用服務：`crontab -e` 刪除 reconcile 那行 → 手動 `bash svc_stop.sh`
- [ ] 確認退乾淨：`squeue -u $USER -n daily-svc` 為空、`crontab -l` 無該行
- [ ] 保留 `daily_service/` 與本報告歸檔（下次重用的範本）

---

## 附錄 A：已實作檔案清單

| 路徑 | 說明 |
|---|---|
| `README.md` | 使用者入口：快速導覽、部署一行、FAQ |
| `daily_service/svc_reconcile.sh` | 核心對賬器（cron 每 5 分；窗口參數單一真相來源） |
| `daily_service/svc_job.sh` | 作業本體（背景服務+前景監控自癒；singleton 冪等；雙保險絲） |
| `daily_service/svc_start.sh` | 手動冪等開機（已實測） |
| `daily_service/svc_stop.sh` | 手動保證關機（已實測） |
| `daily_service/svc_status.sh` | 一鍵狀態：desired/actual/窗口/下一步（已實測） |
| `daily_service/svc.log` | reconcile 事件 log（部署後產生） |

## 附錄 B：術語

- **Slinky**：SchedMD 開發（SchedMD 現為 NVIDIA 旗下）的開源專案套件，GitHub 組織 `SlinkyProject`。本叢集使用的是其中 **slurm-bridge** 元件 — 把 K8s 工作負載（Pod / Job / JobSet / **LeaderWorkerSet**）提交成 Slurm job；NVIDIA 於 8,000+ GPU 叢集 production 等級使用（見附錄 C 查證）
- **desired state / reconcile**：宣告目標狀態並週期比對修復的控制模式
- **churn**：desired 超過容量時，提交↔取消的永久震盪
- **fail-safe**：自動化全部失效時，系統自動退回安全狀態（此處 = 作業自我結束）
- **冪等（idempotent）**：同一操作重複執行，結果不變
- **singleton dependency**：Slurm 原生機制（`--dependency=singleton`）：同名且同使用者的作業同時只能有一個存在，新提交者排隊等待 — 等價於 K8s「replica=1」語意，且由 Slurm 排程器原子性保證

---

## 附錄 C：網路查證紀錄（v1.1–v1.2）

本報告關鍵技術主張已於 2026-10-03 以官方文件查證：

| # | 查證項目 | 結果 | 來源 |
|---|---|---|---|
| 1 | Slinky 的出處與定位 | ✅ **更正**：SchedMD 開發（現為 NVIDIA 旗下），GitHub 組織 `SlinkyProject`。本叢集用的元件是 **slurm-bridge**（"Run Slurm as a Kubernetes scheduler"），支援以 Pod/Job/JobSet/**LeaderWorkerSet** 提交工作負載 — 與現場觀察的 LWS 行為吻合。NVIDIA 於 8,000+ GPU 叢集 production 使用 | github.com/SlinkyProject/slurm-bridge、nvidia.com/en-us/software/slinky、developer.nvidia.com/blog（2026-04） |
| 2 | `--requeue` 是否會在時限到期（TIMEOUT）時觸發 | ✅ **不會**。官方手冊明載 requeue 僅於「管理員手動、節點故障、被高優先權搶佔」三情境 → L4 保險絲（`-t 12:30`）可靠，作業不會無限重生 | slurm.schedmd.com/sbatch.html（--requeue 條目） |
| 3 | Slurm 是否有原生的「同名唯一」機制 | ✅ **新發現並已採用**：`--dependency=singleton` — 同名同使用者之作業同時只能存在一個，新提交者排隊等待。由 Slurm 排程器原子性保證，等價於迷你版需要的「replica=1」語意 → 已加入 `svc_job.sh` 作為 L0 防護層 | slurm.schedmd.com/sbatch.html（dependency/singleton 條目） |
| 4 | 補充：`--deadline` 選項存在 | 可作輔助保險（作業無法在期限前結束則移除），本設計以 `-t` + 時鐘自我退場已足夠，列入備選 | slurm.schedmd.com/sbatch.html（--deadline 條目） |
| 5 | 計算節點時區是否與 login 一致（時鐘自我退場的前提） | ✅ 實測（srun 上 GPU 節點）：兩者皆 **CST（Asia/Taipei, UTC+8）**；作業內仍加 `export TZ=Asia/Taipei` 防禦性加固 | 2026-10-03 實測 |

> 查證影響： 術語更正（附錄 B）、(b) 防護層從四層增為五層（§4.5）、(c) 風險 #8 新增並已緩解、(d) Check List 新增 singleton 競態測試。
>
> **v1.2 deep review 追加修正**：(e) 作業腳本改為「背景服務 + 前景 60 秒監控」結構 — 原前景式寫法在真實長駐服務下時鐘檢查永不執行（嚴重）；(f) 窗口參數改由 reconcile 環境變數注入，消除兩處維護；(g) 時區加固（附錄 C #5）。

---

## 附錄 D：測試紀錄（v1.2，2026-10-03 實測）

### D.1 單元測試（`tests/unit_test_reconcile.sh`，mock 叢集指令，零資源）

| # | 案例 | 期望 | 結果 |
|---|---|---|---|
| 1 | 06:55 無作業 | 不動 | ✅ |
| 2 | 07:00 無作業（窗口起點） | sbatch | ✅ |
| 3 | 07:30 作業存在 | 不動（冪等） | ✅ |
| 4 | 18:59 作業存在 | 不動 | ✅ |
| 5 | 19:00 作業存在（窗口終點） | scancel | ✅ |
| 6 | 23:59 無作業 | 不動 | ✅ |
| 7 | 00:00 殘留作業（跨午夜） | scancel | ✅ |
| 8 | 環境變數注入 | sbatch 收到 SVC_START/END | ✅ |

**結果：8/8 PASS**

### D.2 E2E 真實叢集測試（測試名 `svc-selftest`，4 分鐘短窗口）

| # | 步驟 | 證據 | 結果 |
|---|---|---|---|
| 1 | reconcile 提交（desired=1） | Job 491680 於 10 秒內 RUNNING（gpu-node-006） | ✅ |
| 2 | **Singleton 防重複（L0）** | 重複提交 491681 → `PENDING (Dependency)`，未並行 | ✅ |
| 3 | **時鐘自我退場（L4）** | 491680 於 **14:48:04**（=END 1448）自行結束：`COMPLETED 0:0`，Elapsed 3:01，**無人取消** | ✅ |
| 4 | 窗口關閉+無作業 | reconcile 無動作（冪等） | ✅ |
| 5 | 窗口關閉+作業殘留（desired=0） | 491692 被 reconcile scancel，佇列歸零 | ✅ |

**結果：5/5 PASS**；結束後佇列無殘留、測試工作完全清理。

### D.2b 手動腳本補測（v1.3，生產腳本實測）

| # | 步驟 | 證據 | 結果 |
|---|---|---|---|
| 6 | `svc_start.sh` 開機 | Job 491695 提交後 RUNNING | ✅ |
| 7 | `svc_start.sh` 冪等 | 二次執行顯示 `already running, skip`，仍 1 個作業 | ✅ |
| 8 | `svc_stop.sh` 關機 | 顯示 `stopped: 491695`，佇列歸零 | ✅ |
| 9 | `svc_status.sh` | 正確顯示 in-window=是、desired=1、actual=0 與下一步提示 | ✅ |

### D.3 Reviewer 觀察

1. 測試之作業 log 寫到**計算節點本地 `/tmp`**（login 不可見）— 生產版 `svc_job.sh` 寫 home（NFS 共享）無此問題；`--output` 路徑請勿改成節點本地路徑
2. E2E 覆蓋了 Phase 1 Check List 的「singleton 競態」「自我退場 COMPLETED」「reconcile 開/關機」「冪等」四項 — 正式上線前僅剩「連續 5 個工作日」的長期觀察
3. 測試資產保留於 `tests/`（單元測試 + mock + selftest 腳本），可作回歸測試重用

---


*本報告 v1.2 基於 2026-10-03 實地調查與實測（單元 8/8、E2E 5/5）。實施前請依 §11 Check List 逐項驗證。*
