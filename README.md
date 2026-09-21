# BloxAgent Pro (高特權自主 Luau Agent / 多模型端點支援)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Roblox](https://img.shields.io/badge/Roblox-Luau-00A2FF?logo=roblox&logoColor=white)](https://roblox.com)
[![Gemini](https://img.shields.io/badge/Google%20AI-Gemini%202.0-8E75B2?logo=google&logoColor=white)](https://aistudio.google.com)
[![OpenAI](https://img.shields.io/badge/OpenAI-Compatible-412991?logo=openai&logoColor=white)](https://platform.openai.com)
[![Anthropic](https://img.shields.io/badge/Anthropic-Claude-D97706?logo=anthropic&logoColor=white)](https://anthropic.com)

**BloxAgent Pro** 是一款專為 Roblox 高特權執行器環境（支援 UNC / Synapse X API 標準）設計的自主 Luau 逆向與自動化 Agent 框架。原生支援 **Google AI Studio (Gemini)**、**OpenAI 相容協議**（OpenAI、DeepSeek、Groq、Ollama、OpenRouter 等）與 **Anthropic (Claude)** 格式，具備自訂 API URL 端點、雙軌通信、沙盒防禦、看門狗心跳偵測與內建強大逆向工具箱。

---

## 🚀 快速啟動 (One-Line Loader)

在支援 UNC 的執行器（如 Wave, Codex, Delta, Arceus, Synapse 等）中直接執行以下代碼：

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Vaxaxas/BloxAgent/main/BloxAgent.lua"))()
```

---

## ✨ 核心特性

- **🌐 全端點協議適配與自訂 API URL**
  - **Google AI Studio 直連**：原生支援 `gemini-2.0-flash` 等 Gemini 模型系列，具備 Bidi WebSocket 與思考鏈。
  - **OpenAI 相容協議**：完整相容 OpenAI、DeepSeek、Groq、Ollama、OpenRouter、vLLM 等。自動解析 DeepSeek-R1 的 `reasoning_content` 與 `<think>` 思考標籤。
  - **Anthropic 協議**：支援 Claude 3.5 / 3.7 系列，支援 Extended Thinking 與交替對話結構管理。
  - **智慧自訂 URL 端點**：可在 UI 設定面板中自訂 API URL，支援 Base URL 智慧補全或代理直連。
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

## 🔧 API 協議與自訂端點配置 (API Configuration)

點擊 UI 右上角的 ⚙️ 按鈕即可開啟設定面板進行配置：

| 協議格式 | 預設官方端點 (留空即可) | 常見相容服務商與填寫範例 |
| :--- | :--- | :--- |
| **Gemini (Google)** | `https://generativelanguage.googleapis.com` | Google AI Studio 官方金鑰直連；自訂反向代理如 `https://my-proxy.com` |
| **OpenAI 相容** | `https://api.openai.com/v1/chat/completions` | **DeepSeek**: `https://api.deepseek.com/v1`<br>**Groq**: `https://api.groq.com/openai/v1`<br>**Ollama**: `http://localhost:11434/v1`<br>**OpenRouter**: `https://openrouter.ai/api/v1`<br>**SiliconFlow**: `https://api.siliconflow.cn/v1` |
| **Anthropic (Claude)**| `https://api.anthropic.com/v1/messages` | Anthropic 官方金鑰直連；各大 Claude 中轉代理與 Cloudflare AI Gateway |

> 💡 **小提示**：
> - 自訂 API 端點支援填寫 Base URL（系統會自動補齊 `/v1/chat/completions` 或 `/v1/messages`）或完整端點直連。
> - 在使用 DeepSeek-R1 等推理模型時，系統會自動分離思考內容並呈現在 UI 的折疊思考鏈中。

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
