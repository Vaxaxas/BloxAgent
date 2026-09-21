# BloxAgent Pro (加固版 / Google AI Studio 直連)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Roblox](https://img.shields.io/badge/Roblox-Luau-00A2FF?logo=roblox&logoColor=white)](https://roblox.com)
[![Gemini](https://img.shields.io/badge/Google%20AI-Gemini%202.0-8E75B2?logo=google&logoColor=white)](https://aistudio.google.com)

**BloxAgent Pro** 是一款專為 Roblox 高特權執行器環境（支援 UNC / Synapse X API 標準）設計的自主 Luau 逆向與自動化 Agent 框架。直接連接 Google AI Studio，具備雙軌通信、沙盒防禦、看門狗心跳偵測與內建強大逆向工具箱。

---

## 🚀 快速啟動 (One-Line Loader)

在支援 UNC 的執行器（如 Wave, Codex, Delta, Arceus, Synapse 等）中直接執行以下代碼：

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Vaxaxas/BloxAgent/main/BloxAgent.lua"))()
```

---

## ✨ 核心特性

- **⚡ Google AI Studio 直連**
  - 原生支援 `gemini-2.0-flash` 等 Gemini 最新模型系列。
  - 支援設置思考強度（`Think: Off / Low / Medium / High`）。
- **💻 CodeAct 現代運行時架構 (Code as Actions)**
  - 動作空間收斂為原生 Luau 程式碼區塊，單步執行包含遍歷、分支與多 API 調用之完整邏輯，減少 30%+ 往返輪次。
  - **高特權原生執行**：無隔離環境限制，全面釋放 UNC 標準庫（`hookmetamethod`, `getgenv`, `writefile`, `readfile` 等）。
- **🛡️ 雙軌看門狗防護 (Dual-Track Watchdog)**
  - 前置靜態無讓步死循環檢測（防止未加 `task.wait` 之緊密迴圈凍結遊戲視窗）。
  - 非同步心跳守護計時器，超時自動觸發 `task.cancel` 搶佔式終止。
  - 支援語言虛擬機級指令計數鉤子（`debug.sethook`，上限 $10^7$ 指令）。
- **🔄 Auto-Compact 上下文自動壓縮治理**
  - 會話歷史累積至閾值（預設 8 輪）時自動啟動語意提煉壓縮，萃取已驗證環境狀態事實並重置上下文，徹底免疫注意力衰退（Context Rot）。
- **🩺 Reflexion 結構化自愈修復**
  - 搭配 ACI 輸出治理（硬性 100 行/4000 字元截斷）與 Traceback 精準去噪堆疊。
  - 代碼報錯時自動注入因果診斷錨點，強制模型在思考鏈中分析根因並避免重複踩坑。
- **🧭 原生 AgentEnv 工具庫**
  - `AgentEnv.teleport(target)`：支援坐標、CFrame 或玩家名稱自動定位。
  - `AgentEnv.walkTo(target, options)`：基於 `PathfindingService` 實現自動計算航點、跳躍與避障尋路。
  - `AgentEnv.startRemoteSpy(options)` / `stopRemoteSpy()`：覆蓋 `__namecall` 及直接調用的雙軌網路封包監聽器。
  - `AgentEnv.inspectInstance(instance)`：類似 Dex 的屬性、Attributes、Tags (CollectionService) 深度檢視。
  - `AgentEnv.searchInstances(queryName, className, root)`：多維度階層對象搜尋。
  - `AgentEnv.setNoclip(boolean)` / `AgentEnv.setPlayerProperty(prop, val)`：角色物理穿牆與屬性調整。
- **📂 多會話與持久化存儲**
  - 支援多會話隔離、自定義系統提示詞（System Prompt）即時熱更新。
  - 配置、工作階段與 API Key 自動加密保存在執行器 `BloxAgent/` 工作區目錄。

---

## 🖥️ UI 介面操作說明

| 分頁 | 功能描述 |
| :--- | :--- |
| **📋 結果 (Output)** | 顯示 Gemini 的思考過程鏈、執行狀態日誌與沙盒輸出。 |
| **💻 代碼 (Code)** | 即時展示模型提取後的純 Luau 代碼區塊。 |
| **📂 會話 (Sessions)** | 管理多個會話上下文，支援新建、切換、清空記憶與刪除會話。 |
| **⚙️ 提示詞 (Prompt)** | 即時編輯並儲存自定義 System Prompt，亦可一鍵還原預設。 |

---

## ⚙️ 環境相容性需求

執行器需具備 UNC (Unified Naming Convention) 標準函數：
- `request` / `http_request` / `syn.request`
- `WebSocket.connect`（可選，若無則自動走 HTTP 管道）
- `readfile` / `writefile` / `makefolder` / `isfolder`
- `hookmetamethod` / `hookfunction` / `newcclosure` / `checkcaller`
- `getgenv` / `gethui`

---

## 📄 開源協議

本專案採用 [MIT License](LICENSE) 授權。
