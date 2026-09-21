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
  - 原生支援 `gemini-2.0-flash-exp` 等 Gemini 最新模型系列。
  - 支援設置思考強度（`Think: Off / Low / Medium / High`）。
- **🔄 雙軌通信架構 (Dual-Rail Streaming)**
  - 首選 WebSocket 雙向串流傳輸 (`BidiGenerateContent`)，即時獲取思考鏈與代碼生成。
  - 當前執行器環境不支援 WebSocket 或握手超時自動降級至 HTTP REST API。
- **🛡️ 隔離沙盒與看門狗機制 (Sandbox & Watchdog)**
  - 嚴密隔離環境變數，阻斷對核心程序的非預期修改。
  - 15 秒非阻塞式看門狗定時器，防止無限 busy-wait 循環導致客戶端無響應。
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
