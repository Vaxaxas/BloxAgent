-- ==============================================================================
-- BloxAgent Pro (加固版 / Google AI Studio 直連)
-- 雙軌通信 (Bidi WS + HTTP Fallback) | 幀節流渲染 | 沙盒與底層 Hook 防禦
-- ==============================================================================

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local LogService = game:GetService("LogService")
local TextService = game:GetService("TextService")
local PathfindingService = game:GetService("PathfindingService")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer

-- ==================== [ 0. 控制台除錯日誌器 (F9 Console Logger) ] ====================
local function logInfo(tag, msg)
    print(string.format("[BloxAgent:%s] %s", tag, tostring(msg)))
end

local function logWarn(tag, msg)
    warn(string.format("[BloxAgent:%s] ⚠️ %s", tag, tostring(msg)))
end

local function logError(tag, msg)
    warn(string.format("[BloxAgent:%s] ❌ %s", tag, tostring(msg)))
end

logInfo("Core", "BloxAgent Pro 正在初始化...")

-- 清理舊實例與事件連線 (腳本重入防護)
if getgenv and getgenv()._BloxAgentCleanup then
    pcall(getgenv()._BloxAgentCleanup)
    getgenv()._BloxAgentCleanup = nil
end

local guiParent = nil
local guiLocationName = "未知"

if gethui then
    local okHui, resHui = pcall(gethui)
    if okHui and resHui then
        guiParent = resHui
        guiLocationName = "gethui() [隱蔽 UI 容器，防偵測最佳]"
    end
end
if not guiParent then
    local okCore, resCore = pcall(function()
        local core = game:GetService("CoreGui")
        local test = Instance.new("Folder")
        test.Parent = core
        test:Destroy()
        return core
    end)
    if okCore and resCore then
        guiParent = resCore
        guiLocationName = "CoreGui [系統核心層，防死亡重置]"
    end
end
if not guiParent then
    guiParent = LocalPlayer:WaitForChild("PlayerGui")
    guiLocationName = "PlayerGui [本地玩家層，相容保底]"
end
local oldGui = guiParent:FindFirstChild("BloxAgent_Framework")
if oldGui then
    logInfo("Core", "檢測到舊版本 GUI 實例，正在自動清理...")
    pcall(function() oldGui:Destroy() end)
end

-- ==================== [ 1. Workspace 儲存層與路徑配置 ] ====================
local FOLDER_NAME   = "BloxAgent"
local KEY_FILE      = FOLDER_NAME .. "/gemini_key.txt"
local CFG_FILE      = FOLDER_NAME .. "/settings.json"
local PROMPT_FILE   = FOLDER_NAME .. "/system_prompt.txt"
local SESSIONS_FILE = FOLDER_NAME .. "/sessions.json"

local DEFAULT_SYSTEM_INSTRUCTION = [===[You are BloxAgent Pro, an expert autonomous Luau agent and reverse-engineering assistant running natively inside a high-privilege Roblox executor.
You operate on an autonomous CodeAct (Code as Actions) loop with full environment privileges and UNC standard API support.

================================================================================
1. CODEACT PARADIGM & EXECUTION MANDATE
================================================================================
Instead of invoking fragmented JSON tool schemas, you express ALL actions, queries, traversals, and logic directly as executable Luau code blocks:
```luau
-- Your Luau code here
```
When you output a ```luau code block:
1. The Harness runtime executes it immediately inside the native Roblox executor environment with HIGH PRIVILEGES (no sandbox/no isolation).
2. All standard outputs produced by `print(...)` and `warn(...)` are captured and returned to you in the next turn as an [Observation].
3. Runtime errors and stack tracebacks are captured for immediate self-healing (Reflexion loop).
4. MULTI-STEP LOGIC IN ONE BLOCK: Combine instance searches, property reading, conditional branches, loops, and remote calls in a SINGLE script. Do not waste turns.

================================================================================
2. NATIVE ROBLOX & AGENTENV APIS AT YOUR DISPOSAL
================================================================================
You have raw, unrestricted access to the entire Roblox DataModel and UNC executor suite:
- Globals: `game`, `workspace`, `Players`, `LocalPlayer`, `RunService`, `HttpService`, `PathfindingService`, `CollectionService`
- UNC APIs: `hookmetamethod`, `hookfunction`, `getrawmetatable`, `getgenv()`, `getrenv()`, `getreg()`, `writefile()`, `readfile()`, `isfolder()`, `makefolder()`, `setclipboard()`
- `AgentEnv` helper library:
  * `AgentEnv.searchInstances(queryName, className, root)`: Fast search across DataModel tree (e.g. root = workspace).
  * `AgentEnv.inspectInstance(instanceOrPath)`: Return attributes, tags, properties, child count.
  * `AgentEnv.teleport(target)`: Teleport local player to Player, CFrame, Vector3, or Part.
  * `AgentEnv.walkTo(target)`: PathfindingService automated navigation.
  * `AgentEnv.startRemoteSpy(filter)` / `AgentEnv.stopRemoteSpy()`: Intercept FireServer/InvokeServer.
  * `AgentEnv.setNoclip(boolean)`: Toggle character wall collision.
  * `AgentEnv.setPlayerProperty(prop, value)`: Adjust WalkSpeed, JumpPower, etc.
  * `AgentEnv.heartbeat()`: Pulse execution watchdog heartbeat during long operations.

================================================================================
3. ROBLOX SCRIPTING & WATCHDOG SAFETY RULES
================================================================================
- NEVER write unbounded busy-loops (`while true do`). Always yield with `task.wait()` or `RunService.Heartbeat:Wait()`.
- Yielding automatically pulses the Watchdog heartbeat. If a loop runs for >20 seconds without yielding, the Watchdog will preemptively cancel it.
- Always use `print(...)` to output discovered information, state changes, and findings.
- When creating metamethod hooks, ALWAYS verify caller: `if checkcaller() then return oldNamecall(self, ...) end`.
- When your goal is achieved, or when answering general conceptual questions without needing code execution, respond with clear markdown text without code blocks.
- If an execution fails with an error traceback, analyze the root cause carefully, explain the mistake briefly, and provide the corrected code block.]===]

local DEFAULT_CONFIG = {
    MODEL = "gemini-2.0-flash",
    THINK_LEVEL = "Medium",
    MAX_HISTORY = 12,
    AUTO_EXECUTE = true,       -- 自動執行模型生成的 Luau 代碼 (若為 false 需手動確認批准)
    AUTO_COMPACT = true,       -- 自動上下文壓縮治理 (防範 Context Rot)
    COMPACT_THRESHOLD = 8,     -- 當歷史達到 8 輪時觸發記憶壓縮提煉
    PC_TOGGLE_KEY = "RightControl",
    GUI_TRANSPARENCY = 0.05,
    GUI_SCALE = 1.0,           -- GUI 整體縮放比例 (0.5 ~ 2.0)
    COMM_METHOD = "HTTP",      -- 通信方式: "HTTP" (標準 REST) 或 "WebSocket" (Bidi 雙向串流)
    WS_TIMEOUT = 25,           -- WebSocket 等待逾時 (waitStart 判定秒數, 預設 25s)
    WATCHDOG_TIMEOUT = 20,     -- 代碼執行防死循環看門狗超時 (秒, 預設 20s)
    TEMPERATURE = 0.1,         -- 生成溫度 (0.0 ~ 1.0)
    MAX_OUTPUT_TOKENS = 8192   -- 最大生成 Token 數
}

local Config = table.clone(DEFAULT_CONFIG)
local CurrentApiKey = ""
local CurrentSystemPrompt = DEFAULT_SYSTEM_INSTRUCTION

local function sanitizeSecret(str)
    if not str then return "" end
    local s = tostring(str)
    if CurrentApiKey and #CurrentApiKey > 0 then
        s = s:gsub(CurrentApiKey, "REDACTED_KEY")
    end
    return s
end

local function ensureWorkspaceFolder()
    if isfolder and makefolder then
        local ok, exists = pcall(isfolder, FOLDER_NAME)
        if ok and not exists then
            pcall(makefolder, FOLDER_NAME)
        end
    end
end

-- ==================== [ 2. 輔助序列化與代碼提取工具 ] ====================
local function sanitizeForJSON(val, depth, visited)
    if depth and depth > 4 then return "[Depth Limit]" end
    visited = visited or {}
    local t = typeof(val)

    if t == "number" then
        if val ~= val then
            return "[NaN]"
        elseif val == math.huge then
            return "[+Infinity]"
        elseif val == -math.huge then
            return "[-Infinity]"
        end
        return val
    elseif t == "string" then
        -- 清除非法 ASCII 控制字元與空位元組 (\0-\8, \11-\12, \14-\31)，保留 \t, \n, \r
        return (val:gsub("[%z\1-\8\11\12\14-\31]", ""))
    elseif t == "table" then
        if visited[val] then return "[Circular]" end
        visited[val] = true
        local clean = {}
        local isArray = (#val > 0)
        local okIter, iterErr = pcall(function()
            if isArray then
                for i = 1, #val do
                    clean[i] = sanitizeForJSON(val[i], (depth or 0) + 1, visited)
                end
            else
                for k, v in pairs(val) do
                    clean[tostring(k)] = sanitizeForJSON(v, (depth or 0) + 1, visited)
                end
            end
        end)
        visited[val] = nil
        if not okIter then return "[Protected Table: " .. tostring(iterErr) .. "]" end
        return clean
    elseif t == "Instance" then
        local ok, fullName = pcall(val.GetFullName, val)
        return string.format("<%s> %s", val.ClassName, ok and fullName or val.Name)
    elseif t == "Vector3" or t == "CFrame" or t == "Color3" or t == "UDim2" or t == "UDim" or t == "Ray" or t == "BrickColor" then
        return tostring(val)
    elseif t == "function" or t == "thread" or t == "userdata" or t == "RBXScriptConnection" then
        return string.format("[%s]", t)
    else
        return tostring(val)
    end
end

local function extractLuaCode(text)
    if not text or typeof(text) ~= "string" then return nil end
    local best = nil
    for codeBlock in text:gmatch("```[Ll][Uu][Aa][Uu]?%s*\n?(.-)%s*```") do
        if not best or #codeBlock > #best then
            best = codeBlock
        end
    end
    if not best then
        for codeBlock in text:gmatch("```[%w_-]*%s*\n?(.-)%s*```") do
            -- 若捕獲到首行的語言標記 (例如 ```luau)，將首行語言標籤剔除
            local cleaned = codeBlock:gsub("^[Ll][Uu][Aa][Uu]?%s*\n", "")
            if not best or #cleaned > #best then
                best = cleaned
            end
        end
    end
    if not best then
        -- 容錯機制：若模型直接回傳無 Markdown 標記的純 Lua 代碼
        local trimmed = text:match("^%s*(.-)%s*$")
        if trimmed and (#trimmed > 5) then
            if trimmed:sub(1, 2) == "--" or trimmed:match("^local%s") or trimmed:match("^print%(") or trimmed:match("^game:") or trimmed:match("^task%.") then
                best = trimmed
            end
        end
    end
    return best
end

-- ==================== [ 3. Session 會話管理器與安全持久化 ] ====================
local function safeJSONEncode(data)
    local ok, res = pcall(function()
        return HttpService:JSONEncode(data)
    end)
    return ok and res or nil
end

local function safeJSONDecode(str)
    local ok, res = pcall(function()
        return HttpService:JSONDecode(str)
    end)
    return ok and res or nil
end

local function safeWriteFile(path, content)
    if not writefile then return false end
    return pcall(function()
        writefile(path, content)
    end)
end

local function safeReadFile(path)
    if not readfile then return false, nil end
    if isfile then
        local ok, exists = pcall(isfile, path)
        if not ok or not exists then return false, nil end
    end
    return pcall(readfile, path)
end

local SessionManager = {
    List = {},
    ActiveId = ""
}

local function saveSessionsToWorkspace()
    ensureWorkspaceFolder()
    local sanitizedList = {}
    for _, s in ipairs(SessionManager.List) do
        local cleanHist = {}
        local startIdx = math.max(1, #s.history - (Config.MAX_HISTORY * 2) + 1)
        for i = startIdx, #s.history do
            table.insert(cleanHist, s.history[i])
        end

        local cleanMsgs = {}
        if s.messages then
            local msgStart = math.max(1, #s.messages - 30)
            for i = msgStart, #s.messages do
                table.insert(cleanMsgs, s.messages[i])
            end
        end

        table.insert(sanitizedList, {
            id = s.id,
            name = s.name,
            history = cleanHist,
            messages = cleanMsgs,
            lastOutput = (s.lastOutput and #s.lastOutput > 2500) and (s.lastOutput:sub(1, 2500) .. "\n...[已截斷]") or s.lastOutput,
            lastCode = s.lastCode,
            createdAt = s.createdAt
        })
    end

    local payload = {
        activeId = SessionManager.ActiveId,
        sessions = sanitizedList
    }
    local encoded = safeJSONEncode(payload)
    if encoded then
        safeWriteFile(SESSIONS_FILE, encoded)
    end
end

local function createNewSession(customName)
    local newId = "sess_" .. tostring(os.time()) .. "_" .. tostring(math.random(100, 999))
    local sess = {
        id = newId,
        name = customName or ("Session #" .. tostring(#SessionManager.List + 1)),
        history = {},
        messages = {},
        lastOutput = "[BloxAgent] 新會話已就緒。支援串流對話、可摺疊思考鏈與自主修復循環。",
        lastCode = "-- 尚未生成代碼",
        createdAt = os.date("%H:%M:%S")
    }
    table.insert(SessionManager.List, sess)
    SessionManager.ActiveId = newId
    saveSessionsToWorkspace()
    return sess
end

local function getActiveSession()
    for _, s in ipairs(SessionManager.List) do
        if s.id == SessionManager.ActiveId then
            return s
        end
    end
    if #SessionManager.List > 0 then
        SessionManager.ActiveId = SessionManager.List[1].id
        return SessionManager.List[1]
    end
    return createNewSession("預設會話 (Default)")
end

local function loadFromWorkspace()
    ensureWorkspaceFolder()
    local okK, contentK = safeReadFile(KEY_FILE)
    if okK and contentK and #contentK > 0 then
        CurrentApiKey = (contentK:gsub("%s+", ""))
    end

    local okC, contentC = safeReadFile(CFG_FILE)
    if okC and contentC and #contentC > 0 then
        local parsed = safeJSONDecode(contentC)
        if parsed and typeof(parsed) == "table" then
            for k, v in pairs(parsed) do Config[k] = v end
        end
    end

    local okP, contentP = safeReadFile(PROMPT_FILE)
    if okP and contentP and #contentP > 0 then
        CurrentSystemPrompt = contentP
    end

    local okS, contentS = safeReadFile(SESSIONS_FILE)
    if okS and contentS and #contentS > 0 then
        local parsedS = safeJSONDecode(contentS)
        if parsedS and typeof(parsedS) == "table" and parsedS.sessions and #parsedS.sessions > 0 then
            for _, sess in ipairs(parsedS.sessions) do
                if not sess.messages then
                    sess.messages = {}
                    if sess.lastOutput and #sess.lastOutput > 0 then
                        table.insert(sess.messages, {
                            role = "assistant",
                            text = sess.lastOutput,
                            code = sess.lastCode,
                            status = "success",
                            time = sess.createdAt or "00:00:00"
                        })
                    end
                end
            end
            SessionManager.List = parsedS.sessions
            SessionManager.ActiveId = parsedS.activeId or parsedS.sessions[1].id
        end
    end

    if #SessionManager.List == 0 then
        createNewSession("預設會話 (Default)")
    end
end

local function saveApiKey(key)
    ensureWorkspaceFolder()
    safeWriteFile(KEY_FILE, (key:gsub("%s+", "")))
end

local function saveConfig()
    ensureWorkspaceFolder()
    local encoded = safeJSONEncode(Config)
    if encoded then
        safeWriteFile(CFG_FILE, encoded)
    end
end

local function savePrompt(promptText)
    ensureWorkspaceFolder()
    safeWriteFile(PROMPT_FILE, promptText)
end

loadFromWorkspace()

-- ==================== [ 4. sUNC 全環境相容層 (Universal sUNC Adapter) ] ====================
local function resolveHttpRequest()
    if typeof(request) == "function" then return request end
    if typeof(http_request) == "function" then return http_request end
    if syn and typeof(syn.request) == "function" then return syn.request end
    if http and typeof(http.request) == "function" then return http.request end
    if fluxus and typeof(fluxus.request) == "function" then return fluxus.request end
    if krnl and typeof(krnl.request) == "function" then return krnl.request end
    return nil
end

local function resolveWsConnect()
    if WebSocket and typeof(WebSocket.connect) == "function" then return WebSocket.connect end
    if WebSocket and typeof(WebSocket.Connect) == "function" then return WebSocket.Connect end
    if websocket and typeof(websocket.connect) == "function" then return websocket.connect end
    if websocket and typeof(websocket.Connect) == "function" then return websocket.Connect end
    if syn and syn.websocket and typeof(syn.websocket.connect) == "function" then return syn.websocket.connect end
    if krnl and krnl.websocket and typeof(krnl.websocket.connect) == "function" then return krnl.websocket.connect end
    return nil
end

local rawHttpRequest = resolveHttpRequest()
local wsConnect = resolveWsConnect()
guiParent = guiParent or (gethui and gethui()) or (pcall(function() return game:GetService("CoreGui") end) and game:GetService("CoreGui")) or LocalPlayer:WaitForChild("PlayerGui")

local activeWebSocket = nil
local lastWatchdogHeartbeat = os.clock()

-- sUNC 萬能請求分發器 (自動適配大小寫命名與不同 Executor 的返回值結構)
local function universalHttpRequest(url, method, headers, body)
    if not rawHttpRequest then
        return false, nil, "當前 Executor 未提供任何 sUNC 網路請求函數 (request / http_request)"
    end

    if not url or url == "" then
        return false, nil, "HTTP 請求 URL 為空"
    end

    local payload = {
        Url = url,
        url = url,
        Method = method or "GET",
        method = method or "GET",
        Headers = headers or {},
        headers = headers or {},
        Body = body or "",
        body = body or "",
        Timeout = 60,
        timeout = 60
    }

    local ok, res = pcall(rawHttpRequest, payload)

    -- 某些 Executor 的 request() 不接受 table，嘗試以原生 syn.request 格式重試
    if not ok and typeof(res) == "string" and (res:find("Argument") or res:find("missing") or res:find("nil") or res:find("invalid argument")) then
        logWarn("HTTP", "嘗試替代請求格式 (標準 sUNC table 調用失敗)...")
        -- 嘗試 syn.request 精簡格式 (僅保留標準大寫鍵名)
        local synPayload = {
            Url = url,
            Method = method or "GET",
            Headers = headers or {},
            Body = body or ""
        }
        ok, res = pcall(rawHttpRequest, synPayload)
    end

    if not ok then
        local errDetail = sanitizeSecret(tostring(res or "Executor 網路調用崩潰"))
        logError("HTTP", "sUNC pcall 異常: " .. errDetail)
        return false, nil, errDetail
    end

    -- 部分 Executor 直接回傳 body 字串而非 table
    if typeof(res) == "string" then
        return true, {
            StatusCode = 200,
            Body = res,
            Headers = {}
        }, nil
    end

    if typeof(res) ~= "table" then
        return false, nil, sanitizeSecret("Executor 請求回傳格式異常 (type=" .. typeof(res) .. "): " .. tostring(res):sub(1, 100))
    end

    local statusCode = res.StatusCode or res.statusCode or res.Status or res.status_code or res.status or 0
    local resBody = res.Body or res.body or ""
    local resHeaders = res.Headers or res.headers or {}

    local numStatus = tonumber(tostring(statusCode):match("%d+")) or 0

    return true, {
        StatusCode = numStatus,
        Body = tostring(resBody),
        Headers = resHeaders
    }, nil
end

local function doesModelSupportBidiWS(modelName)
    if not modelName or typeof(modelName) ~= "string" then return false end
    local m = modelName:lower()
    -- Google AI Studio 的 Bidi WebSocket (BidiGenerateContent) 僅支援 2.0-flash-exp 或 realtime 系列
    return m:find("2.0-flash-exp", 1, true) ~= nil or m:find("realtime", 1, true) ~= nil
end

logInfo("UNC", string.format("sUNC 檢測: HTTP 函數 = %s, WebSocket 函數 = %s", rawHttpRequest and "可用" or "缺失", wsConnect and "可用" or "缺失"))

-- ==================== [ 4.5 DataModel 實例路徑解析器 ] ====================
local function resolveInstanceByPath(pathStr)
    if not pathStr or typeof(pathStr) ~= "string" then return nil end
    local clean = pathStr:gsub("^game%.", ""):gsub("^workspace%.", "Workspace.")
    local parts = {}
    for part in clean:gmatch("[^%.]+") do
        table.insert(parts, part)
    end
    if #parts == 0 then return nil end

    local current = game
    for _, name in ipairs(parts) do
        local ok, nextInst = pcall(function()
            if current == game then
                local s = game:FindService(name)
                if s then return s end
            end
            return current:FindFirstChild(name)
        end)
        if ok and nextInst then
            current = nextInst
        else
            return nil
        end
    end
    return current
end

-- ==================== [ 5. AgentEnv 核心模組 ] ====================
local AgentEnv = {
    Logs = {},
    RemoteLogs = {},
    BlockedRemotes = {},
    RemoteSpyActive = false,
    ActiveFilter = nil,
    NoclipActive = false,
}

function AgentEnv.heartbeat()
    lastWatchdogHeartbeat = os.clock()
end

function AgentEnv.searchInstances(queryName, className, root)
    root = root or workspace
    local matches = {}
    local targets = {}
    local okDesc, desc = pcall(function() return root:GetDescendants() end)
    if okDesc and desc then
        targets = desc
    else
        pcall(function()
            for _, child in ipairs(root:GetChildren()) do
                pcall(function()
                    for _, d in ipairs(child:GetDescendants()) do
                        table.insert(targets, d)
                    end
                end)
            end
        end)
    end

    local qLower = (queryName and queryName ~= "") and queryName:lower() or nil
    local cName = (className and className ~= "") and className or nil

    for _, inst in ipairs(targets) do
        local matchName = (not qLower) or string.find(inst.Name:lower(), qLower, 1, true)
        local matchClass = (not cName) or (pcall(function() return inst:IsA(cName) end) and inst:IsA(cName))
        if matchName and matchClass then
            local okFull, fullPath = pcall(inst.GetFullName, inst)
            table.insert(matches, okFull and fullPath or inst.Name)
            if #matches >= 40 then break end
        end
    end
    return matches
end
AgentEnv.findInstances = AgentEnv.searchInstances

function AgentEnv.teleport(target)
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp or not hum then return false, "找不到本地 Humanoid 或 HumanoidRootPart" end

    -- 解除坐姿以防被載具約束或彈出
    if hum.Sit then
        hum.Sit = false
        task.wait(0.05)
    end

    -- 傳送前清除角色殘留速度以防甩飛
    pcall(function()
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
    end)

    local targetCFrame = nil
    if typeof(target) == "CFrame" then
        targetCFrame = target
    elseif typeof(target) == "Vector3" then
        targetCFrame = CFrame.new(target)
    elseif typeof(target) == "Instance" then
        if target:IsA("BasePart") then
            targetCFrame = target.CFrame + Vector3.new(0, 3, 0)
        elseif target:IsA("Model") then
            targetCFrame = target:GetPivot() + Vector3.new(0, 3, 0)
        elseif target:IsA("PVInstance") then
            targetCFrame = target:GetPivot() + Vector3.new(0, 3, 0)
        else
            return false, "傳送目標 Instance 必須為 BasePart 或 Model (PVInstance)"
        end
    elseif typeof(target) == "string" then
        local x, y, z = target:match("^%s*([-%d%.]+)%s*,%s*([-%d%.]+)%s*,%s*([-%d%.]+)%s*$")
        if x and y and z then
            local vx, vy, vz = tonumber(x), tonumber(y), tonumber(z)
            if vx and vy and vz then
                targetCFrame = CFrame.new(vx, vy, vz)
            end
        end

        if not targetCFrame then
            local resolved = resolveInstanceByPath(target) or workspace:FindFirstChild(target, true)
            if resolved and typeof(resolved) == "Instance" then
                if resolved:IsA("BasePart") then
                    targetCFrame = resolved.CFrame + Vector3.new(0, 3, 0)
                elseif resolved:IsA("Model") or resolved:IsA("PVInstance") then
                    targetCFrame = resolved:GetPivot() + Vector3.new(0, 3, 0)
                end
            end
        end

        if not targetCFrame then
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= LocalPlayer and (string.find(p.Name:lower(), target:lower(), 1, true) or (p.DisplayName and string.find(p.DisplayName:lower(), target:lower(), 1, true))) then
                    if p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
                        targetCFrame = p.Character.HumanoidRootPart.CFrame + Vector3.new(0, 3, 0)
                        break
                    end
                end
            end
        end
        if not targetCFrame then return false, "未找到指定座標、部件或玩家: " .. tostring(target) end
    end

    if not targetCFrame then return false, "無法解析傳送目標" end

    hrp.CFrame = targetCFrame

    pcall(function()
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
    end)

    return true, "傳送完成"
end

function AgentEnv.walkTo(target, options)
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hum or not hrp or hum.Health <= 0 then return false, "缺少有效的 Humanoid 或 HumanoidRootPart" end

    local destPos = nil
    if typeof(target) == "Vector3" then
        destPos = target
    elseif typeof(target) == "CFrame" then
        destPos = target.Position
    elseif typeof(target) == "Instance" then
        if target:IsA("BasePart") then
            destPos = target.Position
        elseif target:IsA("Model") and target.PrimaryPart then
            destPos = target.PrimaryPart.Position
        elseif target:IsA("PVInstance") then
            destPos = target:GetPivot().Position
        else
            return false, "尋路目標 Instance 必須為 PVInstance (BasePart 或 Model)"
        end
    elseif typeof(target) == "string" then
        local x, y, z = target:match("^%s*([-%d%.]+)%s*,%s*([-%d%.]+)%s*,%s*([-%d%.]+)%s*$")
        if x and y and z then
            local vx, vy, vz = tonumber(x), tonumber(y), tonumber(z)
            if vx and vy and vz then
                destPos = Vector3.new(vx, vy, vz)
            end
        end

        if not destPos then
            local resolved = resolveInstanceByPath(target) or workspace:FindFirstChild(target, true)
            if resolved and typeof(resolved) == "Instance" then
                if resolved:IsA("BasePart") then
                    destPos = resolved.Position
                elseif resolved:IsA("Model") and resolved.PrimaryPart then
                    destPos = resolved.PrimaryPart.Position
                elseif resolved:IsA("PVInstance") then
                    destPos = resolved:GetPivot().Position
                end
            end
        end

        if not destPos then
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= LocalPlayer and (string.find(p.Name:lower(), target:lower(), 1, true) or (p.DisplayName and string.find(p.DisplayName:lower(), target:lower(), 1, true))) then
                    if p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
                        destPos = p.Character.HumanoidRootPart.Position
                        break
                    end
                end
            end
        end
    end

    if not destPos then return false, "無法解析尋路目標: " .. tostring(target) end

    options = options or {}
    local path = PathfindingService:CreatePath({
        AgentRadius = options.AgentRadius or 2.5,
        AgentHeight = options.AgentHeight or 5.0,
        AgentCanJump = options.AgentCanJump ~= false,
        WaypointSpacing = options.WaypointSpacing or 4.0
    })

    local calcOk, calcErr = pcall(function()
        path:ComputeAsync(hrp.Position, destPos)
    end)

    if not calcOk or path.Status ~= Enum.PathStatus.Success then
        return false, "尋路計算失敗: " .. tostring(calcErr or path.Status.Name)
    end

    local waypoints = path:GetWaypoints()
    local consecutiveStuck = 0

    for i, wp in ipairs(waypoints) do
        AgentEnv.heartbeat()

        -- 檢查每步的存活性
        local curChar = LocalPlayer.Character
        local curHum = curChar and curChar:FindFirstChildOfClass("Humanoid")
        local curHrp = curChar and curChar:FindFirstChild("HumanoidRootPart")
        if not curChar or not curHum or not curHrp or curHum.Health <= 0 then
            return false, "尋路中斷：本地角色不存在或已死亡"
        end

        if wp.Action == Enum.PathWaypointAction.Jump then
            curHum.Jump = true
        end
        curHum:MoveTo(wp.Position)

        local reached = false
        local conn
        local connectOk = pcall(function()
            conn = curHum.MoveToFinished:Connect(function(didReach)
                if didReach then reached = true end
            end)
        end)

        local startT = os.clock()
        while not reached and (os.clock() - startT < 3.5) do
            AgentEnv.heartbeat()
            if curHrp and (curHrp.Position - wp.Position).Magnitude < 3.5 then
                reached = true
                break
            end
            task.wait(0.05)
        end

        if connectOk and conn then
            pcall(function() conn:Disconnect() end)
        end

        if not reached and curHrp and (curHrp.Position - wp.Position).Magnitude >= 3.5 then
            consecutiveStuck = consecutiveStuck + 1
            if consecutiveStuck >= 3 then
                return false, string.format("尋路失敗：在第 %d/%d 個航點連續受阻無法通行", i, #waypoints)
            end
        else
            consecutiveStuck = 0
        end
    end

    return true, string.format("尋路到達目標 (順利通過 %d 個航點)", #waypoints)
end

-- ==================== [ sUNC Hooking & Remote Spy 互斥引擎 ] ====================
local hasHookMetamethod = (typeof(hookmetamethod) == "function")
local hasHookFunction = (typeof(hookfunction) == "function")
local hasNewcclosure = (typeof(newcclosure) == "function")
local hasCheckcaller = (typeof(checkcaller) == "function")
local hasGetNamecallMethod = (typeof(getnamecallmethod) == "function")
local hasSetNamecallMethod = (typeof(setnamecallmethod) == "function")

local function safeNewcclosure(fn)
    if hasNewcclosure then
        local ok, wrapped = pcall(newcclosure, fn)
        if ok and wrapped then return wrapped end
    end
    return fn
end

local function safeCheckcaller()
    if hasCheckcaller then
        local ok, isExecutorCall = pcall(checkcaller)
        if ok then return isExecutorCall end
    end
    return false
end

local originalNamecall = nil
local originalFireServer = nil
local originalInvokeServer = nil
local dummyRemoteEvent = nil
local dummyRemoteFunction = nil

local function internalRecordRemote(inst, method, args)
    if not inst or typeof(inst) ~= "Instance" then return false end
    local okName, rName = pcall(function() return inst.Name end)
    if not okName or not rName then return false end

    if AgentEnv.BlockedRemotes[rName] or AgentEnv.BlockedRemotes[inst] then
        return true
    end

    if AgentEnv.ActiveFilter and AgentEnv.ActiveFilter ~= "" then
        if not string.find(rName:lower(), AgentEnv.ActiveFilter:lower(), 1, true) then
            return false
        end
    end

    if AgentEnv.RemoteSpyActive then
        local cleanArgs = sanitizeForJSON(args)
        local okFull, fullPath = pcall(inst.GetFullName, inst)
        table.insert(AgentEnv.RemoteLogs, {
            time = os.date("%H:%M:%S"),
            name = rName,
            remote = okFull and fullPath or rName,
            method = method,
            args = cleanArgs
        })

        if #AgentEnv.RemoteLogs > 150 then
            table.remove(AgentEnv.RemoteLogs, 1)
        end
    end
    return false
end

function AgentEnv.startRemoteSpy(options)
    AgentEnv.ActiveFilter = (options and options.filter and options.filter ~= "") and options.filter or nil
    if AgentEnv.RemoteSpyActive then return true, "Remote Spy 運作中" end

    if hasHookMetamethod and hasGetNamecallMethod then
        if not originalNamecall then
            local hookFn = safeNewcclosure(function(self, ...)
                local method = hasGetNamecallMethod and getnamecallmethod()
                if not AgentEnv.RemoteSpyActive and not next(AgentEnv.BlockedRemotes) then
                    if hasSetNamecallMethod and method then setnamecallmethod(method) end
                    return originalNamecall(self, ...)
                end
                if not safeCheckcaller() then
                    if method == "FireServer" or method == "InvokeServer" then
                        if internalRecordRemote(self, method, {...}) then
                            return nil
                        end
                    end
                end
                if hasSetNamecallMethod and method then setnamecallmethod(method) end
                return originalNamecall(self, ...)
            end)
            local okHook, resHook = pcall(hookmetamethod, game, "__namecall", hookFn)
            if okHook then
                originalNamecall = resHook
                logInfo("Hook", "已啟用 hookmetamethod(__namecall) 攔截軌道")
            else
                logWarn("Hook", "hookmetamethod 攔截失敗: " .. tostring(resHook))
            end
        end
    end

    if not originalNamecall and hasHookFunction then
        -- 僅在缺少 hookmetamethod 或 hookmetamethod 失敗時使用 hookfunction 作為備用防線
        if not originalFireServer then
            dummyRemoteEvent = Instance.new("RemoteEvent")
            local hookEventFn = safeNewcclosure(function(self, ...)
                if not AgentEnv.RemoteSpyActive and not next(AgentEnv.BlockedRemotes) then
                    return originalFireServer(self, ...)
                end
                if not safeCheckcaller() and internalRecordRemote(self, "FireServer", {...}) then
                    return nil
                end
                return originalFireServer(self, ...)
            end)
            local okHook, res = pcall(hookfunction, dummyRemoteEvent.FireServer, hookEventFn)
            if okHook then
                originalFireServer = res
                logInfo("Hook", "已啟用 hookfunction(FireServer) 備用攔截軌道")
            end
        end

        if not originalInvokeServer then
            dummyRemoteFunction = Instance.new("RemoteFunction")
            local hookFuncFn = safeNewcclosure(function(self, ...)
                if not AgentEnv.RemoteSpyActive and not next(AgentEnv.BlockedRemotes) then
                    return originalInvokeServer(self, ...)
                end
                if not safeCheckcaller() and internalRecordRemote(self, "InvokeServer", {...}) then
                    return nil
                end
                return originalInvokeServer(self, ...)
            end)
            local okHook, res = pcall(hookfunction, dummyRemoteFunction.InvokeServer, hookFuncFn)
            if okHook then
                originalInvokeServer = res
                logInfo("Hook", "已啟用 hookfunction(InvokeServer) 備用攔截軌道")
            end
        end
    end

    if not originalNamecall and not originalFireServer then
        logWarn("Hook", "當前 Executor 不支援任何 Hook 原語或 Hook 安裝失敗，Remote Spy 無法截獲網絡通訊")
        return false, "Executor 缺少 Hook 原語或 Hook 安裝失敗"
    end

    AgentEnv.RemoteSpyActive = true
    return true, "Remote Spy 攔截已啟動"
end

function AgentEnv.stopRemoteSpy()
    AgentEnv.RemoteSpyActive = false
    AgentEnv.ActiveFilter = nil
    return true, "Remote Spy 已停止監聽 (零開銷旁路已啟用)"
end

function AgentEnv.inspectInstance(inst)
    if typeof(inst) ~= "Instance" then return nil, "目標非 Instance 物件" end

    local okFull, fullName = pcall(inst.GetFullName, inst)
    local okParent, parentName = pcall(function()
        if not inst.Parent then return "nil" end
        local okP, pFull = pcall(inst.Parent.GetFullName, inst.Parent)
        return okP and pFull or inst.Parent.Name
    end)

    local inspection = {
        Name = inst.Name,
        ClassName = inst.ClassName,
        FullName = okFull and fullName or inst.Name,
        Parent = okParent and parentName or "nil",
        ChildrenCount = #inst:GetChildren(),
        Properties = {},
        Attributes = sanitizeForJSON(inst:GetAttributes()),
        Tags = CollectionService:GetTags(inst)
    }

    local propsToCheck = {
        "Position", "CFrame", "Size", "CanCollide", "Anchored", "Transparency", "Material", "Color",
        "WalkSpeed", "JumpPower", "JumpHeight", "HipHeight",
        "Value", "Text", "Visible", "Enabled", "Active", "ZIndex", "SoundId", "Playing", "Volume"
    }

    for _, pName in ipairs(propsToCheck) do
        local ok, val = pcall(function() return inst[pName] end)
        if ok and val ~= nil then
            inspection.Properties[pName] = tostring(val)
        end
    end

    return inspection
end

function AgentEnv.setPlayerProperty(prop, value)
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        local okSet = pcall(function() hum[prop] = value end)
        return okSet
    end
    return false
end

local noclipConnection = nil

function AgentEnv.setNoclip(state)
    AgentEnv.NoclipActive = state
    if state then
        if not noclipConnection then
            noclipConnection = RunService.Stepped:Connect(function()
                if AgentEnv.NoclipActive and LocalPlayer.Character then
                    for _, part in ipairs(LocalPlayer.Character:GetDescendants()) do
                        if part:IsA("BasePart") and part.CanCollide then
                            part.CanCollide = false
                        end
                    end
                end
            end)
        end
    else
        if noclipConnection then
            pcall(function() noclipConnection:Disconnect() end)
            noclipConnection = nil
        end
        if LocalPlayer.Character then
            for _, part in ipairs(LocalPlayer.Character:GetDescendants()) do
                if part:IsA("BasePart") and (part.Name == "UpperTorso" or part.Name == "LowerTorso" or part.Name == "Torso") then
                    part.CanCollide = true
                end
            end
        end
    end
end

getgenv().AgentEnv = AgentEnv

-- 註冊全局釋放回調 (防止重入洩漏)
getgenv()._BloxAgentCleanup = function()
    if noclipConnection then
        pcall(function() noclipConnection:Disconnect() end)
        noclipConnection = nil
    end
    if activeWebSocket then
        pcall(function()
            if activeWebSocket.Close then activeWebSocket:Close()
            elseif activeWebSocket.close then activeWebSocket:close() end
        end)
        activeWebSocket = nil
    end
    if currentCodeThread then pcall(task.cancel, currentCodeThread) end
    if currentMainThread then pcall(task.cancel, currentMainThread) end
end

-- ==================== [ 5.1 Agent 註冊工具庫 (Registered Tool Declarations) ] ====================
local AGENT_TOOL_DECLARATIONS = {
    {
        name = "execute_luau",
        description = "Executes arbitrary Luau script in the Roblox executor sandbox with full game and UNC access. Standard output from print() and runtime errors are captured in the observation.",
        parameters = {
            type = "OBJECT",
            properties = {
                code = { type = "STRING", description = "The Luau code to run." }
            },
            required = { "code" }
        }
    },
    {
        name = "find_instances",
        description = "Searches the Roblox DataModel tree for instances matching queryName and/or className (e.g. RemoteEvents, Parts, Models, Player characters).",
        parameters = {
            type = "OBJECT",
            properties = {
                queryName = { type = "STRING", description = "Name substring to filter instances." },
                className = { type = "STRING", description = "ClassName to filter (e.g. 'RemoteEvent', 'Part', 'Model')." },
                root = { type = "STRING", description = "Root container name: 'workspace', 'ReplicatedStorage', 'Players', etc. Defaults to 'workspace'." }
            }
        }
    },
    {
        name = "inspect_instance",
        description = "Deeply inspects an instance at the specified path, returning its ClassName, Parent, Children count, Attributes, Tags, and core Properties (Position, CFrame, WalkSpeed, etc.).",
        parameters = {
            type = "OBJECT",
            properties = {
                path = { type = "STRING", description = "Full path or name of the instance (e.g. 'game.ReplicatedStorage.Remotes.BuyItem')." }
            },
            required = { "path" }
        }
    },
    {
        name = "teleport",
        description = "Teleports the local player character to a specified target (Player name, Instance name, or coordinates 'X, Y, Z').",
        parameters = {
            type = "OBJECT",
            properties = {
                target = { type = "STRING", description = "Target player name, part name, or coordinates." }
            },
            required = { "target" }
        }
    },
    {
        name = "walk_to",
        description = "Uses PathfindingService to calculate waypoints and walk the local player character to the target.",
        parameters = {
            type = "OBJECT",
            properties = {
                target = { type = "STRING", description = "Target player name, part name, or coordinates." }
            },
            required = { "target" }
        }
    },
    {
        name = "start_remote_spy",
        description = "Activates Remote Spy to intercept and log outbound FireServer/InvokeServer network traffic.",
        parameters = {
            type = "OBJECT",
            properties = {
                filter = { type = "STRING", description = "Optional name substring to filter remotes." }
            }
        }
    },
    {
        name = "get_remote_logs",
        description = "Retrieves recent network traffic logs intercepted by Remote Spy."
    },
    {
        name = "set_noclip",
        description = "Enables or disables noclip (allowing the player character to walk through solid walls and terrain).",
        parameters = {
            type = "OBJECT",
            properties = {
                enabled = { type = "BOOLEAN", description = "true to enable noclip, false to disable." }
            },
            required = { "enabled" }
        }
    },
    {
        name = "read_file",
        description = "Reads content of a file from the executor BloxAgent workspace folder.",
        parameters = {
            type = "OBJECT",
            properties = {
                filename = { type = "STRING", description = "Name of file to read." }
            },
            required = { "filename" }
        }
    },
    {
        name = "write_file",
        description = "Writes content to a file in the executor BloxAgent workspace folder.",
        parameters = {
            type = "OBJECT",
            properties = {
                filename = { type = "STRING", description = "Name of file to write." },
                content = { type = "STRING", description = "Content to save." }
            },
            required = { "filename", "content" }
        }
    },
    {
        name = "finish",
        description = "Signals that the goal or task is fully completed and provides a final summary.",
        parameters = {
            type = "OBJECT",
            properties = {
                summary = { type = "STRING", description = "Summary of results and conclusions." }
            },
            required = { "summary" }
        }
    }
}

-- ==================== [ 6. 通信層 (Gemini WebSocket & sUNC HTTP) ] ====================
local function wsSend(sock, payload)
    if not sock then return false end
    if sock.Send then
        return pcall(function() sock:Send(payload) end)
    elseif sock.send then
        return pcall(function() sock:send(payload) end)
    end
    return false
end

local function callGeminiWebSocket(apiKey, modelName, userPrompt, targetSession, onChunk)
    local cleanModel = (modelName:gsub("^models/", ""))
    local wsUrl = string.format(
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=%s",
        apiKey
    )

    logInfo("WS", "正在嘗試建立 WebSocket 雙向串流連線至: " .. cleanModel)

    local okConn, wsOrErr = pcall(function() return wsConnect(wsUrl) end)
    if not okConn or not wsOrErr then
        local safeErr = tostring(wsOrErr or "未知錯誤"):gsub(apiKey, "REDACTED_KEY")
        logWarn("WS", "WebSocket 連線建立失敗: " .. safeErr)
        return false, "WebSocket 連線建立失敗: " .. safeErr
    end
    local ws = wsOrErr
    activeWebSocket = ws
    logInfo("WS", "WebSocket 連線物件已創建，正在進行 Bidi 協議交握...")

    local setupPayload = {
        setup = {
            model = "models/" .. cleanModel,
            generationConfig = {
                responseModalities = { "TEXT" },
                temperature = tonumber(Config.TEMPERATURE) or 0.1
            },
            systemInstruction = {
                parts = { { text = CurrentSystemPrompt } }
            }
        }
    }

    local turnsPayload = {}
    for _, item in ipairs(targetSession.history) do
        table.insert(turnsPayload, {
            role = item.role,
            parts = item.parts
        })
    end
    table.insert(turnsPayload, {
        role = "user",
        parts = { { text = userPrompt } }
    })

    local clientTurnPayload = {
        clientContent = {
            turns = turnsPayload,
            turnComplete = true
        }
    }

    local fullReply = ""
    local fullThinking = ""
    local isFinished = false
    local streamError = nil
    local receivedContent = false

    local lastActivityTime = os.clock()

    local function handleIncomingMessage(rawMsg)
        local parseOk, data = pcall(HttpService.JSONDecode, HttpService, rawMsg)
        if not parseOk or typeof(data) ~= "table" then return end

        lastActivityTime = os.clock()

        if data.setupComplete then
            logInfo("WS", "Bidi Setup 完成，發送用戶指令...")
            wsSend(ws, HttpService:JSONEncode(clientTurnPayload))
            return
        end

        if data.serverContent then
            local serverContent = data.serverContent
            if serverContent.modelTurn and serverContent.modelTurn.parts then
                for _, part in ipairs(serverContent.modelTurn.parts) do
                    if part.thought == true then
                        fullThinking = fullThinking .. (part.text or "")
                    elseif part.text then
                        receivedContent = true
                        fullReply = fullReply .. part.text
                        if onChunk then onChunk(fullReply, fullThinking) end
                    end
                end
            end

            if serverContent.turnComplete then
                logInfo("WS", "模型生成完畢 (turnComplete)")
                isFinished = true
            end
        end

        if data.error then
            streamError = string.format("API 串流錯誤 (%s): %s", tostring(data.error.code), tostring(data.error.message))
            logError("WS", streamError)
            isFinished = true
        end
    end

    local function handleClose()
        if not receivedContent and not isFinished then
            streamError = "WebSocket 連線已中斷 (可能為無效 Key、模型不支援 Bidi 或網路阻擋)"
            logWarn("WS", streamError)
        end
        isFinished = true
    end

    local function bindWsEvent(eventName, handler)
        if ws[eventName] then
            if typeof(ws[eventName].Connect) == "function" then
                pcall(function() ws[eventName]:Connect(handler) end)
                return true
            elseif typeof(ws[eventName]) == "function" then
                pcall(function() ws[eventName](ws, handler) end)
                return true
            end
        end
        return false
    end

    if not bindWsEvent("OnMessage", handleIncomingMessage) and not bindWsEvent("Message", handleIncomingMessage) then
        pcall(function() ws.OnMessage = handleIncomingMessage end)
        pcall(function() if ws.onmessage ~= nil then ws.onmessage = handleIncomingMessage end end)
    end

    if not bindWsEvent("OnClose", handleClose) and not bindWsEvent("Close", handleClose) then
        pcall(function() ws.OnClose = handleClose end)
        pcall(function() if ws.onclose ~= nil then ws.onclose = handleClose end end)
    end

    local sendOk, sendErr = wsSend(ws, HttpService:JSONEncode(setupPayload))

    if not sendOk then
        logError("WS", "握手請求發送失敗: " .. tostring(sendErr))
        pcall(function()
            if ws.Close then ws:Close()
            elseif ws.close then ws:close() end
        end)
        activeWebSocket = nil
        return false, "WebSocket 握手發送失敗: " .. tostring(sendErr)
    end

    local timeoutSec = tonumber(Config.WS_TIMEOUT) or 25
    while not isFinished do
        if os.clock() - lastActivityTime > timeoutSec then
            streamError = string.format("WebSocket 響應逾時 (%d 秒無數據，可在設定中調整)", timeoutSec)
            logWarn("WS", streamError)
            break
        end
        task.wait(0.05)
    end

    pcall(function()
        if ws.Close then ws:Close()
        elseif ws.close then ws:close() end
    end)
    activeWebSocket = nil

    if streamError or not receivedContent then
        return false, streamError or "未收到有效 WebSocket 回應"
    end

    logInfo("WS", string.format("WebSocket 通信成功 (回覆長度: %d)", #fullReply))
    return true, fullReply, fullThinking
end

local function callGeminiHTTP(apiKey, modelName, thinkLevel, userPrompt, targetSession)
    local cleanModel = (modelName:gsub("^models/", ""))
    local endpoint = string.format("https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s", cleanModel, apiKey)

    logInfo("HTTP", "正在發起 sUNC HTTP 請求至: " .. cleanModel)

    local contents = {}
    for _, item in ipairs(targetSession.history) do
        table.insert(contents, {
            role = item.role,
            parts = item.parts
        })
    end
    if userPrompt and #userPrompt > 0 then
        table.insert(contents, {
            role = "user",
            parts = { { text = userPrompt } }
        })
    end

    local genConfig = {
        temperature = tonumber(Config.TEMPERATURE) or 0.1,
        maxOutputTokens = tonumber(Config.MAX_OUTPUT_TOKENS) or 8192
    }
    if thinkLevel and thinkLevel ~= "Off" then
        local budget = 0
        if thinkLevel == "Low" then budget = 1024
        elseif thinkLevel == "Medium" then budget = 4096
        elseif thinkLevel == "High" then budget = 8192
        end
        if budget > 0 then
            genConfig.thinkingConfig = { thinkingBudget = budget }
        end
    elseif thinkLevel == "Off" then
        genConfig.thinkingConfig = { thinkingBudget = 0 }
    end

    local payload = {
        systemInstruction = { parts = { { text = CurrentSystemPrompt } } },
        contents = contents,
        generationConfig = genConfig
    }

    local encodedBody = safeJSONEncode(payload)
    if not encodedBody then
        return false, "請求 Payload JSON 編碼失敗", "", {}, {}
    end

    local headers = {
        ["Content-Type"] = "application/json",
        ["x-goog-api-key"] = apiKey
    }

    local reqOk, response, reqErr
    for attempt = 1, 2 do
        reqOk, response, reqErr = universalHttpRequest(endpoint, "POST", headers, encodedBody)
        if reqOk and response then
            local code = response.StatusCode
            if code == 503 or code == 429 then
                if attempt == 1 then
                    logWarn("HTTP", string.format("伺服器回傳狀態碼 %d (高負載/忙碌)，自動於 1.5 秒後進行重試...", code))
                    task.wait(1.5)
                end
            else
                break
            end
        else
            break
        end
    end

    if not reqOk or not response then
        local errMsg = sanitizeSecret("sUNC 網路請求異常: " .. tostring(reqErr or "未知錯誤"))
        logError("HTTP", errMsg)
        return false, errMsg, "", {}, {}
    end

    local statusCode = response.StatusCode
    local body = response.Body

    logInfo("HTTP", string.format("HTTP 伺服器響應狀態碼: %s", tostring(statusCode or "無")))

    if statusCode ~= 200 then
        local detailedMsg = ""
        if body and #body > 0 then
            local errJson = safeJSONDecode(body)
            if errJson and errJson.error then
                detailedMsg = string.format(" [%s: %s]", tostring(errJson.error.status or errJson.error.code), tostring(errJson.error.message))
            else
                detailedMsg = " [" .. (body:sub(1, 160)) .. "]"
            end
        end

        local friendlyHint = ""
        if statusCode == 503 then
            friendlyHint = "\n💡 提示：此模型當前伺服器流量過載，通常為暫時性，請稍後再試，或更換模型。"
        elseif statusCode == 404 then
            friendlyHint = "\n💡 提示：模型不存在或此 API 版本不支援，請確認模型名稱。"
        elseif statusCode == 401 or statusCode == 403 then
            friendlyHint = "\n💡 提示：API Key 無效或權限不足，請檢查金鑰。"
        end

        local finalErrMsg = sanitizeSecret(string.format("HTTP 請求失敗 (狀態碼 %s)%s%s", tostring(statusCode or "中斷"), detailedMsg, friendlyHint))
        logError("HTTP", finalErrMsg)
        return false, finalErrMsg, "", {}, {}
    end

    local data = safeJSONDecode(body)
    if not data or typeof(data) ~= "table" then
        local parseErrMsg = sanitizeSecret("JSON 解析失敗: " .. tostring(body):sub(1, 100))
        logError("HTTP", parseErrMsg)
        return false, "伺服器返回非有效 JSON 格式", "", {}, {}
    end

    local replyText = ""
    local thoughtText = ""
    local functionCalls = {}
    local rawParts = {}

    if data.candidates and data.candidates[1] and data.candidates[1].content and data.candidates[1].content.parts then
        rawParts = data.candidates[1].content.parts
        for _, part in ipairs(data.candidates[1].content.parts) do
            if part.thought == true then
                thoughtText = thoughtText .. (part.text or "")
            elseif part.text then
                replyText = replyText .. (part.text or "")
            end
            if part.functionCall then
                table.insert(functionCalls, part.functionCall)
            end
        end
    end

    if replyText == "" and thoughtText == "" and #functionCalls == 0 then
        logWarn("HTTP", "API 未回傳文本或工具調用內容")
        return false, "API 未回傳有效內容 (可能觸發安全過濾或 Token 超限)", "", {}, {}
    end

    logInfo("HTTP", string.format("HTTP 通信成功 (回覆長度: %d, 思考長度: %d, 工具調用: %d)", #replyText, #thoughtText, #functionCalls))
    return true, replyText, thoughtText, functionCalls, rawParts
end

-- ==================== [ 6.5 上下文治理與自動壓縮引擎 (Auto-Compaction) ] ====================
local function compactSessionHistory(targetSession, apiKey, modelName)
    if not targetSession or not targetSession.history or #targetSession.history < 4 then
        return false
    end

    logInfo("Compact", "觸發上下文自動壓縮 (Auto-Compaction)...")
    if AgentLoopStatusBadge then
        AgentLoopStatusBadge.Text = "🔄 上下文治理壓縮中..."
        AgentLoopStatusBadge.TextColor3 = Color3.fromRGB(255, 200, 100)
    end

    -- 提取需要被壓縮的舊歷史文本
    local transcriptLines = {}
    for idx, item in ipairs(targetSession.history) do
        local r = item.role or "unknown"
        for _, p in ipairs(item.parts or {}) do
            if p.text then
                table.insert(transcriptLines, string.format("[%s]: %s", r, p.text:sub(1, 600)))
            end
        end
    end
    local transcript = table.concat(transcriptLines, "\n\n")

    local compactPrompt = [===[請將以下 Agent 與使用者的執行歷史進行語意壓縮（Compaction），提煉出結構化的「已驗證環境狀態事實與已完成進度摘要」：
1. 已確認的遊戲實例全路徑、物件名稱與關鍵屬性。
2. 已驗證有效的 Remote 協議、引數結構或功能狀態。
3. 當前已完成的工作步驟，以及待解決的目標。
4. 去除冗長的除錯代碼、無效的 Traceback 與過時終端日誌。
請直接以簡明、條列式的繁體中文 Markdown 輸出摘要事實，不需冗餘問候。]===]

    local cleanModel = (modelName:gsub("^models/", ""))
    local endpoint = string.format("https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s", cleanModel, apiKey)
    local payload = {
        contents = {
            {
                role = "user",
                parts = {
                    { text = compactPrompt .. "\n\n=== 執行歷史紀錄 ===\n" .. transcript }
                }
            }
        },
        generationConfig = {
            temperature = 0.1,
            maxOutputTokens = 2048
        }
    }
    local encodedBody = safeJSONEncode(payload)
    if not encodedBody then return false end

    local headers = {
        ["Content-Type"] = "application/json",
        ["x-goog-api-key"] = apiKey
    }

    local reqOk, response = universalHttpRequest(endpoint, "POST", headers, encodedBody)
    if reqOk and response and response.StatusCode == 200 then
        local data = safeJSONDecode(response.Body)
        local summaryText = ""
        if data and data.candidates and data.candidates[1] and data.candidates[1].content and data.candidates[1].content.parts then
            for _, pt in ipairs(data.candidates[1].content.parts) do
                if pt.text then summaryText = summaryText .. pt.text end
            end
        end

        if #summaryText > 0 then
            -- 保留最近 1 輪對話
            local recentHistory = {}
            if #targetSession.history >= 2 then
                table.insert(recentHistory, targetSession.history[#targetSession.history - 1])
                table.insert(recentHistory, targetSession.history[#targetSession.history])
            end

            targetSession.history = {
                {
                    role = "user",
                    parts = { { text = "[系統記憶壓縮 / Context Compaction State]\n以下為先前執行步驟所提煉之環境已知狀態與進度摘要：\n" .. summaryText } }
                },
                {
                    role = "model",
                    parts = { { text = "已同步當前環境狀態事實摘要，已重置對話歷史以防注意力衰退，準備繼續執行下一步。" } }
                }
            }
            for _, rh in ipairs(recentHistory) do
                table.insert(targetSession.history, rh)
            end

            table.insert(targetSession.messages, {
                role = "assistant",
                text = "🔄 **[上下文治理]** 歷史對話已自動完成語意壓縮（Auto-Compacted），提煉關鍵環境狀態事實並重置冗餘上下文，有效杜絕注意力衰退 (Context Rot)。",
                time = os.date("%H:%M:%S")
            })
            if renderActiveSessionChat then renderActiveSessionChat() end
            if saveSessionsToWorkspace then saveSessionsToWorkspace() end
            logInfo("Compact", "上下文壓縮完成！")
            return true
        end
    end
    return false
end

-- ==================== [ 7. 高特權 CodeAct 運行時與雙軌看門狗 (Execution Harness) ] ====================
local isBusy = false
local currentExecutionId = 0
local currentMainThread = nil
local currentCodeThread = nil

-- ACI (Agent-Computer Interface) 輸出規範常數
local ACI_MAX_LOG_LINES = 100
local ACI_MAX_LOG_CHARS = 4000

local function checkDangerousLoops(code)
    if not code or typeof(code) ~= "string" then return true end
    local hasWhileTrue = code:find("while%s+true%s+do") or code:find("while%s+1%s+do")
    local hasRepeatFalse = code:find("repeat.-until%s+false")
    if (hasWhileTrue or hasRepeatFalse) then
        local hasYield = code:find("wait", 1, true) or code:find("Heartbeat", 1, true) or code:find("Stepped", 1, true) or code:find("heartbeat", 1, true) or code:find("RenderStepped", 1, true)
        if not hasYield then
            return false, "靜態安全攔截：檢測到無讓步死循環 (while/repeat 區塊內未發現 task.wait 或 RunService 讓步)，為避免遊戲凍結已阻止執行。"
        end
    end
    return true, nil
end

local function executeCodeAct(luaCode)
    local capturedLogs = {}
    local totalChars = 0
    local logTruncated = false

    local function addLog(str)
        if #capturedLogs >= ACI_MAX_LOG_LINES or totalChars >= ACI_MAX_LOG_CHARS then
            if not logTruncated then
                logTruncated = true
                table.insert(capturedLogs, string.format("[⚠️ 終端輸出已達 ACI 上限截斷 (僅展示前 %d 行)。若需檢視更多請於代碼中縮小查詢範圍或使用分頁/切片]", #capturedLogs))
            end
            return
        end
        totalChars = totalChars + #str
        table.insert(capturedLogs, str)
        logInfo("AgentPrint", str)
    end

    local safeLoop, loopErr = checkDangerousLoops(luaCode)
    if not safeLoop then
        return false, loopErr, capturedLogs
    end

    local func, compileErr
    local prependedCode = "local print, warn, AgentEnv = ...; " .. luaCode
    local okLoad, loadRes, loadErr = pcall(loadstring, prependedCode)
    if not okLoad or type(loadRes) ~= "function" then
        -- 容錯備援：若注入語法在特定環境失敗，回退至原生 loadstring
        okLoad, loadRes, loadErr = pcall(loadstring, luaCode)
    end
    if okLoad and type(loadRes) == "function" then
        func = loadRes
    else
        compileErr = tostring(loadErr or loadRes or "語法解析失敗")
        return false, "代碼編譯失敗: " .. compileErr, capturedLogs
    end

    -- 高特權透明環境：不設限沙盒隔離，允許無障礙調用 UNC 與真實全域環境
    local baseEnv = (getgenv and getgenv()) or getfenv(0) or _G
    local execEnv = {}

    -- 包裝 print 與 warn 以進行 ACI 輸出捕獲與防洪截斷
    execEnv.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            local v = select(i, ...)
            parts[i] = typeof(v) == "table" and (safeJSONEncode(sanitizeForJSON(v)) or tostring(v)) or tostring(v)
        end
        addLog(table.concat(parts, " "))
    end

    execEnv.warn = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            local v = select(i, ...)
            parts[i] = typeof(v) == "table" and (safeJSONEncode(sanitizeForJSON(v)) or tostring(v)) or tostring(v)
        end
        addLog("[Warn] " .. table.concat(parts, " "))
    end

    -- 包裝 task.wait 與 wait，在讓步時自動刷新看門狗心跳時間戳記
    local wrappedTask = table.clone(task)
    local origTaskWait = task.wait
    wrappedTask.wait = function(...)
        lastWatchdogHeartbeat = os.clock()
        return origTaskWait(...)
    end
    execEnv.task = wrappedTask
    execEnv.wait = function(...)
        lastWatchdogHeartbeat = os.clock()
        return task.wait(...)
    end

    execEnv.AgentEnv = AgentEnv
    execEnv.script = nil

    setmetatable(execEnv, {
        __index = function(_, k)
            if k == "script" then return nil end
            local v = baseEnv[k]
            if v == nil and getfenv then
                v = getfenv(0)[k]
            end
            return v
        end,
        __newindex = function(_, k, v)
            -- 腳本中定義或賦值的全域變數直接作用於真實環境，支援逆向腳本互動
            if baseEnv then
                baseEnv[k] = v
            end
        end
    })

    pcall(setfenv, func, execEnv)

    local runOk, runErr = false, ""
    local finished = false
    local returnedValues = {}
    lastWatchdogHeartbeat = os.clock()

    -- 啟動語言虛擬機級別的動態指令計數鉤子 (若執行器支援 debug.sethook)
    local hasSetHook = false
    if debug and type(debug.sethook) == "function" then
        pcall(function()
            debug.sethook(function()
                debug.sethook()
                error("[Watchdog Security] 執行指令突破配額 (10^7 指令)，判定為嚴密無讓步死循環強制中止")
            end, "", 10000)
            hasSetHook = true
        end)
    end

    -- 暫時重定向全域 getgenv().print 與 warn，確保非同步與間接調用亦能被 ACI 捕獲
    local origGenPrint = (getgenv and getgenv().print)
    local origGenWarn = (getgenv and getgenv().warn)
    if getgenv then
        getgenv().print = execEnv.print
        getgenv().warn = execEnv.warn
    end

    currentCodeThread = task.spawn(function()
        runOk, runErr = xpcall(function()
            returnedValues = { func(execEnv.print, execEnv.warn, AgentEnv) }
        end, function(err)
            local tb = debug.traceback(tostring(err), 2)
            -- ACI Traceback 去噪：過濾 Harness 內部框架包裝行，精確定位模型程式碼
            local cleanLines = {}
            for line in tostring(tb):gmatch("[^\r\n]+") do
                if not line:find("executeCodeAct") and not line:find("xpcall") then
                    table.insert(cleanLines, line)
                end
            end
            return table.concat(cleanLines, "\n")
        end)
        finished = true
    end)

    local TIMEOUT = tonumber(Config.WATCHDOG_TIMEOUT) or 20
    while not finished do
        if os.clock() - lastWatchdogHeartbeat > TIMEOUT then
            if currentCodeThread then
                pcall(task.cancel, currentCodeThread)
                currentCodeThread = nil
            end
            runOk = false
            runErr = string.format("代碼無響應超過 %d 秒 (非同步看門狗搶佔式中斷，可在設定中調整)", TIMEOUT)
            logWarn("Watchdog", runErr)
            break
        end
        task.wait(0.05)
    end

    if hasSetHook and debug and debug.sethook then
        pcall(debug.sethook)
    end

    -- 還原全域 print 與 warn
    if getgenv then
        getgenv().print = origGenPrint
        getgenv().warn = origGenWarn
    end

    -- 若腳本存在 return 且無 print，將返回值作為輸出觀測捕獲
    if runOk and #capturedLogs == 0 and #returnedValues > 0 then
        local retStrs = {}
        for i = 1, #returnedValues do
            local v = returnedValues[i]
            retStrs[i] = typeof(v) == "table" and (safeJSONEncode(sanitizeForJSON(v)) or tostring(v)) or tostring(v)
        end
        addLog("[Return] " .. table.concat(retStrs, ", "))
    end

    -- 終端日誌保底：若完全無輸出亦非報錯，標註執行狀態避免日誌為空
    if runOk and #capturedLogs == 0 then
        table.insert(capturedLogs, "(代碼執行完成，無 print 輸出與返回值)")
    end

    currentCodeThread = nil
    return runOk, runErr, capturedLogs
end

-- 向下相容別名
local executeInSandbox = executeCodeAct

-- ==================== [ 7.1 Agent 工具分發器 (ReAct Tool Dispatcher) ] ====================
local function dispatchAgentTool(toolName, args)
    args = args or {}
    logInfo("ToolDispatch", "調用工具: " .. tostring(toolName))

    if toolName == "execute_luau" then
        local code = args.code or ""
        local runOk, runErr, logs = executeInSandbox(code)
        local outStr = table.concat(logs, "\n")
        if not runOk then
            return {
                status = "error",
                error = tostring(runErr),
                logs = logs,
                output = string.format("代碼執行報錯: %s\n日誌:\n%s", tostring(runErr), outStr)
            }
        else
            return {
                status = "success",
                logs = logs,
                output = string.format("代碼執行成功。\n日誌:\n%s", (#outStr > 0 and outStr or "(無 print 輸出)"))
            }
        end

    elseif toolName == "find_instances" then
        local rootInst = workspace
        if args.root and args.root ~= "" then
            rootInst = resolveInstanceByPath(args.root) or (pcall(function() return game:GetService(args.root) end) and game:GetService(args.root)) or workspace
        end
        local matches = AgentEnv.findInstances(args.queryName, args.className, rootInst)
        return {
            status = "success",
            matches = matches,
            output = string.format("找到 %d 個符合條件的實例:\n%s", #matches, (#matches > 0 and table.concat(matches, "\n") or "無匹配實例"))
        }

    elseif toolName == "inspect_instance" then
        local inst = resolveInstanceByPath(args.path)
        if not inst then
            return {
                status = "error",
                output = string.format("未在 DataModel 中找到路徑指定的實例: %s", tostring(args.path))
            }
        end
        local info, err = AgentEnv.inspectInstance(inst)
        if not info then
            return { status = "error", output = tostring(err) }
        end
        return {
            status = "success",
            data = info,
            output = safeJSONEncode(info) or "檢視完成"
        }

    elseif toolName == "teleport" then
        local target = args.target
        local ok, msg = AgentEnv.teleport(target)
        return {
            status = ok and "success" or "error",
            output = tostring(msg)
        }

    elseif toolName == "walk_to" then
        local target = args.target
        local ok, msg = AgentEnv.walkTo(target)
        return {
            status = ok and "success" or "error",
            output = tostring(msg)
        }

    elseif toolName == "start_remote_spy" then
        local ok, msg = AgentEnv.startRemoteSpy({ filter = args.filter })
        return {
            status = ok and "success" or "error",
            output = tostring(msg)
        }

    elseif toolName == "get_remote_logs" then
        local rawLogs = sanitizeForJSON(AgentEnv.RemoteLogs)
        local formattedLogs = {}
        for _, logItem in ipairs(rawLogs) do
            if typeof(logItem) == "table" then
                local str = string.format("[%s] %s:%s(%s)", tostring(logItem.time or ""), tostring(logItem.remote or logItem.name or ""), tostring(logItem.method or ""), safeJSONEncode(logItem.args) or "")
                table.insert(formattedLogs, str)
            else
                table.insert(formattedLogs, tostring(logItem))
            end
        end
        return {
            status = "success",
            logs = formattedLogs,
            output = string.format("當前獲取到 %d 條攔截日誌:\n%s", #AgentEnv.RemoteLogs, #formattedLogs > 0 and table.concat(formattedLogs, "\n") or "(無攔截日誌)")
        }

    elseif toolName == "set_noclip" then
        local state = args.enabled == true
        AgentEnv.setNoclip(state)
        return {
            status = "success",
            output = string.format("穿牆模式 (Noclip) 已設為: %s", state and "開啟" or "關閉")
        }

    elseif toolName == "read_file" then
        local fn = args.filename or ""
        local cleanFn = fn:gsub("%.%.", ""):gsub("[\\/]", ""):lower()
        if cleanFn == "gemini_key.txt" or cleanFn == "settings.json" or cleanFn == "system_prompt.txt" or cleanFn == "sessions.json" then
            return { status = "error", output = "安全原則阻擋: 禁止存取系統保護設定檔案 (" .. cleanFn .. ")" }
        end
        local filePath = FOLDER_NAME .. "/" .. cleanFn
        local ok, content = safeReadFile(filePath)
        if ok and content then
            return { status = "success", content = content, output = content }
        else
            return { status = "error", output = "檔案不存在或無法讀取: " .. filePath }
        end

    elseif toolName == "write_file" then
        local fn = args.filename or ""
        local cleanFn = fn:gsub("%.%.", ""):gsub("[\\/]", ""):lower()
        if cleanFn == "gemini_key.txt" or cleanFn == "settings.json" or cleanFn == "system_prompt.txt" or cleanFn == "sessions.json" then
            return { status = "error", output = "安全原則阻擋: 禁止竄改系統保護設定檔案 (" .. cleanFn .. ")" }
        end
        local filePath = FOLDER_NAME .. "/" .. cleanFn
        local content = args.content or ""
        ensureWorkspaceFolder()
        local ok = safeWriteFile(filePath, content)
        return {
            status = ok and "success" or "error",
            output = ok and ("成功寫入檔案: " .. filePath) or ("寫入檔案失敗: " .. filePath)
        }

    elseif toolName == "finish" then
        return {
            status = "finished",
            summary = args.summary or "",
            output = string.format("任務已圓滿完成！總結: %s", tostring(args.summary or ""))
        }

    else
        return {
            status = "error",
            output = "未知的工具調用名稱: " .. tostring(toolName)
        }
    end
end

-- ==================== [ 8. BloxAgent 2.0 UI 架構 ] ====================
local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "BloxAgent_Framework"
ScreenGui.ResetOnSpawn = false
ScreenGui.Parent = guiParent

local FloatButton = Instance.new("TextButton")
FloatButton.Name = "FloatToggle"
FloatButton.Size = UDim2.new(0, 44, 0, 44)
FloatButton.Position = UDim2.new(0.04, 0, 0.22, 0)
FloatButton.BackgroundColor3 = Color3.fromRGB(32, 34, 46)
FloatButton.Text = "🤖"
FloatButton.TextSize = 22
FloatButton.Active = true
FloatButton.Visible = isMobile -- 電腦端預設隱藏，使用快捷鍵呼出！
FloatButton.Parent = ScreenGui
Instance.new("UICorner", FloatButton).CornerRadius = UDim.new(1, 0)
local floatStroke = Instance.new("UIStroke", FloatButton)
floatStroke.Color = Color3.fromRGB(80, 120, 240)
floatStroke.Thickness = 1.5

local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(0, 420, 0, 480)
MainFrame.Position = UDim2.new(0.5, -210, 0.12, 0)
MainFrame.BackgroundColor3 = Color3.fromRGB(18, 19, 26)
MainFrame.BackgroundTransparency = Config.GUI_TRANSPARENCY or 0.05
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Visible = true
MainFrame.Parent = ScreenGui
Instance.new("UICorner", MainFrame).CornerRadius = UDim.new(0, 12)
local mainStroke = Instance.new("UIStroke", MainFrame)
mainStroke.Color = Color3.fromRGB(45, 48, 65)
mainStroke.Thickness = 1.2
local mainUIScale = Instance.new("UIScale", MainFrame)
mainUIScale.Scale = tonumber(Config.GUI_SCALE) or 1.0

-- 移動端懸浮球單擊即時開關 (無需連點兩次)
local function setupMobileFloatToggle(btn, onToggle)
    local touchStartPos = nil
    local touchStartTime = 0
    local startBtnPos = nil
    local dragInput = nil

    btn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            touchStartPos = input.Position
            touchStartTime = os.clock()
            startBtnPos = btn.Position

            local conn
            conn = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    if conn then conn:Disconnect(); conn = nil end
                    local dt = os.clock() - touchStartTime
                    local dist = (input.Position - touchStartPos).Magnitude
                    if dist < 12 and dt < 0.6 then
                        onToggle()
                    end
                end
            end)
        end
    end)

    btn.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseMovement then
            dragInput = input
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and touchStartPos then
            local delta = input.Position - touchStartPos
            if delta.Magnitude > 12 then
                btn.Position = UDim2.new(startBtnPos.X.Scale, startBtnPos.X.Offset + delta.X, startBtnPos.Y.Scale, startBtnPos.Y.Offset + delta.Y)
            end
        end
    end)
end

setupMobileFloatToggle(FloatButton, function()
    MainFrame.Visible = not MainFrame.Visible
end)

-- PC 端自訂快捷鍵監聽呼出
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    local targetKey = Config.PC_TOGGLE_KEY or "RightControl"
    local targetEnum = Enum.KeyCode[targetKey] or Enum.KeyCode.RightControl
    if input.KeyCode == targetEnum then
        MainFrame.Visible = not MainFrame.Visible
    end
end)

logInfo("Core", string.format("BloxAgent 2.0 已就緒！設備: %s | PC 呼出鍵: [%s]", isMobile and "移動端 (懸浮球)" or "PC (鍵盤快捷鍵)", Config.PC_TOGGLE_KEY or "RightControl"))

-- 視窗拖拽功能
local function enableFrameDrag(dragHandle, frame)
    local dragging = false
    local dragInput, dragStart, startPos

    dragHandle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position

            local conn
            conn = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    if conn then conn:Disconnect(); conn = nil end
                end
            end)
        end
    end)

    dragHandle.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragging then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

-- ==================== [ 9. 頂部導航列 (Top Header Bar) ] ====================
local Header = Instance.new("Frame")
Header.Size = UDim2.new(1, 0, 0, 38)
Header.BackgroundColor3 = Color3.fromRGB(24, 25, 34)
Header.BorderSizePixel = 0
Header.Parent = MainFrame
Instance.new("UICorner", Header).CornerRadius = UDim.new(0, 12)
enableFrameDrag(Header, MainFrame)

local SessionDrawerBtn = Instance.new("TextButton")
SessionDrawerBtn.Size = UDim2.new(0, 68, 0, 26)
SessionDrawerBtn.Position = UDim2.new(0, 8, 0, 6)
SessionDrawerBtn.BackgroundColor3 = Color3.fromRGB(36, 40, 54)
SessionDrawerBtn.Text = "會話"
SessionDrawerBtn.Font = Enum.Font.GothamBold
SessionDrawerBtn.TextSize = 11
SessionDrawerBtn.TextColor3 = Color3.fromRGB(200, 220, 255)
SessionDrawerBtn.Parent = Header
Instance.new("UICorner", SessionDrawerBtn).CornerRadius = UDim.new(0, 6)

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Size = UDim2.new(0.4, 0, 1, 0)
TitleLabel.Position = UDim2.new(0, 84, 0, 0)
TitleLabel.BackgroundTransparency = 1
TitleLabel.Text = "BloxAgent 2.0"
TitleLabel.Font = Enum.Font.GothamBold
TitleLabel.TextSize = 13
TitleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Parent = Header

local ModelBadge = Instance.new("TextLabel")
ModelBadge.Size = UDim2.new(0.3, 0, 1, 0)
ModelBadge.Position = UDim2.new(0, 185, 0, 0)
ModelBadge.BackgroundTransparency = 1
ModelBadge.Text = "[" .. tostring(Config.MODEL) .. "]"
ModelBadge.Font = Enum.Font.Code
ModelBadge.TextSize = 10
ModelBadge.TextColor3 = Color3.fromRGB(120, 220, 255)
ModelBadge.TextXAlignment = Enum.TextXAlignment.Left
ModelBadge.Parent = Header

local SettingsBtn = Instance.new("TextButton")
SettingsBtn.Size = UDim2.new(0, 28, 0, 26)
SettingsBtn.Position = UDim2.new(1, -66, 0, 6)
SettingsBtn.BackgroundColor3 = Color3.fromRGB(36, 40, 54)
SettingsBtn.Text = "⚙️"
SettingsBtn.Font = Enum.Font.GothamBold
SettingsBtn.TextSize = 13
SettingsBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
SettingsBtn.Parent = Header
Instance.new("UICorner", SettingsBtn).CornerRadius = UDim.new(0, 6)

local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(0, 28, 0, 26)
CloseBtn.Position = UDim2.new(1, -34, 0, 6)
CloseBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
CloseBtn.Text = "✕"
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.TextSize = 12
CloseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
CloseBtn.Parent = Header
Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(0, 6)
CloseBtn.MouseButton1Click:Connect(function()
    MainFrame.Visible = false
end)

-- ==================== [ 10. 對話串流視圖 (Unified Chat Stream) ] ====================
local ChatScroll = Instance.new("ScrollingFrame")
ChatScroll.Size = UDim2.new(1, -16, 1, -125)
ChatScroll.Position = UDim2.new(0, 8, 0, 44)
ChatScroll.BackgroundColor3 = Color3.fromRGB(14, 15, 20)
ChatScroll.BorderSizePixel = 0
ChatScroll.ScrollBarThickness = 4
ChatScroll.ScrollBarImageColor3 = Color3.fromRGB(80, 85, 110)
ChatScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
ChatScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
ChatScroll.ElasticBehavior = Enum.ElasticBehavior.Always
ChatScroll.Parent = MainFrame
Instance.new("UICorner", ChatScroll).CornerRadius = UDim.new(0, 8)

local ChatLayout = Instance.new("UIListLayout")
ChatLayout.SortOrder = Enum.SortOrder.LayoutOrder
ChatLayout.Padding = UDim.new(0, 8)
ChatLayout.Parent = ChatScroll

local function scrollToBottom()
    task.defer(function()
        ChatScroll.CanvasPosition = Vector2.new(0, 999999)
    end)
end

-- ==================== [ 11. 卡片構建器 (Message Cards Builder) ] ====================
local function buildUserCard(msg)
    local card = Instance.new("Frame")
    card.Size = UDim2.new(1, 0, 0, 0)
    card.AutomaticSize = Enum.AutomaticSize.Y
    card.BackgroundColor3 = Color3.fromRGB(26, 38, 58)
    card.BorderSizePixel = 0
    Instance.new("UICorner", card).CornerRadius = UDim.new(0, 8)

    local header = Instance.new("TextLabel")
    header.Size = UDim2.new(1, -16, 0, 20)
    header.Position = UDim2.new(0, 8, 0, 4)
    header.BackgroundTransparency = 1
    header.Text = string.format("👤 你 (User) • %s", msg.time or os.date("%H:%M:%S"))
    header.Font = Enum.Font.GothamBold
    header.TextSize = 11
    header.TextColor3 = Color3.fromRGB(140, 200, 255)
    header.TextXAlignment = Enum.TextXAlignment.Left
    header.Parent = card

    local body = Instance.new("TextLabel")
    body.Size = UDim2.new(1, -16, 0, 0)
    body.Position = UDim2.new(0, 8, 0, 24)
    body.AutomaticSize = Enum.AutomaticSize.Y
    body.BackgroundTransparency = 1
    body.Text = msg.text or ""
    body.Font = Enum.Font.Gotham
    body.TextSize = 12
    body.TextColor3 = Color3.fromRGB(240, 240, 245)
    body.TextWrapped = true
    body.TextXAlignment = Enum.TextXAlignment.Left
    body.Parent = card

    local pad = Instance.new("UIPadding", card)
    pad.PaddingBottom = UDim.new(0, 8)

    return card
end

local executeCodeAction -- forward declaration

local function buildAgentCard(msg)
    local card = Instance.new("Frame")
    card.Size = UDim2.new(1, 0, 0, 0)
    card.AutomaticSize = Enum.AutomaticSize.Y
    card.BackgroundColor3 = Color3.fromRGB(24, 25, 33)
    card.BorderSizePixel = 0
    Instance.new("UICorner", card).CornerRadius = UDim.new(0, 8)

    local cardLayout = Instance.new("UIListLayout", card)
    cardLayout.SortOrder = Enum.SortOrder.LayoutOrder
    cardLayout.Padding = UDim.new(0, 6)

    local pad = Instance.new("UIPadding", card)
    pad.PaddingTop = UDim.new(0, 6)
    pad.PaddingBottom = UDim.new(0, 8)
    pad.PaddingLeft = UDim.new(0, 8)
    pad.PaddingRight = UDim.new(0, 8)

    -- 1. 卡片頂部徽章
    local headerFrame = Instance.new("Frame")
    headerFrame.Size = UDim2.new(1, 0, 0, 20)
    headerFrame.BackgroundTransparency = 1
    headerFrame.LayoutOrder = 1
    headerFrame.Parent = card

    local titleLabel = Instance.new("TextLabel")
    titleLabel.Size = UDim2.new(0.6, 0, 1, 0)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text = string.format("🤖 BloxAgent • %s", msg.time or os.date("%H:%M:%S"))
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.TextSize = 11
    titleLabel.TextColor3 = Color3.fromRGB(150, 255, 180)
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.Parent = headerFrame

    local statusBadge = Instance.new("TextLabel")
    statusBadge.Size = UDim2.new(0.4, 0, 1, 0)
    statusBadge.Position = UDim2.new(0.6, 0, 0, 0)
    statusBadge.BackgroundTransparency = 1
    statusBadge.Font = Enum.Font.GothamMedium
    statusBadge.TextSize = 10
    statusBadge.TextXAlignment = Enum.TextXAlignment.Right
    statusBadge.Parent = headerFrame

    if msg.status == "generating" then
        statusBadge.Text = "推理中..."
        statusBadge.TextColor3 = Color3.fromRGB(255, 215, 0)
    elseif msg.status == "running" then
        statusBadge.Text = "⚡ 執行中..."
        statusBadge.TextColor3 = Color3.fromRGB(100, 200, 255)
    elseif msg.status == "waiting_approval" then
        statusBadge.Text = "⏳ 審批待命"
        statusBadge.TextColor3 = Color3.fromRGB(255, 180, 50)
    elseif msg.status == "success" or msg.status == "finished" then
        statusBadge.Text = "✅ 完成"
        statusBadge.TextColor3 = Color3.fromRGB(100, 255, 120)
    elseif msg.status == "error" then
        statusBadge.Text = "❌ 報錯 (Reflexion)"
        statusBadge.TextColor3 = Color3.fromRGB(255, 100, 100)
    else
        statusBadge.Text = ""
    end

    -- 2. 可點擊展開/收合的思考鏈摺疊塊 (Thinking Accordion)
    local thinkBody = nil
    if msg.thinking and #msg.thinking > 0 then
        local thinkHeader = Instance.new("TextButton")
        thinkHeader.Size = UDim2.new(1, 0, 0, 24)
        thinkHeader.BackgroundColor3 = Color3.fromRGB(34, 28, 48)
        thinkHeader.Text = string.format("  ▶ 思考鏈 (%d 字) [點擊展開]", #msg.thinking)
        thinkHeader.Font = Enum.Font.GothamMedium
        thinkHeader.TextSize = 11
        thinkHeader.TextColor3 = Color3.fromRGB(190, 165, 255)
        thinkHeader.TextXAlignment = Enum.TextXAlignment.Left
        thinkHeader.LayoutOrder = 2
        Instance.new("UICorner", thinkHeader).CornerRadius = UDim.new(0, 4)
        thinkHeader.Parent = card

        thinkBody = Instance.new("Frame")
        thinkBody.Size = UDim2.new(1, 0, 0, 0)
        thinkBody.AutomaticSize = Enum.AutomaticSize.Y
        thinkBody.BackgroundColor3 = Color3.fromRGB(20, 16, 30)
        thinkBody.Visible = false -- 預設收合！
        thinkBody.LayoutOrder = 3
        Instance.new("UICorner", thinkBody).CornerRadius = UDim.new(0, 4)
        thinkBody.Parent = card

        local thinkText = Instance.new("TextLabel")
        thinkText.Size = UDim2.new(1, -12, 0, 0)
        thinkText.Position = UDim2.new(0, 6, 0, 6)
        thinkText.AutomaticSize = Enum.AutomaticSize.Y
        thinkText.BackgroundTransparency = 1
        thinkText.Text = msg.thinking
        thinkText.Font = Enum.Font.Code
        thinkText.TextSize = 10
        thinkText.TextColor3 = Color3.fromRGB(200, 185, 245)
        thinkText.TextWrapped = true
        thinkText.TextXAlignment = Enum.TextXAlignment.Left
        thinkText.Parent = thinkBody
        local tPad = Instance.new("UIPadding", thinkBody)
        tPad.PaddingBottom = UDim.new(0, 8)

        local isExpanded = false
        thinkHeader.MouseButton1Click:Connect(function()
            isExpanded = not isExpanded
            thinkBody.Visible = isExpanded
            thinkHeader.Text = isExpanded
                and string.format("  ▼ 思考鏈 (%d 字) [點擊收起]", #msg.thinking)
                or string.format("  ▶ 思考鏈 (%d 字) [點擊展開]", #msg.thinking)
            scrollToBottom()
        end)
    end

    -- 3. 文本回覆 (Explanation text)
    local textLabel = nil
    if msg.text and #msg.text > 0 then
        textLabel = Instance.new("TextLabel")
        textLabel.Size = UDim2.new(1, 0, 0, 0)
        textLabel.AutomaticSize = Enum.AutomaticSize.Y
        textLabel.BackgroundTransparency = 1
        textLabel.Text = msg.text
        textLabel.Font = Enum.Font.Gotham
        textLabel.TextSize = 12
        textLabel.TextColor3 = Color3.fromRGB(235, 235, 240)
        textLabel.TextWrapped = true
        textLabel.TextXAlignment = Enum.TextXAlignment.Left
        textLabel.LayoutOrder = 4
        textLabel.Parent = card
    end

    -- 3.5 工具調用與觀測展示 (Tool Invocation & Observation Badge)
    if msg.toolName then
        local toolCard = Instance.new("Frame")
        toolCard.Size = UDim2.new(1, 0, 0, 0)
        toolCard.AutomaticSize = Enum.AutomaticSize.Y
        toolCard.BackgroundColor3 = Color3.fromRGB(16, 18, 25)
        toolCard.LayoutOrder = 4.5
        Instance.new("UICorner", toolCard).CornerRadius = UDim.new(0, 6)
        toolCard.Parent = card

        local tcHeader = Instance.new("Frame")
        tcHeader.Size = UDim2.new(1, 0, 0, 24)
        tcHeader.BackgroundColor3 = Color3.fromRGB(22, 25, 36)
        tcHeader.BorderSizePixel = 0
        Instance.new("UICorner", tcHeader).CornerRadius = UDim.new(0, 6)
        tcHeader.Parent = toolCard

        local tcTitle = Instance.new("TextLabel")
        tcTitle.Size = UDim2.new(1, -90, 1, 0)
        tcTitle.Position = UDim2.new(0, 8, 0, 0)
        tcTitle.BackgroundTransparency = 1
        tcTitle.Text = "工具調用: " .. tostring(msg.toolName)
        tcTitle.Font = Enum.Font.GothamBold
        tcTitle.TextSize = 10.5
        tcTitle.TextColor3 = Color3.fromRGB(120, 220, 255)
        tcTitle.TextXAlignment = Enum.TextXAlignment.Left
        tcTitle.Parent = tcHeader

        local tcBadge = Instance.new("TextLabel")
        tcBadge.Size = UDim2.new(0, 75, 0, 16)
        tcBadge.Position = UDim2.new(1, -80, 0, 4)
        tcBadge.BackgroundColor3 = Color3.fromRGB(12, 14, 20)
        tcBadge.Text = (msg.status == "running") and "執行中" or ((msg.error or msg.status == "error") and "失敗" or "成功")
        tcBadge.Font = Enum.Font.Code
        tcBadge.TextSize = 9
        tcBadge.TextColor3 = (msg.status == "running") and Color3.fromRGB(255, 215, 0) or ((msg.error or msg.status == "error") and Color3.fromRGB(255, 100, 100) or Color3.fromRGB(100, 255, 120))
        tcBadge.Parent = tcHeader
        Instance.new("UICorner", tcBadge).CornerRadius = UDim.new(0, 3)

        local tcContent = Instance.new("Frame")
        tcContent.Size = UDim2.new(1, -16, 0, 0)
        tcContent.Position = UDim2.new(0, 8, 0, 28)
        tcContent.AutomaticSize = Enum.AutomaticSize.Y
        tcContent.BackgroundTransparency = 1
        tcContent.Parent = toolCard
        local tcLayout = Instance.new("UIListLayout", tcContent)
        tcLayout.SortOrder = Enum.SortOrder.LayoutOrder
        tcLayout.Padding = UDim.new(0, 4)

        if msg.toolArgs and next(msg.toolArgs) and msg.toolName ~= "execute_luau" then
            local argsLabel = Instance.new("TextLabel")
            argsLabel.Size = UDim2.new(1, 0, 0, 0)
            argsLabel.AutomaticSize = Enum.AutomaticSize.Y
            argsLabel.BackgroundTransparency = 1
            argsLabel.Text = "參數: " .. (safeJSONEncode(msg.toolArgs) or "")
            argsLabel.Font = Enum.Font.Code
            argsLabel.TextSize = 9.5
            argsLabel.TextColor3 = Color3.fromRGB(180, 185, 200)
            argsLabel.TextWrapped = true
            argsLabel.TextXAlignment = Enum.TextXAlignment.Left
            argsLabel.LayoutOrder = 1
            argsLabel.Parent = tcContent
        end

        if msg.observation and #tostring(msg.observation) > 0 and msg.toolName ~= "execute_luau" then
            local obsText = tostring(msg.observation)
            if #obsText > 2500 then
                obsText = obsText:sub(1, 2500) .. "\n...[觀測日誌過長已自動截斷]"
            end
            local obsLabel = Instance.new("TextLabel")
            obsLabel.Size = UDim2.new(1, 0, 0, 0)
            obsLabel.AutomaticSize = Enum.AutomaticSize.Y
            obsLabel.BackgroundTransparency = 1
            obsLabel.Text = "觀測結果:\n" .. obsText
            obsLabel.Font = Enum.Font.Code
            obsLabel.TextSize = 10
            obsLabel.TextColor3 = Color3.fromRGB(140, 240, 190)
            obsLabel.TextWrapped = true
            obsLabel.TextXAlignment = Enum.TextXAlignment.Left
            obsLabel.LayoutOrder = 2
            obsLabel.Parent = tcContent
        end

        local tcPad = Instance.new("UIPadding", toolCard)
        tcPad.PaddingBottom = UDim.new(0, 8)
    end

    -- 4. 代碼卡片 (Code block with Copy & Re-run)
    if msg.code and #msg.code > 0 then
        local codeCard = Instance.new("Frame")
        codeCard.Size = UDim2.new(1, 0, 0, 0)
        codeCard.AutomaticSize = Enum.AutomaticSize.Y
        codeCard.BackgroundColor3 = Color3.fromRGB(14, 15, 20)
        codeCard.LayoutOrder = 5
        Instance.new("UICorner", codeCard).CornerRadius = UDim.new(0, 6)
        codeCard.Parent = card

        local codeHeader = Instance.new("Frame")
        codeHeader.Size = UDim2.new(1, 0, 0, 26)
        codeHeader.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
        codeHeader.BorderSizePixel = 0
        Instance.new("UICorner", codeHeader).CornerRadius = UDim.new(0, 6)
        codeHeader.Parent = codeCard

        local cTitle = Instance.new("TextLabel")
        cTitle.Size = UDim2.new(0.5, 0, 1, 0)
        cTitle.Position = UDim2.new(0, 8, 0, 0)
        cTitle.BackgroundTransparency = 1
        cTitle.Text = "Luau 腳本"
        cTitle.Font = Enum.Font.GothamBold
        cTitle.TextSize = 11
        cTitle.TextColor3 = Color3.fromRGB(140, 255, 170)
        cTitle.TextXAlignment = Enum.TextXAlignment.Left
        cTitle.Parent = codeHeader

        local copyBtn = Instance.new("TextButton")
        copyBtn.Size = UDim2.new(0, 60, 0, 20)
        copyBtn.Position = UDim2.new(1, -135, 0, 3)
        copyBtn.BackgroundColor3 = Color3.fromRGB(38, 42, 56)
        copyBtn.Text = "複製"
        copyBtn.Font = Enum.Font.GothamMedium
        copyBtn.TextSize = 10
        copyBtn.TextColor3 = Color3.fromRGB(220, 220, 230)
        Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0, 4)
        copyBtn.Parent = codeHeader

        copyBtn.MouseButton1Click:Connect(function()
            if setclipboard then
                pcall(setclipboard, msg.code)
                copyBtn.Text = "已複製"
                task.delay(1.2, function() copyBtn.Text = "複製" end)
            else
                copyBtn.Text = "無剪貼簿"
                task.delay(1.2, function() copyBtn.Text = "複製" end)
            end
        end)

        local reRunBtn = Instance.new("TextButton")
        local isWaiting = (msg.status == "waiting_approval")
        reRunBtn.Size = isWaiting and UDim2.new(0, 85, 0, 20) or UDim2.new(0, 65, 0, 20)
        reRunBtn.Position = isWaiting and UDim2.new(1, -90, 0, 3) or UDim2.new(1, -70, 0, 3)
        reRunBtn.BackgroundColor3 = isWaiting and Color3.fromRGB(40, 140, 70) or Color3.fromRGB(30, 110, 60)
        reRunBtn.Text = isWaiting and "▶️ 批准執行" or "執行"
        reRunBtn.Font = Enum.Font.GothamBold
        reRunBtn.TextSize = 10
        reRunBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        Instance.new("UICorner", reRunBtn).CornerRadius = UDim.new(0, 4)
        reRunBtn.Parent = codeHeader

        reRunBtn.MouseButton1Click:Connect(function()
            if executeCodeAction then
                executeCodeAction(msg.code)
            end
        end)

        local codeText = Instance.new("TextLabel")
        codeText.Size = UDim2.new(1, -16, 0, 0)
        codeText.Position = UDim2.new(0, 8, 0, 32)
        codeText.AutomaticSize = Enum.AutomaticSize.Y
        codeText.BackgroundTransparency = 1
        codeText.Text = msg.code
        codeText.Font = Enum.Font.Code
        codeText.TextSize = 11
        codeText.TextColor3 = Color3.fromRGB(150, 255, 180)
        codeText.TextWrapped = true
        codeText.TextXAlignment = Enum.TextXAlignment.Left
        codeText.Parent = codeCard
        local cPad = Instance.new("UIPadding", codeCard)
        cPad.PaddingBottom = UDim.new(0, 8)
    end

    -- 5. ACI 終端輸出 (Terminal console output)
    if (msg.logs and #msg.logs > 0) or msg.error or (msg.code and msg.observation and #msg.observation > 0) then
        local termCard = Instance.new("Frame")
        termCard.Size = UDim2.new(1, 0, 0, 0)
        termCard.AutomaticSize = Enum.AutomaticSize.Y
        termCard.BackgroundColor3 = Color3.fromRGB(10, 10, 14)
        termCard.LayoutOrder = 6
        Instance.new("UICorner", termCard).CornerRadius = UDim.new(0, 6)
        termCard.Parent = card

        local termHeader = Instance.new("TextLabel")
        termHeader.Size = UDim2.new(1, -12, 0, 22)
        termHeader.Position = UDim2.new(0, 6, 0, 2)
        termHeader.BackgroundTransparency = 1
        termHeader.Text = msg.error and "ACI 終端報錯 (Traceback)" or "ACI 終端輸出 (Output)"
        termHeader.Font = Enum.Font.GothamBold
        termHeader.TextSize = 10
        termHeader.TextColor3 = msg.error and Color3.fromRGB(255, 100, 100) or Color3.fromRGB(100, 220, 255)
        termHeader.TextXAlignment = Enum.TextXAlignment.Left
        termHeader.Parent = termCard

        local logLines = {}
        if msg.error then
            table.insert(logLines, "[Error] " .. tostring(msg.error))
        end
        if msg.logs and #msg.logs > 0 then
            for _, l in ipairs(msg.logs) do
                table.insert(logLines, l)
            end
        elseif msg.observation and #msg.observation > 0 and not msg.error then
            table.insert(logLines, msg.observation)
        end
        if #logLines == 0 then
            table.insert(logLines, "(無終端 print 輸出)")
        end

        local termText = Instance.new("TextLabel")
        termText.Size = UDim2.new(1, -16, 0, 0)
        termText.Position = UDim2.new(0, 8, 0, 24)
        termText.AutomaticSize = Enum.AutomaticSize.Y
        termText.BackgroundTransparency = 1
        termText.Text = table.concat(logLines, "\n")
        termText.Font = Enum.Font.Code
        termText.TextSize = 10
        termText.TextColor3 = msg.error and Color3.fromRGB(255, 150, 150) or Color3.fromRGB(180, 240, 180)
        termText.TextWrapped = true
        termText.TextXAlignment = Enum.TextXAlignment.Left
        termText.Parent = termCard
        local termPad = Instance.new("UIPadding", termCard)
        termPad.PaddingBottom = UDim.new(0, 6)
    end

    return card
end

local function renderActiveSessionChat()
    for _, child in ipairs(ChatScroll:GetChildren()) do
        if child:IsA("Frame") then
            child:Destroy()
        end
    end

    local sess = getActiveSession()
    ModelBadge.Text = "[" .. tostring(Config.MODEL) .. "]"

    if #sess.messages == 0 then
        local emptyCard = Instance.new("Frame")
        emptyCard.Size = UDim2.new(1, 0, 0, 70)
        emptyCard.BackgroundColor3 = Color3.fromRGB(22, 23, 30)
        Instance.new("UICorner", emptyCard).CornerRadius = UDim.new(0, 8)
        emptyCard.Parent = ChatScroll

        local emptyText = Instance.new("TextLabel")
        emptyText.Size = UDim2.new(1, -20, 1, 0)
        emptyText.Position = UDim2.new(0, 10, 0, 0)
        emptyText.BackgroundTransparency = 1
        emptyText.Text = "歡迎使用 BloxAgent Pro (CodeAct 運行時)！\n請在下方輸入任務指令，模型將直接生成並執行 Luau 代碼完成目標。"
        emptyText.Font = Enum.Font.Gotham
        emptyText.TextSize = 12
        emptyText.TextColor3 = Color3.fromRGB(170, 175, 195)
        emptyText.TextWrapped = true
        emptyText.Parent = emptyCard
    else
        for _, msg in ipairs(sess.messages) do
            if msg.role == "user" then
                local uCard = buildUserCard(msg)
                uCard.Parent = ChatScroll
            else
                local aCard = buildAgentCard(msg)
                aCard.Parent = ChatScroll
            end
        end
    end

    scrollToBottom()
end

-- ==================== [ 12. 抽屜式會話面板 (Session Drawer) ] ====================
local SessionDrawer = Instance.new("Frame")
SessionDrawer.Name = "SessionDrawer"
SessionDrawer.Size = UDim2.new(0.85, 0, 1, 0)
SessionDrawer.Position = UDim2.new(0, 0, 0, 0)
SessionDrawer.BackgroundColor3 = Color3.fromRGB(20, 21, 28)
SessionDrawer.BorderSizePixel = 0
SessionDrawer.ZIndex = 50
SessionDrawer.Visible = false
SessionDrawer.Parent = MainFrame
Instance.new("UICorner", SessionDrawer).CornerRadius = UDim.new(0, 12)
local sessionStroke = Instance.new("UIStroke", SessionDrawer)
sessionStroke.Color = Color3.fromRGB(50, 55, 75)

local DrawerHeader = Instance.new("Frame")
DrawerHeader.Size = UDim2.new(1, 0, 0, 38)
DrawerHeader.BackgroundColor3 = Color3.fromRGB(26, 28, 38)
DrawerHeader.BorderSizePixel = 0
DrawerHeader.ZIndex = 51
DrawerHeader.Parent = SessionDrawer
Instance.new("UICorner", DrawerHeader).CornerRadius = UDim.new(0, 12)

local DrawerTitle = Instance.new("TextLabel")
DrawerTitle.Size = UDim2.new(0.6, 0, 1, 0)
DrawerTitle.Position = UDim2.new(0, 10, 0, 0)
DrawerTitle.BackgroundTransparency = 1
DrawerTitle.Text = "會話列表 (Sessions)"
DrawerTitle.Font = Enum.Font.GothamBold
DrawerTitle.TextSize = 12
DrawerTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
DrawerTitle.TextXAlignment = Enum.TextXAlignment.Left
DrawerTitle.ZIndex = 52
DrawerTitle.Parent = DrawerHeader

local NewSessBtn = Instance.new("TextButton")
NewSessBtn.Size = UDim2.new(0, 60, 0, 24)
NewSessBtn.Position = UDim2.new(1, -98, 0, 7)
NewSessBtn.BackgroundColor3 = Color3.fromRGB(35, 140, 70)
NewSessBtn.Text = "+ 新增"
NewSessBtn.Font = Enum.Font.GothamBold
NewSessBtn.TextSize = 10
NewSessBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
NewSessBtn.ZIndex = 52
NewSessBtn.Parent = DrawerHeader
Instance.new("UICorner", NewSessBtn).CornerRadius = UDim.new(0, 4)

local CloseDrawerBtn = Instance.new("TextButton")
CloseDrawerBtn.Size = UDim2.new(0, 24, 0, 24)
CloseDrawerBtn.Position = UDim2.new(1, -32, 0, 7)
CloseDrawerBtn.BackgroundColor3 = Color3.fromRGB(150, 45, 45)
CloseDrawerBtn.Text = "✕"
CloseDrawerBtn.Font = Enum.Font.GothamBold
CloseDrawerBtn.TextSize = 11
CloseDrawerBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
CloseDrawerBtn.ZIndex = 52
CloseDrawerBtn.Parent = DrawerHeader
Instance.new("UICorner", CloseDrawerBtn).CornerRadius = UDim.new(0, 4)

local DrawerListScroll = Instance.new("ScrollingFrame")
DrawerListScroll.Size = UDim2.new(1, -16, 1, -48)
DrawerListScroll.Position = UDim2.new(0, 8, 0, 44)
DrawerListScroll.BackgroundColor3 = Color3.fromRGB(14, 15, 20)
DrawerListScroll.BorderSizePixel = 0
DrawerListScroll.ScrollBarThickness = 4
DrawerListScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
DrawerListScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
DrawerListScroll.ZIndex = 51
DrawerListScroll.Parent = SessionDrawer
Instance.new("UICorner", DrawerListScroll).CornerRadius = UDim.new(0, 6)

local DrawerListLayout = Instance.new("UIListLayout")
DrawerListLayout.SortOrder = Enum.SortOrder.LayoutOrder
DrawerListLayout.Padding = UDim.new(0, 4)
DrawerListLayout.Parent = DrawerListScroll

local function renderDrawerSessionList()
    for _, item in ipairs(DrawerListScroll:GetChildren()) do
        if item:IsA("Frame") then item:Destroy() end
    end

    for _, sess in ipairs(SessionManager.List) do
        local isCurrent = (sess.id == SessionManager.ActiveId)

        local itemCard = Instance.new("Frame")
        itemCard.Size = UDim2.new(1, 0, 0, 38)
        itemCard.BackgroundColor3 = isCurrent and Color3.fromRGB(35, 45, 62) or Color3.fromRGB(24, 25, 32)
        itemCard.ZIndex = 52
        Instance.new("UICorner", itemCard).CornerRadius = UDim.new(0, 6)
        itemCard.Parent = DrawerListScroll

        local nameBtn = Instance.new("TextButton")
        nameBtn.Size = UDim2.new(1, -75, 1, 0)
        nameBtn.Position = UDim2.new(0, 8, 0, 0)
        nameBtn.BackgroundTransparency = 1
        nameBtn.Text = string.format("%s (%d 則)", sess.name, #(sess.messages or {}))
        nameBtn.Font = isCurrent and Enum.Font.GothamBold or Enum.Font.Gotham
        nameBtn.TextSize = 11
        nameBtn.TextColor3 = isCurrent and Color3.fromRGB(120, 210, 255) or Color3.fromRGB(200, 205, 215)
        nameBtn.TextXAlignment = Enum.TextXAlignment.Left
        nameBtn.ZIndex = 53
        nameBtn.Parent = itemCard

        nameBtn.MouseButton1Click:Connect(function()
            SessionManager.ActiveId = sess.id
            saveSessionsToWorkspace()
            SessionDrawer.Visible = false
            renderActiveSessionChat()
        end)

        local delBtn = Instance.new("TextButton")
        delBtn.Size = UDim2.new(0, 24, 0, 24)
        delBtn.Position = UDim2.new(1, -30, 0, 7)
        delBtn.BackgroundColor3 = Color3.fromRGB(160, 40, 40)
        delBtn.Text = "✕"
        delBtn.TextSize = 11
        delBtn.ZIndex = 53
        delBtn.Parent = itemCard
        Instance.new("UICorner", delBtn).CornerRadius = UDim.new(0, 4)

        delBtn.MouseButton1Click:Connect(function()
            if #SessionManager.List <= 1 then
                delBtn.Text = "─"
                task.delay(1.2, function() delBtn.Text = "✕" end)
                return
            end
            for i, s in ipairs(SessionManager.List) do
                if s.id == sess.id then
                    table.remove(SessionManager.List, i)
                    break
                end
            end
            if SessionManager.ActiveId == sess.id then
                SessionManager.ActiveId = SessionManager.List[1].id
            end
            saveSessionsToWorkspace()
            renderDrawerSessionList()
            renderActiveSessionChat()
        end)
    end
end

SessionDrawerBtn.MouseButton1Click:Connect(function()
    SessionDrawer.Visible = not SessionDrawer.Visible
    if SessionDrawer.Visible then
        renderDrawerSessionList()
    end
end)

CloseDrawerBtn.MouseButton1Click:Connect(function()
    SessionDrawer.Visible = false
end)

NewSessBtn.MouseButton1Click:Connect(function()
    createNewSession()
    renderDrawerSessionList()
    renderActiveSessionChat()
end)

-- ==================== [ 13. 設定面板 (Settings Modal) ] ====================
local SettingsModal = Instance.new("Frame")
SettingsModal.Name = "SettingsModal"
SettingsModal.Size = UDim2.new(1, 0, 1, 0)
SettingsModal.Position = UDim2.new(0, 0, 0, 0)
SettingsModal.BackgroundColor3 = Color3.fromRGB(20, 21, 28)
SettingsModal.BorderSizePixel = 0
SettingsModal.ZIndex = 60
SettingsModal.Visible = false
SettingsModal.Parent = MainFrame
Instance.new("UICorner", SettingsModal).CornerRadius = UDim.new(0, 12)

local SetHeader = Instance.new("Frame")
SetHeader.Size = UDim2.new(1, 0, 0, 38)
SetHeader.BackgroundColor3 = Color3.fromRGB(26, 28, 38)
SetHeader.BorderSizePixel = 0
SetHeader.ZIndex = 61
SetHeader.Parent = SettingsModal
Instance.new("UICorner", SetHeader).CornerRadius = UDim.new(0, 12)

local SetTitle = Instance.new("TextLabel")
SetTitle.Size = UDim2.new(0.6, 0, 1, 0)
SetTitle.Position = UDim2.new(0, 12, 0, 0)
SetTitle.BackgroundTransparency = 1
SetTitle.Text = "⚙️ BloxAgent 設定 (Preferences)"
SetTitle.Font = Enum.Font.GothamBold
SetTitle.TextSize = 12
SetTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
SetTitle.TextXAlignment = Enum.TextXAlignment.Left
SetTitle.ZIndex = 62
SetTitle.Parent = SetHeader

local CloseSetBtn = Instance.new("TextButton")
CloseSetBtn.Size = UDim2.new(0, 80, 0, 24)
CloseSetBtn.Position = UDim2.new(1, -88, 0, 7)
CloseSetBtn.BackgroundColor3 = Color3.fromRGB(40, 140, 70)
CloseSetBtn.Text = "儲存並關閉"
CloseSetBtn.Font = Enum.Font.GothamBold
CloseSetBtn.TextSize = 10
CloseSetBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
CloseSetBtn.ZIndex = 62
CloseSetBtn.Parent = SetHeader
Instance.new("UICorner", CloseSetBtn).CornerRadius = UDim.new(0, 4)

local SetScroll = Instance.new("ScrollingFrame")
SetScroll.Size = UDim2.new(1, -16, 1, -48)
SetScroll.Position = UDim2.new(0, 8, 0, 44)
SetScroll.BackgroundColor3 = Color3.fromRGB(14, 15, 20)
SetScroll.BorderSizePixel = 0
SetScroll.ScrollBarThickness = 4
SetScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
SetScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
SetScroll.ZIndex = 61
SetScroll.Parent = SettingsModal
Instance.new("UICorner", SetScroll).CornerRadius = UDim.new(0, 6)

local SetLayout = Instance.new("UIListLayout")
SetLayout.SortOrder = Enum.SortOrder.LayoutOrder
SetLayout.Padding = UDim.new(0, 8)
SetLayout.Parent = SetScroll

local setPad = Instance.new("UIPadding", SetScroll)
setPad.PaddingTop = UDim.new(0, 8)
setPad.PaddingBottom = UDim.new(0, 8)
setPad.PaddingLeft = UDim.new(0, 8)
setPad.PaddingRight = UDim.new(0, 8)

local function makeSectionHeader(text, order)
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 0, 20)
    lbl.BackgroundTransparency = 1
    lbl.Text = text
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = 11
    lbl.TextColor3 = Color3.fromRGB(100, 200, 255)
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.LayoutOrder = order
    lbl.ZIndex = 62
    lbl.Parent = SetScroll
    return lbl
end

-- 通用橫向滑塊建構器 (Reusable Horizontal Slider Builder)
-- config = { layoutOrder, min, max, step, default, format(val)->str, color, onChange(val) }
local _activeSliderUpdate = nil  -- 全域拖曳中的滑塊更新函數 (一次只有一個滑塊在拖曳)
local function makeSlider(config)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 28)
    row.BackgroundTransparency = 1
    row.LayoutOrder = config.layoutOrder
    row.ZIndex = 62
    row.Parent = SetScroll

    -- 軌道背景 (Track)
    local track = Instance.new("TextButton")
    track.Size = UDim2.new(0.7, 0, 0, 8)
    track.Position = UDim2.new(0, 0, 0.5, -4)
    track.BackgroundColor3 = Color3.fromRGB(40, 42, 55)
    track.AutoButtonColor = false
    track.Text = ""
    track.ZIndex = 63
    track.Parent = row
    Instance.new("UICorner", track).CornerRadius = UDim.new(0, 4)

    -- 填充條 (Fill bar)
    local fill = Instance.new("Frame")
    fill.Size = UDim2.new(0, 0, 1, 0)
    fill.BackgroundColor3 = config.color or Color3.fromRGB(80, 160, 255)
    fill.ZIndex = 64
    fill.ClipsDescendants = true
    fill.Parent = track
    Instance.new("UICorner", fill).CornerRadius = UDim.new(0, 4)

    -- 拖曳圓鈕 (Thumb)
    local thumb = Instance.new("Frame")
    thumb.Size = UDim2.new(0, 16, 0, 16)
    thumb.AnchorPoint = Vector2.new(0.5, 0.5)
    thumb.Position = UDim2.new(0, 0, 0.5, 0)
    thumb.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    thumb.ZIndex = 66
    thumb.Parent = track
    Instance.new("UICorner", thumb).CornerRadius = UDim.new(1, 0)
    local thumbStroke = Instance.new("UIStroke", thumb)
    thumbStroke.Color = config.color or Color3.fromRGB(80, 160, 255)
    thumbStroke.Thickness = 1.5

    -- 數值標籤 (Value Label)
    local valLabel = Instance.new("TextLabel")
    valLabel.Size = UDim2.new(0.28, 0, 1, 0)
    valLabel.Position = UDim2.new(0.72, 0, 0, 0)
    valLabel.BackgroundTransparency = 1
    valLabel.Font = Enum.Font.Code
    valLabel.TextSize = 10
    valLabel.TextColor3 = config.color or Color3.fromRGB(180, 185, 200)
    valLabel.TextXAlignment = Enum.TextXAlignment.Right
    valLabel.ZIndex = 63
    valLabel.Parent = row

    local min = config.min
    local max = config.max
    local step = config.step
    local currentVal = config.default or min

    local function snapValue(rawVal)
        if step and step > 0 then
            rawVal = math.floor(rawVal / step + 0.5) * step
            rawVal = tonumber(string.format("%." .. math.max(0, -math.floor(math.log10(step + 1e-9))) .. "f", rawVal)) or rawVal
        end
        return math.clamp(rawVal, min, max)
    end

    local function setVisual(val)
        local t = math.clamp((val - min) / (max - min), 0, 1)
        fill.Size = UDim2.new(t, 0, 1, 0)
        thumb.Position = UDim2.new(t, 0, 0.5, 0)
        valLabel.Text = config.format(val)
    end

    local function updateFromX(absX)
        local trackPos = track.AbsolutePosition.X
        local trackWidth = track.AbsoluteSize.X
        if trackWidth < 1 then return end
        local t = math.clamp((absX - trackPos) / trackWidth, 0, 1)
        currentVal = snapValue(min + t * (max - min))
        setVisual(currentVal)
        if config.onChange then config.onChange(currentVal) end
    end

    setVisual(currentVal)

    -- 點擊與拖曳邏輯 (Click & Drag)
    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            updateFromX(input.Position.X)
            _activeSliderUpdate = updateFromX
        end
    end)

    return { frame = row, setVisual = setVisual, getValue = function() return currentVal end }
end

-- 全域拖曳追蹤 (統一由一個連線處理所有滑塊拖曳)
UserInputService.InputChanged:Connect(function(input)
    if _activeSliderUpdate and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        _activeSliderUpdate(input.Position.X)
    end
end)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        if _activeSliderUpdate then
            _activeSliderUpdate = nil
            saveConfig()
        end
    end
end)

-- 1. API 金鑰設定
makeSectionHeader("Google AI Studio API Key", 1)

local KeyInputBox = Instance.new("TextBox")
KeyInputBox.Size = UDim2.new(1, 0, 0, 28)
KeyInputBox.BackgroundColor3 = Color3.fromRGB(24, 26, 34)
KeyInputBox.TextColor3 = Color3.fromRGB(120, 220, 255)
KeyInputBox.PlaceholderText = "AIzaSy..."
KeyInputBox.Text = CurrentApiKey
KeyInputBox.Font = Enum.Font.Code
KeyInputBox.TextSize = 11
KeyInputBox.ClearTextOnFocus = false
KeyInputBox.LayoutOrder = 2
KeyInputBox.ZIndex = 62
KeyInputBox.Parent = SetScroll
Instance.new("UICorner", KeyInputBox).CornerRadius = UDim.new(0, 6)

KeyInputBox.FocusLost:Connect(function()
    local text = (KeyInputBox.Text:gsub("%s+", ""))
    if text ~= "" and text ~= CurrentApiKey then
        CurrentApiKey = text
        saveApiKey(text)
    end
end)

-- 2. 模型設定
makeSectionHeader("模型選擇 (Model Selection)", 3)

local ModelInputBox = Instance.new("TextBox")
ModelInputBox.Size = UDim2.new(1, 0, 0, 28)
ModelInputBox.BackgroundColor3 = Color3.fromRGB(24, 26, 34)
ModelInputBox.TextColor3 = Color3.fromRGB(255, 215, 0)
ModelInputBox.PlaceholderText = "gemini-2.0-flash"
ModelInputBox.Text = Config.MODEL
ModelInputBox.Font = Enum.Font.Code
ModelInputBox.TextSize = 11
ModelInputBox.ClearTextOnFocus = false
ModelInputBox.LayoutOrder = 4
ModelInputBox.ZIndex = 62
ModelInputBox.Parent = SetScroll
Instance.new("UICorner", ModelInputBox).CornerRadius = UDim.new(0, 6)

ModelInputBox.FocusLost:Connect(function()
    local m = (ModelInputBox.Text:gsub("%s+", ""))
    if m ~= "" then
        Config.MODEL = m
        saveConfig()
        ModelBadge.Text = "[" .. m .. "]"
    end
end)

local ModelButtonsFrame = Instance.new("Frame")
ModelButtonsFrame.Size = UDim2.new(1, 0, 0, 24)
ModelButtonsFrame.BackgroundTransparency = 1
ModelButtonsFrame.LayoutOrder = 5
ModelButtonsFrame.ZIndex = 62
ModelButtonsFrame.Parent = SetScroll

local QUICK_MODELS = { "gemini-2.0-flash", "gemini-2.0-flash-exp", "gemini-2.5-flash", "gemini-1.5-pro" }
for idx, mName in ipairs(QUICK_MODELS) do
    local qBtn = Instance.new("TextButton")
    qBtn.Size = UDim2.new(0.24, -2, 1, 0)
    qBtn.Position = UDim2.new((idx - 1) * 0.25, 0, 0, 0)
    qBtn.BackgroundColor3 = Color3.fromRGB(36, 40, 52)
    qBtn.Text = mName:gsub("gemini%-", "")
    qBtn.Font = Enum.Font.GothamMedium
    qBtn.TextSize = 9
    qBtn.TextColor3 = Color3.fromRGB(200, 220, 255)
    qBtn.ZIndex = 63
    qBtn.Parent = ModelButtonsFrame
    Instance.new("UICorner", qBtn).CornerRadius = UDim.new(0, 4)

    qBtn.MouseButton1Click:Connect(function()
        Config.MODEL = mName
        ModelInputBox.Text = mName
        ModelBadge.Text = "[" .. mName .. "]"
        saveConfig()
    end)
end

-- 3. Agent 執行設置
makeSectionHeader("Agent 執行設置 (Execution & Tool Options)", 6)

local AutoLoopRow = Instance.new("Frame")
AutoLoopRow.Size = UDim2.new(1, 0, 0, 28)
AutoLoopRow.BackgroundTransparency = 1
AutoLoopRow.LayoutOrder = 7
AutoLoopRow.ZIndex = 62
AutoLoopRow.Parent = SetScroll

local AutoExecBtn = Instance.new("TextButton")
AutoExecBtn.Size = UDim2.new(1, 0, 1, 0)
AutoExecBtn.BackgroundColor3 = Config.AUTO_EXECUTE and Color3.fromRGB(30, 100, 150) or Color3.fromRGB(50, 52, 65)
AutoExecBtn.Text = Config.AUTO_EXECUTE and "CodeAct 自動執行: 開 (自主長程迴圈，無限制輪次)" or "CodeAct 自動執行: 關 (手動單步審批)"
AutoExecBtn.Font = Enum.Font.GothamBold
AutoExecBtn.TextSize = 10
AutoExecBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
AutoExecBtn.ZIndex = 63
AutoExecBtn.Parent = AutoLoopRow
Instance.new("UICorner", AutoExecBtn).CornerRadius = UDim.new(0, 4)

AutoExecBtn.MouseButton1Click:Connect(function()
    Config.AUTO_EXECUTE = not Config.AUTO_EXECUTE
    AutoExecBtn.BackgroundColor3 = Config.AUTO_EXECUTE and Color3.fromRGB(30, 100, 150) or Color3.fromRGB(50, 52, 65)
    AutoExecBtn.Text = Config.AUTO_EXECUTE and "CodeAct 自動執行: 開 (自主長程迴圈，無限制輪次)" or "CodeAct 自動執行: 關 (手動單步審批)"
    saveConfig()
end)

-- 3.5 上下文治理與自動壓縮
local AutoCompactRow = Instance.new("Frame")
AutoCompactRow.Size = UDim2.new(1, 0, 0, 28)
AutoCompactRow.BackgroundTransparency = 1
AutoCompactRow.LayoutOrder = 8
AutoCompactRow.ZIndex = 62
AutoCompactRow.Parent = SetScroll

local AutoCompactBtn = Instance.new("TextButton")
AutoCompactBtn.Size = UDim2.new(1, 0, 1, 0)
AutoCompactBtn.BackgroundColor3 = Config.AUTO_COMPACT and Color3.fromRGB(30, 120, 100) or Color3.fromRGB(50, 52, 65)
AutoCompactBtn.Text = Config.AUTO_COMPACT and "自動記憶壓縮: 開" or "自動記憶壓縮: 關"
AutoCompactBtn.Font = Enum.Font.GothamBold
AutoCompactBtn.TextSize = 10
AutoCompactBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
AutoCompactBtn.ZIndex = 63
AutoCompactBtn.Parent = AutoCompactRow
Instance.new("UICorner", AutoCompactBtn).CornerRadius = UDim.new(0, 4)

AutoCompactBtn.MouseButton1Click:Connect(function()
    Config.AUTO_COMPACT = not Config.AUTO_COMPACT
    AutoCompactBtn.BackgroundColor3 = Config.AUTO_COMPACT and Color3.fromRGB(30, 120, 100) or Color3.fromRGB(50, 52, 65)
    AutoCompactBtn.Text = Config.AUTO_COMPACT and "自動記憶壓縮: 開" or "自動記憶壓縮: 關"
    saveConfig()
end)

makeSectionHeader("壓縮閾值 (Compact Threshold)", 8.5)
makeSlider({
    layoutOrder = 8.6,
    min = 4, max = 20, step = 2,
    default = tonumber(Config.COMPACT_THRESHOLD) or 8,
    format = function(v) return string.format("%d 輪", v) end,
    color = Color3.fromRGB(60, 180, 140),
    onChange = function(v) Config.COMPACT_THRESHOLD = v end,
})

-- 4. 思考深度 (Think Level)
makeSectionHeader("思考深度 (Think Level)", 9)
local ThinkRow = Instance.new("Frame")
ThinkRow.Size = UDim2.new(1, 0, 0, 24)
ThinkRow.BackgroundTransparency = 1
ThinkRow.LayoutOrder = 9
ThinkRow.ZIndex = 62
ThinkRow.Parent = SetScroll

local THINK_LEVELS = { "Off", "Low", "Medium", "High" }
local thinkButtons = {}

for idx, lvl in ipairs(THINK_LEVELS) do
    local tBtn = Instance.new("TextButton")
    tBtn.Size = UDim2.new(0.24, -2, 1, 0)
    tBtn.Position = UDim2.new((idx - 1) * 0.25, 0, 0, 0)
    tBtn.BackgroundColor3 = (Config.THINK_LEVEL == lvl) and Color3.fromRGB(80, 50, 140) or Color3.fromRGB(35, 36, 46)
    tBtn.Text = lvl
    tBtn.Font = Enum.Font.GothamMedium
    tBtn.TextSize = 10
    tBtn.TextColor3 = (Config.THINK_LEVEL == lvl) and Color3.fromRGB(220, 180, 255) or Color3.fromRGB(160, 165, 180)
    tBtn.ZIndex = 63
    tBtn.Parent = ThinkRow
    Instance.new("UICorner", tBtn).CornerRadius = UDim.new(0, 4)
    thinkButtons[lvl] = tBtn

    tBtn.MouseButton1Click:Connect(function()
        Config.THINK_LEVEL = lvl
        for k, b in pairs(thinkButtons) do
            b.BackgroundColor3 = (k == lvl) and Color3.fromRGB(80, 50, 140) or Color3.fromRGB(35, 36, 46)
            b.TextColor3 = (k == lvl) and Color3.fromRGB(220, 180, 255) or Color3.fromRGB(160, 165, 180)
        end
        saveConfig()
    end)
end

-- 5. PC 呼出鍵設定 (PC Keybind)
makeSectionHeader("PC 介面呼出快捷鍵 (PC Toggle Key)", 10)
local KeyRow = Instance.new("Frame")
KeyRow.Size = UDim2.new(1, 0, 0, 24)
KeyRow.BackgroundTransparency = 1
KeyRow.LayoutOrder = 11
KeyRow.ZIndex = 62
KeyRow.Parent = SetScroll

local PC_KEYS = { "RightControl", "Insert", "F4", "LeftAlt", "Backquote" }
local keyButtons = {}

for idx, kName in ipairs(PC_KEYS) do
    local kBtn = Instance.new("TextButton")
    kBtn.Size = UDim2.new(0.19, -2, 1, 0)
    kBtn.Position = UDim2.new((idx - 1) * 0.20, 0, 0, 0)
    kBtn.BackgroundColor3 = (Config.PC_TOGGLE_KEY == kName) and Color3.fromRGB(40, 100, 160) or Color3.fromRGB(35, 36, 46)
    kBtn.Text = (kName == "RightControl" and "RCtrl") or (kName == "Backquote" and "~") or kName
    kBtn.Font = Enum.Font.GothamMedium
    kBtn.TextSize = 9
    kBtn.TextColor3 = (Config.PC_TOGGLE_KEY == kName) and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(160, 165, 180)
    kBtn.ZIndex = 63
    kBtn.Parent = KeyRow
    Instance.new("UICorner", kBtn).CornerRadius = UDim.new(0, 4)
    keyButtons[kName] = kBtn

    kBtn.MouseButton1Click:Connect(function()
        Config.PC_TOGGLE_KEY = kName
        for k, b in pairs(keyButtons) do
            b.BackgroundColor3 = (k == kName) and Color3.fromRGB(40, 100, 160) or Color3.fromRGB(35, 36, 46)
            b.TextColor3 = (k == kName) and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(160, 165, 180)
        end
        saveConfig()
    end)
end

-- 6. 背景透明度 (GUI Transparency)
makeSectionHeader("面板背景透明度 (Transparency)", 12)
makeSlider({
    layoutOrder = 12.5,
    min = 0, max = 0.5, step = 0.05,
    default = tonumber(Config.GUI_TRANSPARENCY) or 0.05,
    format = function(v) return string.format("%.0f%%", v * 100) end,
    color = Color3.fromRGB(100, 140, 200),
    onChange = function(v)
        Config.GUI_TRANSPARENCY = v
        MainFrame.BackgroundTransparency = v
    end,
})

-- 6.5 通信方式 (HTTP / WebSocket)
makeSectionHeader("📡 通信方式 (Communication Method)", 13)
local CommMethodRow = Instance.new("Frame")
CommMethodRow.Size = UDim2.new(1, 0, 0, 28)
CommMethodRow.BackgroundTransparency = 1
CommMethodRow.LayoutOrder = 13.5
CommMethodRow.ZIndex = 62
CommMethodRow.Parent = SetScroll

local COMM_METHODS = {
    { key = "HTTP", label = "HTTP (標準 REST)", color = Color3.fromRGB(30, 100, 150) },
    { key = "WebSocket", label = "WebSocket (Bidi 串流)", color = Color3.fromRGB(120, 60, 160) }
}
local commMethodButtons = {}

for idx, opt in ipairs(COMM_METHODS) do
    local cmBtn = Instance.new("TextButton")
    cmBtn.Size = UDim2.new(0.5, -2, 1, 0)
    cmBtn.Position = UDim2.new((idx - 1) * 0.5, 0, 0, 0)
    local isCur = (Config.COMM_METHOD == opt.key)
    cmBtn.BackgroundColor3 = isCur and opt.color or Color3.fromRGB(35, 36, 46)
    cmBtn.Text = opt.label
    cmBtn.Font = Enum.Font.GothamBold
    cmBtn.TextSize = 10
    cmBtn.TextColor3 = isCur and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(180, 185, 200)
    cmBtn.ZIndex = 63
    cmBtn.Parent = CommMethodRow
    Instance.new("UICorner", cmBtn).CornerRadius = UDim.new(0, 4)
    commMethodButtons[opt.key] = { btn = cmBtn, color = opt.color }

    cmBtn.MouseButton1Click:Connect(function()
        Config.COMM_METHOD = opt.key
        for k, v in pairs(commMethodButtons) do
            local sel = (k == opt.key)
            v.btn.BackgroundColor3 = sel and v.color or Color3.fromRGB(35, 36, 46)
            v.btn.TextColor3 = sel and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(180, 185, 200)
        end
        saveConfig()
    end)
end

local CommMethodHint = Instance.new("TextLabel")
CommMethodHint.Size = UDim2.new(1, 0, 0, 16)
CommMethodHint.BackgroundTransparency = 1
CommMethodHint.LayoutOrder = 13.6
CommMethodHint.ZIndex = 62
CommMethodHint.Text = "  HTTP: 相容所有模型 | WebSocket: 僅限 2.0-flash-exp / realtime 等 Bidi 模型"
CommMethodHint.Font = Enum.Font.Code
CommMethodHint.TextSize = 8
CommMethodHint.TextColor3 = Color3.fromRGB(120, 130, 155)
CommMethodHint.TextXAlignment = Enum.TextXAlignment.Left
CommMethodHint.Parent = SetScroll

-- 7. WebSocket 串流超時 (waitStart 逾時秒數)
-- 7. WebSocket 串流超時
makeSectionHeader("WebSocket 串流逾時 (waitStart 秒數)", 14)
makeSlider({
    layoutOrder = 14.5,
    min = 5, max = 90, step = 5,
    default = tonumber(Config.WS_TIMEOUT) or 25,
    format = function(v) return string.format("%d 秒", v) end,
    color = Color3.fromRGB(40, 120, 180),
    onChange = function(v) Config.WS_TIMEOUT = v end,
})

-- 8. 代碼執行看門狗逾時
makeSectionHeader("🛡️ 執行看門狗逾時 (Watchdog 秒數)", 16)
makeSlider({
    layoutOrder = 16.5,
    min = 5, max = 120, step = 5,
    default = tonumber(Config.WATCHDOG_TIMEOUT) or 20,
    format = function(v) return string.format("%d 秒", v) end,
    color = Color3.fromRGB(200, 120, 40),
    onChange = function(v) Config.WATCHDOG_TIMEOUT = v end,
})

-- 9. 生成溫度
makeSectionHeader("生成溫度 (Temperature)", 18)
makeSlider({
    layoutOrder = 18.5,
    min = 0, max = 2.0, step = 0.1,
    default = tonumber(Config.TEMPERATURE) or 0.1,
    format = function(v) return string.format("%.1f", v) end,
    color = Color3.fromRGB(180, 60, 150),
    onChange = function(v) Config.TEMPERATURE = v end,
})

-- 9.5 GUI 縮放比例
makeSectionHeader("🔍 GUI 縮放比例 (GUI Scale)", 19)
makeSlider({
    layoutOrder = 19.5,
    min = 0.5, max = 2.0, step = 0.1,
    default = tonumber(Config.GUI_SCALE) or 1.0,
    format = function(v) return string.format("%.1fx", v) end,
    color = Color3.fromRGB(80, 180, 220),
    onChange = function(v)
        Config.GUI_SCALE = v
        if mainUIScale then mainUIScale.Scale = v end
    end,
})


-- 10. 當前 GUI 掛載層級提示 (GUI Location Banner)
makeSectionHeader("當前環境掛載層級 (GUI Environment)", 20)
local GuiMountBanner = Instance.new("TextLabel")
GuiMountBanner.Size = UDim2.new(1, 0, 0, 26)
GuiMountBanner.BackgroundColor3 = Color3.fromRGB(24, 28, 38)
GuiMountBanner.Text = "  掛載容器: " .. tostring(guiLocationName)
GuiMountBanner.Font = Enum.Font.Code
GuiMountBanner.TextSize = 10
GuiMountBanner.TextColor3 = Color3.fromRGB(120, 220, 255)
GuiMountBanner.TextXAlignment = Enum.TextXAlignment.Left
GuiMountBanner.LayoutOrder = 21
GuiMountBanner.ZIndex = 62
GuiMountBanner.Parent = SetScroll
Instance.new("UICorner", GuiMountBanner).CornerRadius = UDim.new(0, 4)

SettingsBtn.MouseButton1Click:Connect(function()
    SettingsModal.Visible = not SettingsModal.Visible
end)

CloseSetBtn.MouseButton1Click:Connect(function()
    SettingsModal.Visible = false
    ModelBadge.Text = "[" .. tostring(Config.MODEL) .. "]"
end)

-- ==================== [ 14. 底部輸入與控制列 (Bottom Input Bar) ] ====================
local BottomBar = Instance.new("Frame")
BottomBar.Size = UDim2.new(1, -16, 0, 72)
BottomBar.Position = UDim2.new(0, 8, 1, -78)
BottomBar.BackgroundColor3 = Color3.fromRGB(24, 25, 34)
BottomBar.BorderSizePixel = 0
BottomBar.Parent = MainFrame
Instance.new("UICorner", BottomBar).CornerRadius = UDim.new(0, 8)

local ControlSubRow = Instance.new("Frame")
ControlSubRow.Size = UDim2.new(1, -12, 0, 22)
ControlSubRow.Position = UDim2.new(0, 6, 0, 4)
ControlSubRow.BackgroundTransparency = 1
ControlSubRow.Parent = BottomBar

local AgentLoopStatusBadge = Instance.new("TextLabel")
AgentLoopStatusBadge.Size = UDim2.new(0, 130, 1, 0)
AgentLoopStatusBadge.BackgroundColor3 = Color3.fromRGB(36, 40, 54)
AgentLoopStatusBadge.Text = "CodeAct: 就緒"
AgentLoopStatusBadge.Font = Enum.Font.GothamMedium
AgentLoopStatusBadge.TextSize = 10
AgentLoopStatusBadge.TextColor3 = Color3.fromRGB(120, 220, 255)
AgentLoopStatusBadge.Parent = ControlSubRow
Instance.new("UICorner", AgentLoopStatusBadge).CornerRadius = UDim.new(0, 4)

local StepBadge = Instance.new("TextLabel")
StepBadge.Size = UDim2.new(0, 75, 1, 0)
StepBadge.Position = UDim2.new(0, 136, 0, 0)
StepBadge.BackgroundColor3 = Color3.fromRGB(36, 40, 54)
StepBadge.Text = "輪次: 0"
StepBadge.Font = Enum.Font.Code
StepBadge.TextSize = 9.5
StepBadge.TextColor3 = Color3.fromRGB(180, 185, 200)
StepBadge.Parent = ControlSubRow
Instance.new("UICorner", StepBadge).CornerRadius = UDim.new(0, 4)

local ClearChatBtn = Instance.new("TextButton")
ClearChatBtn.Size = UDim2.new(0, 75, 1, 0)
ClearChatBtn.Position = UDim2.new(1, -75, 0, 0)
ClearChatBtn.BackgroundColor3 = Color3.fromRGB(40, 42, 54)
ClearChatBtn.Text = "清空對話"
ClearChatBtn.Font = Enum.Font.GothamMedium
ClearChatBtn.TextSize = 10
ClearChatBtn.TextColor3 = Color3.fromRGB(200, 205, 215)
ClearChatBtn.Parent = ControlSubRow
Instance.new("UICorner", ClearChatBtn).CornerRadius = UDim.new(0, 4)

ClearChatBtn.MouseButton1Click:Connect(function()
    local cur = getActiveSession()
    cur.messages = {}
    cur.history = {}
    saveSessionsToWorkspace()
    renderActiveSessionChat()
    ClearChatBtn.Text = "已清空"
    task.delay(1.2, function() ClearChatBtn.Text = "清空對話" end)
end)

local InputSubRow = Instance.new("Frame")
InputSubRow.Size = UDim2.new(1, -12, 0, 38)
InputSubRow.Position = UDim2.new(0, 6, 0, 28)
InputSubRow.BackgroundTransparency = 1
InputSubRow.Parent = BottomBar

local PromptInputBox = Instance.new("TextBox")
PromptInputBox.Size = UDim2.new(1, -85, 1, 0)
PromptInputBox.BackgroundColor3 = Color3.fromRGB(16, 17, 22)
PromptInputBox.TextColor3 = Color3.fromRGB(240, 240, 245)
PromptInputBox.PlaceholderText = "輸入指令 (例如: 走訪目標玩家並截獲 Remotes)..."
PromptInputBox.PlaceholderColor3 = Color3.fromRGB(120, 125, 140)
PromptInputBox.Font = Enum.Font.Gotham
PromptInputBox.TextSize = 12
PromptInputBox.Text = ""
PromptInputBox.ClearTextOnFocus = false
PromptInputBox.TextWrapped = true
PromptInputBox.Parent = InputSubRow
Instance.new("UICorner", PromptInputBox).CornerRadius = UDim.new(0, 6)

local SubmitBtn = Instance.new("TextButton")
SubmitBtn.Size = UDim2.new(0, 78, 1, 0)
SubmitBtn.Position = UDim2.new(1, -78, 0, 0)
SubmitBtn.BackgroundColor3 = Color3.fromRGB(50, 120, 240)
SubmitBtn.Text = "發送"
SubmitBtn.Font = Enum.Font.GothamBold
SubmitBtn.TextSize = 12
SubmitBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
SubmitBtn.Parent = InputSubRow
Instance.new("UICorner", SubmitBtn).CornerRadius = UDim.new(0, 6)

-- ==================== [ 15. 自主循環與執行調度引擎 (Agent Pipeline) ] ====================
local function resetBusyState()
    isBusy = false
    currentMainThread = nil
    currentCodeThread = nil
    SubmitBtn.Text = "發送"
    SubmitBtn.BackgroundColor3 = Color3.fromRGB(50, 120, 240)
    SubmitBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    if AgentLoopStatusBadge then
        AgentLoopStatusBadge.Text = "CodeAct: 就緒"
        AgentLoopStatusBadge.TextColor3 = Color3.fromRGB(120, 220, 255)
    end
    if StepBadge then
        StepBadge.Text = "輪次: 0"
    end
end

local function abortCurrentExecution(reason)
    currentExecutionId = currentExecutionId + 1
    if activeWebSocket then
        pcall(function()
            if activeWebSocket.Close then activeWebSocket:Close()
            elseif activeWebSocket.close then activeWebSocket:close() end
        end)
        activeWebSocket = nil
    end

    if currentCodeThread then
        pcall(task.cancel, currentCodeThread)
        currentCodeThread = nil
    end

    if currentMainThread then
        pcall(task.cancel, currentMainThread)
        currentMainThread = nil
    end

    local cur = getActiveSession()
    if #cur.messages > 0 and cur.messages[#cur.messages].role == "assistant" and (cur.messages[#cur.messages].status == "generating" or cur.messages[#cur.messages].status == "running") then
        cur.messages[#cur.messages].status = "error"
        cur.messages[#cur.messages].text = cur.messages[#cur.messages].text .. "\n\n[已中止] " .. tostring(reason or "已停止")
    end

    resetBusyState()
    renderActiveSessionChat()
    saveSessionsToWorkspace()
end

executeCodeAction = function(codeToRun)
    if isBusy then
        logWarn("Exec", "當前已有任務正在執行中...")
        return
    end

    currentExecutionId = currentExecutionId + 1
    local myExecId = currentExecutionId

    local cur = getActiveSession()
    local agentMsg = {
        role = "assistant",
        text = "[手動執行代碼]...",
        thinking = "",
        code = codeToRun,
        logs = {},
        status = "running",
        time = os.date("%H:%M:%S")
    }
    table.insert(cur.messages, agentMsg)
    renderActiveSessionChat()

    isBusy = true
    SubmitBtn.Text = "停止"
    SubmitBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
    SubmitBtn.TextColor3 = Color3.fromRGB(255, 255, 255)

    currentMainThread = task.spawn(function()
        local runOk, runErr, capturedLogs = executeCodeAct(codeToRun)
        if myExecId ~= currentExecutionId then return end
        agentMsg.status = runOk and "success" or "error"
        agentMsg.error = (not runOk) and runErr or nil
        agentMsg.logs = capturedLogs
        local outText = (#capturedLogs > 0 and table.concat(capturedLogs, "\n") or "(無 print 輸出)")
        agentMsg.observation = runOk and outText or string.format("代碼執行報錯:\n%s\n終端輸出:\n%s", tostring(runErr), outText)
        renderActiveSessionChat()
        saveSessionsToWorkspace()
        resetBusyState()
    end)
end

SubmitBtn.MouseButton1Click:Connect(function()
    if isBusy then
        logWarn("Core", "使用者請求停止執行...")
        abortCurrentExecution("已由使用者手動強制中止。")
        return
    end

    local prompt = PromptInputBox.Text
    if not prompt:match("%S") then
        return
    end

    local currentKey = CurrentApiKey:gsub("%s+", "")
    if currentKey == "" then
        SettingsModal.Visible = true
        return
    end

    PromptInputBox.Text = ""
    isBusy = true
    currentExecutionId = currentExecutionId + 1
    local myExecId = currentExecutionId

    SubmitBtn.Text = "停止"
    SubmitBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
    SubmitBtn.TextColor3 = Color3.fromRGB(255, 255, 255)

    local cur = getActiveSession()
    table.insert(cur.messages, {
        role = "user",
        text = prompt,
        time = os.date("%H:%M:%S")
    })
    renderActiveSessionChat()

    currentMainThread = task.spawn(function()
        table.insert(cur.history, {
            role = "user",
            parts = { { text = prompt } }
        })

        local turn = 1
        local loopDone = false
        local consecutiveErrors = 0

        while isBusy and not loopDone do
            if myExecId ~= currentExecutionId then return end

            -- 1. Auto-Compact 治理檢查：當歷史累積達到閾值時觸發記憶語意壓縮
            if Config.AUTO_COMPACT and #cur.history >= (tonumber(Config.COMPACT_THRESHOLD or 8) * 2) then
                compactSessionHistory(cur, CurrentApiKey, Config.MODEL)
                if myExecId ~= currentExecutionId or not isBusy then return end
            end

            if AgentLoopStatusBadge then
                local commTag = (Config.COMM_METHOD == "WebSocket") and "WS" or "HTTP"
                AgentLoopStatusBadge.Text = string.format("CodeAct 推理中 [%s] (第 %d 輪)", commTag, turn)
                AgentLoopStatusBadge.TextColor3 = Color3.fromRGB(120, 220, 255)
            end
            if StepBadge then
                StepBadge.Text = string.format("輪次: %d", turn)
            end

            local agentMsg = {
                role = "assistant",
                turn = turn,
                text = "",
                thinking = "",
                code = nil,
                observation = nil,
                logs = {},
                status = "generating",
                time = os.date("%H:%M:%S")
            }
            table.insert(cur.messages, agentMsg)
            renderActiveSessionChat()

            -- CodeAct 模式發起通信 (依設定選擇 HTTP 或 WebSocket)
            local success, reply, thinking, functionCalls, rawParts
            if Config.COMM_METHOD == "WebSocket" and wsConnect then
                success, reply, thinking = callGeminiWebSocket(CurrentApiKey, Config.MODEL, nil, cur)
                functionCalls = {}
                rawParts = {}
                -- WebSocket 失敗時自動降級回 HTTP (Automatic Fallback)
                if not success then
                    logWarn("COMM", "WebSocket 通信失敗，自動降級至 HTTP 模式: " .. tostring(reply))
                    success, reply, thinking, functionCalls, rawParts = callGeminiHTTP(CurrentApiKey, Config.MODEL, Config.THINK_LEVEL, nil, cur)
                end
            else
                success, reply, thinking, functionCalls, rawParts = callGeminiHTTP(CurrentApiKey, Config.MODEL, Config.THINK_LEVEL, nil, cur)
            end

            if myExecId ~= currentExecutionId or not isBusy then return end

            if not success then
                agentMsg.status = "error"
                agentMsg.text = "通信失敗: " .. tostring(reply)
                renderActiveSessionChat()
                break
            end

            agentMsg.text = reply or ""
            agentMsg.thinking = thinking or ""

            -- 記錄模型回覆到歷史
            table.insert(cur.history, {
                role = "model",
                parts = (rawParts and #rawParts > 0) and rawParts or { { text = reply } }
            })

            local luaCode = extractLuaCode(reply)

            if luaCode then
                agentMsg.code = luaCode
                cur.lastCode = luaCode

                if not Config.AUTO_EXECUTE then
                    agentMsg.status = "waiting_approval"
                    agentMsg.observation = "代碼已生成，等待手動審批執行 (可點擊代碼卡片上方的「▶️ 批准執行」，或在設定中開啟自動執行)"
                    if AgentLoopStatusBadge then
                        AgentLoopStatusBadge.Text = "⏳ 等待審批確認"
                        AgentLoopStatusBadge.TextColor3 = Color3.fromRGB(255, 180, 50)
                    end
                    renderActiveSessionChat()
                    loopDone = true
                else
                    agentMsg.status = "running"
                    if AgentLoopStatusBadge then
                        AgentLoopStatusBadge.Text = "⚡ 執行 Luau 代碼中..."
                        AgentLoopStatusBadge.TextColor3 = Color3.fromRGB(100, 255, 150)
                    end
                    renderActiveSessionChat()

                    local runOk, runErr, capturedLogs = executeCodeAct(luaCode)
                    if myExecId ~= currentExecutionId or not isBusy then return end

                    agentMsg.logs = capturedLogs
                    local outText = (#capturedLogs > 0 and table.concat(capturedLogs, "\n") or "(無 print 輸出)")

                    if runOk then
                        consecutiveErrors = 0
                        agentMsg.status = "success"
                        agentMsg.observation = outText
                        renderActiveSessionChat()

                        table.insert(cur.history, {
                            role = "user",
                            parts = { { text = string.format("[執行觀測 Observation]\n狀態: 成功\n終端輸出:\n%s", outText) } }
                        })
                    else
                        consecutiveErrors = consecutiveErrors + 1
                        agentMsg.status = "error"
                        agentMsg.error = runErr
                        agentMsg.observation = string.format("代碼執行報錯:\n%s\n終端輸出:\n%s", tostring(runErr), outText)
                        if AgentLoopStatusBadge then
                            AgentLoopStatusBadge.Text = "🩺 自愈修復中 (Reflexion)..."
                            AgentLoopStatusBadge.TextColor3 = Color3.fromRGB(255, 120, 120)
                        end
                        renderActiveSessionChat()

                        local repeatWarning = (consecutiveErrors >= 2) and string.format("\n⚠️ [警報] 此為連續第 %d 次執行出錯！請立即更換實例搜尋方式或調整 API 參數，切勿重複相同呼叫！", consecutiveErrors) or ""
                        local reflexPrompt = string.format([===[[直譯器原生報錯 / Runtime Traceback]
報錯訊息: %s
終端輸出:
%s%s

[Reflexion 自愈診斷指引]
直譯器捕獲上述異常堆疊。請在下一輪輸出中：
1. 在思考過程（Thinking）中診斷該報錯的確切根本原因。
2. 指明修正方案與禁忌路徑（不可重複相同的無效調用）。
3. 輸出修正後的完整 ```luau 代碼區塊以自愈推進。]===],
                            tostring(runErr),
                            outText,
                            repeatWarning
                        )

                        table.insert(cur.history, {
                            role = "user",
                            parts = { { text = reflexPrompt } }
                        })
                    end
                end
            else
                -- 無可執行代碼：純文本回覆或已完成回答
                agentMsg.status = "finished"
                renderActiveSessionChat()
                loopDone = true
            end

            -- 歷史長度防爆 (滑動窗口保護)
            while #cur.history > (Config.MAX_HISTORY * 2) do
                table.remove(cur.history, 1)
            end
            while #cur.history > 0 and cur.history[1].role ~= "user" do
                table.remove(cur.history, 1)
            end

            saveSessionsToWorkspace()
            turn = turn + 1
            task.wait(0.2)
            if myExecId ~= currentExecutionId or not isBusy then return end
        end


        if myExecId == currentExecutionId then
            saveSessionsToWorkspace()
            resetBusyState()
        end
    end)
end)

-- 初始渲染當前會話
renderActiveSessionChat()
