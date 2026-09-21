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

local guiParent = (gethui and gethui()) or (pcall(function() return game:GetService("CoreGui") end) and game:GetService("CoreGui")) or LocalPlayer:WaitForChild("PlayerGui")
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

local DEFAULT_SYSTEM_INSTRUCTION = [===[You are BloxAgent, an expert autonomous Luau reverse-engineer and exploit automation Agent running natively inside a high-privilege Roblox mobile/PC executor.
You operate with complete UNC (Unified Naming Convention) and Synapse X environment access.

================================================================================
1. EXECUTION ENVIRONMENT & GLOBAL CAPABILITIES
================================================================================
You have unrestricted access to standard Luau globals, UNC primitives, and built-in AgentEnv tooling:
- Built-in AgentEnv Utilities:
  * `AgentEnv.teleport(target)`: Teleport to Vector3, CFrame, or Player Name string.
  * `AgentEnv.walkTo(target, options)`: Native PathfindingService waypoints navigation. Target can be Vector3, CFrame, Instance (BasePart/Model), or Player Name.
  * `AgentEnv.startRemoteSpy(options)`: Intercepts and records FireServer/InvokeServer into `AgentEnv.RemoteLogs`.
  * `AgentEnv.stopRemoteSpy()`: Halts Remote Spy logging.
  * `AgentEnv.BlockedRemotes`: Table map (name or instance) to block outbound remote invocations.
  * `AgentEnv.inspectInstance(instance)`: Dynamic property, tag, and attribute inspector (Dex-style).
  * `AgentEnv.searchInstances(queryName, className, root)`: Deep instance search.
  * `AgentEnv.setNoclip(boolean)` / `AgentEnv.setPlayerProperty(prop, val)`.
- UNC & Synapse Hooking / Metatables:
  `getgenv()`, `getrenv()`, `getrawmetatable(tbl)`, `setrawmetatable(tbl, mt)`, `setreadonly(tbl, bool)`, `hookmetamethod(obj, method, hookFn)`, `hookfunction(old, new)`, `newcclosure(fn)`, `checkcaller()`, `getnamecallmethod()`.
- Reflection & Memory:
  `getgc(true)`, `getinstances()`, `getnilinstances()`, `getloadedmodules()`, `getupvalues(fn)`, `setupvalue(fn, idx, val)`.
- Signal & Input Triggers:
  `fireclickdetector(inst)`, `fireproximityprompt(inst)`, `firetouchinterest(part, toTouch, toggle)`, `getconnections(signal)` (`:Disable()`, `:Enable()`, `:Fire()`).
  `Drawing.new(type)`, `readfile(path)`, `writefile(path, data)`.

================================================================================
2. EXPLOIT DEVELOPMENT RULES & CODING PATTERNS
================================================================================
[A. Hooking Metamethods (__namecall / __index)]
- Always verify `if checkcaller() then return oldNamecall(self, ...) end` to prevent intercepting executor/agent operations.
- Always cache the original metamethod before hooking.

[B. Memory Scanning & GC Traversal]
- When locating hidden values (inventories, currencies, anti-cheat tokens):
  - Search `getgc(true)` for target keys or metatables.
  - Traverse `getloadedmodules()` and inspect via `require()` inside `pcall`.
  - Check `getnilinstances()` for anti-cheat instances, hidden remotes, or unparented assets.

[C. Connection Manipulation]
- Suppress anti-cheat listeners or input detectors using `getconnections(signal)` and call `:Disable()`.

[D. Safe Execution & Thread Safety]
- Never introduce infinite busy-wait loops (`while true do end`). Always use `task.wait()` or bind to `RunService.Heartbeat`.
- Wrap metatable property modifications with `setreadonly(mt, false)` and restore with `setreadonly(mt, true)`.

================================================================================
3. OUTPUT & FORMATTING MANDATE
================================================================================
1. MUST ALWAYS use `print(...)` to log discoveries, intercepted network payloads, inspected properties, and execution status.
2. Return ONLY the raw Luau executable script inside a single ```lua ... ``` markdown block.
3. No conversational preambles, apologies, or markdown outside the ```lua ... ``` block.]===]

local DEFAULT_CONFIG = {
    MODEL = "gemini-2.0-flash",
    THINK_LEVEL = "Medium",
    MAX_HISTORY = 8,
    AUTONOMOUS_MODE = true,
    MAX_AUTO_STEPS = 3,
    AUTO_EXECUTE = true,
    PC_TOGGLE_KEY = "RightControl",
    GUI_TRANSPARENCY = 0.05
}

local Config = table.clone(DEFAULT_CONFIG)
local CurrentApiKey = ""
local CurrentSystemPrompt = DEFAULT_SYSTEM_INSTRUCTION

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
        for k, v in pairs(val) do
            clean[tostring(k)] = sanitizeForJSON(v, (depth or 0) + 1, visited)
        end
        return clean
    elseif t == "Instance" then
        local ok, fullName = pcall(function() return val:GetFullName() end)
        return string.format("<%s> %s", val.ClassName, ok and fullName or val.Name)
    elseif t == "Vector3" or t == "CFrame" or t == "Color3" or t == "UDim2" or t == "UDim" or t == "Ray" or t == "BrickColor" then
        return tostring(val)
    elseif t == "function" or t == "thread" or t == "userdata" or t == "RBXScriptConnection" then
        return string.format("[%s]", t)
    else
        return val
    end
end

local function extractLuaCode(text)
    if not text or typeof(text) ~= "string" then return nil end
    local best = nil
    for codeBlock in text:gmatch("```lua%s*\n?(.-)%s*```") do
        if not best or #codeBlock > #best then
            best = codeBlock
        end
    end
    if not best then
        for codeBlock in text:gmatch("```%s*\n?(.-)%s*```") do
            if not best or #codeBlock > #best then
                best = codeBlock
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

    local payload = {
        Url = url,
        url = url,
        Method = method or "GET",
        method = method or "GET",
        Headers = headers or {},
        headers = headers or {},
        Body = body or "",
        body = body or ""
    }

    local ok, res = pcall(rawHttpRequest, payload)
    if not ok then
        return false, nil, tostring(res or "Executor 網路調用崩潰")
    end

    if typeof(res) ~= "table" then
        return false, nil, "Executor 請求回傳格式異常: " .. tostring(res)
    end

    local statusCode = res.StatusCode or res.statusCode or res.Status or res.status_code or res.status or 0
    local resBody = res.Body or res.body or ""
    local resHeaders = res.Headers or res.headers or {}

    return true, {
        StatusCode = tonumber(statusCode) or 0,
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

-- ==================== [ 5. AgentEnv 核心模組 ] ====================
local AgentEnv = {
    Logs = {},
    RemoteLogs = {},
    BlockedRemotes = {},
    RemoteSpyActive = false,
    NoclipActive = false,
}

function AgentEnv.heartbeat()
    lastWatchdogHeartbeat = os.clock()
end

function AgentEnv.searchInstances(queryName, className, root)
    root = root or workspace
    local matches = {}
    for _, inst in ipairs(root:GetDescendants()) do
        local matchName = (not queryName) or string.find(inst.Name:lower(), queryName:lower(), 1, true)
        local matchClass = (not className) or inst:IsA(className)
        if matchName and matchClass then
            table.insert(matches, inst:GetFullName())
            if #matches >= 40 then break end
        end
    end
    return matches
end

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
        for _, p in ipairs(Players:GetPlayers()) do
            if string.find(p.Name:lower(), target:lower(), 1, true) or (p.DisplayName and string.find(p.DisplayName:lower(), target:lower(), 1, true)) then
                if p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
                    targetCFrame = p.Character.HumanoidRootPart.CFrame + Vector3.new(0, 3, 0)
                    break
                end
            end
        end
        if not targetCFrame then return false, "未找到指定玩家" end
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
        for _, p in ipairs(Players:GetPlayers()) do
            if string.find(p.Name:lower(), target:lower(), 1, true) then
                if p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
                    destPos = p.Character.HumanoidRootPart.Position
                    break
                end
            end
        end
    end

    if not destPos then return false, "無法解析尋路目標" end

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

    if AgentEnv.RemoteSpyActive then
        local cleanArgs = sanitizeForJSON(args)
        local okFull, fullPath = pcall(function() return inst:GetFullName() end)
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
    if AgentEnv.RemoteSpyActive then return true, "Remote Spy 運作中" end

    -- 互斥原則：若支援 hookmetamethod，優先 hook __namecall，絕不重複 hook hookfunction 避免雙倍截獲
    if hasHookMetamethod and hasGetNamecallMethod then
        if not originalNamecall then
            local hookFn = safeNewcclosure(function(self, ...)
                if not AgentEnv.RemoteSpyActive then
                    return originalNamecall(self, ...)
                end
                if not safeCheckcaller() then
                    local method = getnamecallmethod()
                    if method == "FireServer" or method == "InvokeServer" then
                        if internalRecordRemote(self, method, {...}) then
                            return nil
                        end
                    end
                end
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
    elseif hasHookFunction then
        -- 僅在缺少 hookmetamethod 時使用 hookfunction 作為備用防線
        if not originalFireServer then
            dummyRemoteEvent = Instance.new("RemoteEvent")
            local hookEventFn = safeNewcclosure(function(self, ...)
                if not AgentEnv.RemoteSpyActive then
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
                if not AgentEnv.RemoteSpyActive then
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
    else
        logWarn("Hook", "當前 Executor 不支援任何 Hook 原語，Remote Spy 無法截獲網絡通訊")
        return false, "Executor 缺少 Hook 原語"
    end

    AgentEnv.RemoteSpyActive = true
    return true, "Remote Spy 攔截已啟動"
end

function AgentEnv.stopRemoteSpy()
    AgentEnv.RemoteSpyActive = false
    return true, "Remote Spy 已停止監聽 (零開銷旁路已啟用)"
end

function AgentEnv.inspectInstance(inst)
    if typeof(inst) ~= "Instance" then return nil, "目標非 Instance 物件" end

    local okFull, fullName = pcall(function() return inst:GetFullName() end)
    local okParent, parentName = pcall(function()
        if not inst.Parent then return "nil" end
        return inst.Parent:GetFullName()
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
    if hum and pcall(function() return hum[prop] end) then
        hum[prop] = value
        return true
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
                if part:IsA("BasePart") and (part.Name == "HumanoidRootPart" or part.Name == "UpperTorso" or part.Name == "LowerTorso" or part.Name == "Torso") then
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


-- ==================== [ 6. 通信層 (Gemini WebSocket & sUNC HTTP) ] ====================
local activeWebSocket = nil
local lastWatchdogHeartbeat = os.clock()

local function callGeminiWebSocket(apiKey, modelName, userPrompt, targetSession, onChunk)
    local cleanModel = (modelName:gsub("^models/", ""))
    local wsUrl = string.format(
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=%s",
        apiKey
    )

    logInfo("WS", "正在嘗試建立 WebSocket 雙向串流連線至: " .. cleanModel)

    local okConn, wsOrErr = pcall(function() return wsConnect(wsUrl) end)
    if not okConn or not wsOrErr then
        logWarn("WS", "WebSocket 連線建立失敗: " .. tostring(wsOrErr or "未知錯誤"))
        return false, "WebSocket 連線建立失敗: " .. tostring(wsOrErr or "未知錯誤")
    end
    local ws = wsOrErr
    activeWebSocket = ws
    logInfo("WS", "WebSocket 連線物件已創建，正在進行 Bidi 協議交握...")

    local setupPayload = {
        setup = {
            model = "models/" .. cleanModel,
            generationConfig = {
                responseModalities = { "TEXT" },
                temperature = 0.1
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

    local function handleIncomingMessage(rawMsg)
        local parseOk, data = pcall(HttpService.JSONDecode, HttpService, rawMsg)
        if not parseOk or typeof(data) ~= "table" then return end

        if data.setupComplete then
            logInfo("WS", "Bidi Setup 完成，發送用戶指令...")
            pcall(function() ws:Send(HttpService:JSONEncode(clientTurnPayload)) end)
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
        ws.OnMessage = handleIncomingMessage
        if ws.onmessage ~= nil then ws.onmessage = handleIncomingMessage end
    end

    if not bindWsEvent("OnClose", handleClose) and not bindWsEvent("Close", handleClose) then
        ws.OnClose = handleClose
        if ws.onclose ~= nil then ws.onclose = handleClose end
    end

    local sendOk, sendErr = pcall(function()
        ws:Send(HttpService:JSONEncode(setupPayload))
    end)

    if not sendOk then
        logError("WS", "握手請求發送失敗: " .. tostring(sendErr))
        pcall(function()
            if ws.Close then ws:Close()
            elseif ws.close then ws:close() end
        end)
        activeWebSocket = nil
        return false, "WebSocket 握手發送失敗: " .. tostring(sendErr)
    end

    local waitStart = os.clock()
    while not isFinished do
        if os.clock() - waitStart > 20 then
            streamError = "WebSocket 響應逾時 (20 秒無數據)"
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
    table.insert(contents, {
        role = "user",
        parts = { { text = userPrompt } }
    })

    local payload = {
        systemInstruction = { parts = { { text = CurrentSystemPrompt } } },
        contents = contents,
        generationConfig = { temperature = 0.1, maxOutputTokens = 8192 }
    }

    local encodedBody = safeJSONEncode(payload)
    if not encodedBody then
        return false, "請求 Payload JSON 編碼失敗", "", ""
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
        local errMsg = "sUNC 網路請求異常: " .. tostring(reqErr or "未知錯誤")
        logError("HTTP", errMsg)
        return false, errMsg, "", ""
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

        local finalErrMsg = string.format("HTTP 請求失敗 (狀態碼 %s)%s%s", tostring(statusCode or "中斷"), detailedMsg, friendlyHint)
        logError("HTTP", finalErrMsg)
        return false, finalErrMsg, "", ""
    end

    local data = safeJSONDecode(body)
    if not data or typeof(data) ~= "table" then
        logError("HTTP", "JSON 解析失敗: " .. tostring(body):sub(1, 100))
        return false, "伺服器返回非有效 JSON 格式", "", ""
    end

    local replyText = ""
    local thoughtText = ""

    if data.candidates and data.candidates[1] and data.candidates[1].content and data.candidates[1].content.parts then
        for _, part in ipairs(data.candidates[1].content.parts) do
            if part.thought == true then
                thoughtText = thoughtText .. (part.text or "")
            elseif part.text then
                replyText = replyText .. (part.text or "")
            end
        end
    end

    if replyText == "" and thoughtText == "" then
        logWarn("HTTP", "API 未回傳文本候選內容")
        return false, "API 未回傳有效內容 (可能觸發安全過濾或 Token 超限)", "", ""
    end

    logInfo("HTTP", string.format("HTTP 通信成功 (回覆長度: %d, 思考長度: %d)", #replyText, #thoughtText))
    return true, replyText, thoughtText
end

-- ==================== [ 7. 沙盒執行引擎與靜態死循環防禦 ] ====================
local isBusy = false
local currentMainThread = nil
local currentCodeThread = nil

local function checkDangerousLoops(code)
    if not code or typeof(code) ~= "string" then return true end
    for loopBlock in code:gmatch("while%s+true%s+do(.-)end") do
        if not loopBlock:find("wait", 1, true) and not loopBlock:find("Heartbeat", 1, true) and not loopBlock:find("Stepped", 1, true) and not loopBlock:find("heartbeat", 1, true) then
            return false, "檢測到未包含讓步 (Yield/task.wait) 的 while true 死循環，為防止 Roblox 凍結已阻止執行。"
        end
    end
    for loopBlock in code:gmatch("repeat(.-)until%s+false") do
        if not loopBlock:find("wait", 1, true) and not loopBlock:find("Heartbeat", 1, true) and not loopBlock:find("Stepped", 1, true) and not loopBlock:find("heartbeat", 1, true) then
            return false, "檢測到未包含讓步 (Yield/task.wait) 的 repeat until false 死循環，為防止 Roblox 凍結已阻止執行。"
        end
    end
    return true, nil
end

local function executeInSandbox(luaCode)
    local capturedLogs = {}
    local safeLoop, loopErr = checkDangerousLoops(luaCode)
    if not safeLoop then
        return false, loopErr, capturedLogs
    end

    local func, compileErr
    local okLoad, loadRes = pcall(loadstring, luaCode)
    if okLoad and type(loadRes) == "function" then
        func = loadRes
    else
        compileErr = tostring(loadRes or "語法解析失敗")
        return false, "代碼編譯失敗: " .. compileErr, capturedLogs
    end

    local wrappedTask = table.clone(task)
    local origTaskWait = task.wait
    wrappedTask.wait = function(...)
        AgentEnv.heartbeat()
        return origTaskWait(...)
    end

    local customEnv = {
        script = nil,
        task = wrappedTask,
        wait = function(...)
            AgentEnv.heartbeat()
            return task.wait(...)
        end,
        print = function(...)
            local str = {}
            for i = 1, select("#", ...) do
                local v = select(i, ...)
                str[i] = typeof(v) == "table" and (safeJSONEncode(sanitizeForJSON(v)) or tostring(v)) or tostring(v)
            end
            local line = table.concat(str, " ")
            table.insert(capturedLogs, line)
            logInfo("AgentPrint", line)
        end,
        AgentEnv = AgentEnv,
        LocalPlayer = LocalPlayer,
        Players = Players,
        game = game,
        workspace = workspace,
        RunService = RunService,
        HttpService = HttpService,
        PathfindingService = PathfindingService,
        CollectionService = CollectionService,
        UserInputService = UserInputService
    }

    setmetatable(customEnv, {
        __index = function(_, k)
            if k == "script" then return nil end
            return (getgenv and getgenv()[k]) or getfenv()[k]
        end,
        __newindex = function(t, k, v)
            rawset(t, k, v)
        end
    })

    pcall(setfenv, func, customEnv)

    local runOk, runErr = false, ""
    local finished = false
    lastWatchdogHeartbeat = os.clock()

    currentCodeThread = task.spawn(function()
        runOk, runErr = pcall(func)
        finished = true
    end)

    local TIMEOUT = 15
    while not finished do
        if os.clock() - lastWatchdogHeartbeat > TIMEOUT then
            if currentCodeThread then
                pcall(task.cancel, currentCodeThread)
                currentCodeThread = nil
            end
            runOk = false
            runErr = "代碼無響應超過 " .. tostring(TIMEOUT) .. " 秒 (看門狗強制中斷)"
            logWarn("Watchdog", runErr)
            break
        end
        task.wait(0.05)
    end

    currentCodeThread = nil
    return runOk, runErr, capturedLogs
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
SessionDrawerBtn.Text = "📁 會話"
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
        statusBadge.Text = "⏳ 生成中..."
        statusBadge.TextColor3 = Color3.fromRGB(255, 215, 0)
    elseif msg.status == "running" then
        statusBadge.Text = "⚡ 執行中..."
        statusBadge.TextColor3 = Color3.fromRGB(100, 200, 255)
    elseif msg.status == "success" then
        statusBadge.Text = "✓ 完成"
        statusBadge.TextColor3 = Color3.fromRGB(100, 255, 120)
    elseif msg.status == "error" then
        statusBadge.Text = "✗ 錯誤"
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
        thinkHeader.Text = string.format("  ▶ 🧠 思考鏈 (%d 字) [點擊展開]", #msg.thinking)
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
                and string.format("  ▼ 🧠 思考鏈 (%d 字) [點擊收起]", #msg.thinking)
                or string.format("  ▶ 🧠 思考鏈 (%d 字) [點擊展開]", #msg.thinking)
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
        cTitle.Text = "💻 Luau 腳本"
        cTitle.Font = Enum.Font.GothamBold
        cTitle.TextSize = 11
        cTitle.TextColor3 = Color3.fromRGB(140, 255, 170)
        cTitle.TextXAlignment = Enum.TextXAlignment.Left
        cTitle.Parent = codeHeader

        local copyBtn = Instance.new("TextButton")
        copyBtn.Size = UDim2.new(0, 60, 0, 20)
        copyBtn.Position = UDim2.new(1, -135, 0, 3)
        copyBtn.BackgroundColor3 = Color3.fromRGB(38, 42, 56)
        copyBtn.Text = "📋 複製"
        copyBtn.Font = Enum.Font.GothamMedium
        copyBtn.TextSize = 10
        copyBtn.TextColor3 = Color3.fromRGB(220, 220, 230)
        Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0, 4)
        copyBtn.Parent = codeHeader

        copyBtn.MouseButton1Click:Connect(function()
            if setclipboard then
                pcall(setclipboard, msg.code)
                copyBtn.Text = "✓ 已複製"
                task.delay(1.2, function() copyBtn.Text = "📋 複製" end)
            else
                copyBtn.Text = "無剪貼簿"
                task.delay(1.2, function() copyBtn.Text = "📋 複製" end)
            end
        end)

        local reRunBtn = Instance.new("TextButton")
        reRunBtn.Size = UDim2.new(0, 65, 0, 20)
        reRunBtn.Position = UDim2.new(1, -70, 0, 3)
        reRunBtn.BackgroundColor3 = Color3.fromRGB(30, 110, 60)
        reRunBtn.Text = "▶️ 執行"
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

    -- 5. 沙盒終端輸出 (Terminal console output)
    if (msg.logs and #msg.logs > 0) or msg.error then
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
        termHeader.Text = msg.error and "❌ 沙盒終端報錯" or "📋 沙盒終端輸出"
        termHeader.Font = Enum.Font.GothamBold
        termHeader.TextSize = 10
        termHeader.TextColor3 = msg.error and Color3.fromRGB(255, 100, 100) or Color3.fromRGB(100, 220, 255)
        termHeader.TextXAlignment = Enum.TextXAlignment.Left
        termHeader.Parent = termCard

        local logLines = {}
        if msg.error then
            table.insert(logLines, "[Error] " .. tostring(msg.error))
        end
        if msg.logs then
            for _, l in ipairs(msg.logs) do
                table.insert(logLines, l)
            end
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
        emptyText.Text = "👋 歡迎使用 BloxAgent 2.0！\n請在下方輸入指令（支援單次生成與自主修復循環）。"
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
DrawerTitle.Text = "📁 會話列表 (Sessions)"
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
NewSessBtn.Text = "➕ 新增"
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
        delBtn.Text = "🗑️"
        delBtn.TextSize = 11
        delBtn.ZIndex = 53
        delBtn.Parent = itemCard
        Instance.new("UICorner", delBtn).CornerRadius = UDim.new(0, 4)

        delBtn.MouseButton1Click:Connect(function()
            if #SessionManager.List <= 1 then
                delBtn.Text = "✗"
                task.delay(1.2, function() delBtn.Text = "🗑️" end)
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
CloseSetBtn.Text = "✓ 儲存並關閉"
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

-- 1. API 金鑰設定
makeSectionHeader("🔑 Google AI Studio API Key", 1)

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
makeSectionHeader("🤖 模型選擇 (Model Selection)", 3)

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

-- 3. 自主循環與修復次數
makeSectionHeader("⚡ 自主修復循環 (Autonomous Re-act Loop)", 6)

local AutoLoopRow = Instance.new("Frame")
AutoLoopRow.Size = UDim2.new(1, 0, 0, 28)
AutoLoopRow.BackgroundTransparency = 1
AutoLoopRow.LayoutOrder = 7
AutoLoopRow.ZIndex = 62
AutoLoopRow.Parent = SetScroll

local AutoLoopToggleBtn = Instance.new("TextButton")
AutoLoopToggleBtn.Size = UDim2.new(0.5, -4, 1, 0)
AutoLoopToggleBtn.BackgroundColor3 = Config.AUTONOMOUS_MODE and Color3.fromRGB(35, 140, 70) or Color3.fromRGB(50, 52, 65)
AutoLoopToggleBtn.Text = Config.AUTONOMOUS_MODE and "自主修復: 開啟 (On)" or "自主修復: 關閉 (Off)"
AutoLoopToggleBtn.Font = Enum.Font.GothamBold
AutoLoopToggleBtn.TextSize = 10
AutoLoopToggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
AutoLoopToggleBtn.ZIndex = 63
AutoLoopToggleBtn.Parent = AutoLoopRow
Instance.new("UICorner", AutoLoopToggleBtn).CornerRadius = UDim.new(0, 4)

local AutoExecBtn = Instance.new("TextButton")
AutoExecBtn.Size = UDim2.new(0.5, -4, 1, 0)
AutoExecBtn.Position = UDim2.new(0.5, 4, 0, 0)
AutoExecBtn.BackgroundColor3 = Config.AUTO_EXECUTE and Color3.fromRGB(30, 100, 150) or Color3.fromRGB(50, 52, 65)
AutoExecBtn.Text = Config.AUTO_EXECUTE and "代碼自動執行: 開" or "代碼自動執行: 關"
AutoExecBtn.Font = Enum.Font.GothamBold
AutoExecBtn.TextSize = 10
AutoExecBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
AutoExecBtn.ZIndex = 63
AutoExecBtn.Parent = AutoLoopRow
Instance.new("UICorner", AutoExecBtn).CornerRadius = UDim.new(0, 4)

AutoLoopToggleBtn.MouseButton1Click:Connect(function()
    Config.AUTONOMOUS_MODE = not Config.AUTONOMOUS_MODE
    AutoLoopToggleBtn.BackgroundColor3 = Config.AUTONOMOUS_MODE and Color3.fromRGB(35, 140, 70) or Color3.fromRGB(50, 52, 65)
    AutoLoopToggleBtn.Text = Config.AUTONOMOUS_MODE and "自主修復: 開啟 (On)" or "自主修復: 關閉 (Off)"
    saveConfig()
end)

AutoExecBtn.MouseButton1Click:Connect(function()
    Config.AUTO_EXECUTE = not Config.AUTO_EXECUTE
    AutoExecBtn.BackgroundColor3 = Config.AUTO_EXECUTE and Color3.fromRGB(30, 100, 150) or Color3.fromRGB(50, 52, 65)
    AutoExecBtn.Text = Config.AUTO_EXECUTE and "代碼自動執行: 開" or "代碼自動執行: 關"
    saveConfig()
end)

-- 4. 思考深度 (Think Level)
makeSectionHeader("🧠 思考深度 (Think Level)", 8)
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
makeSectionHeader("⌨️ PC 介面呼出快捷鍵 (PC Toggle Key)", 10)
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
makeSectionHeader("🎨 面板背景透明度 (Transparency)", 12)
local TransRow = Instance.new("Frame")
TransRow.Size = UDim2.new(1, 0, 0, 24)
TransRow.BackgroundTransparency = 1
TransRow.LayoutOrder = 13
TransRow.ZIndex = 62
TransRow.Parent = SetScroll

local TRANS_OPTS = { { label = "0% (純黑)", val = 0.0 }, { label = "10%", val = 0.1 }, { label = "20%", val = 0.2 }, { label = "30%", val = 0.3 } }
for idx, opt in ipairs(TRANS_OPTS) do
    local trBtn = Instance.new("TextButton")
    trBtn.Size = UDim2.new(0.24, -2, 1, 0)
    trBtn.Position = UDim2.new((idx - 1) * 0.25, 0, 0, 0)
    trBtn.BackgroundColor3 = Color3.fromRGB(35, 36, 46)
    trBtn.Text = opt.label
    trBtn.Font = Enum.Font.GothamMedium
    trBtn.TextSize = 9
    trBtn.TextColor3 = Color3.fromRGB(180, 185, 200)
    trBtn.ZIndex = 63
    trBtn.Parent = TransRow
    Instance.new("UICorner", trBtn).CornerRadius = UDim.new(0, 4)

    trBtn.MouseButton1Click:Connect(function()
        Config.GUI_TRANSPARENCY = opt.val
        MainFrame.BackgroundTransparency = opt.val
        saveConfig()
    end)
end

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

local AutoLoopToggleIndicator = Instance.new("TextButton")
AutoLoopToggleIndicator.Size = UDim2.new(0, 110, 1, 0)
AutoLoopToggleIndicator.BackgroundColor3 = Config.AUTONOMOUS_MODE and Color3.fromRGB(30, 90, 50) or Color3.fromRGB(45, 46, 56)
AutoLoopToggleIndicator.Text = Config.AUTONOMOUS_MODE and "⚡ 自主模式: 開" or "⚡ 自主模式: 關"
AutoLoopToggleIndicator.Font = Enum.Font.GothamBold
AutoLoopToggleIndicator.TextSize = 10
AutoLoopToggleIndicator.TextColor3 = Color3.fromRGB(240, 245, 255)
AutoLoopToggleIndicator.Parent = ControlSubRow
Instance.new("UICorner", AutoLoopToggleIndicator).CornerRadius = UDim.new(0, 4)

AutoLoopToggleIndicator.MouseButton1Click:Connect(function()
    Config.AUTONOMOUS_MODE = not Config.AUTONOMOUS_MODE
    AutoLoopToggleIndicator.BackgroundColor3 = Config.AUTONOMOUS_MODE and Color3.fromRGB(30, 90, 50) or Color3.fromRGB(45, 46, 56)
    AutoLoopToggleIndicator.Text = Config.AUTONOMOUS_MODE and "⚡ 自主模式: 開" or "⚡ 自主模式: 關"
    saveConfig()
end)

local ClearChatBtn = Instance.new("TextButton")
ClearChatBtn.Size = UDim2.new(0, 85, 1, 0)
ClearChatBtn.Position = UDim2.new(0, 116, 0, 0)
ClearChatBtn.BackgroundColor3 = Color3.fromRGB(40, 42, 54)
ClearChatBtn.Text = "🧹 清空對話"
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
    ClearChatBtn.Text = "✓ 已清空"
    task.delay(1.2, function() ClearChatBtn.Text = "🧹 清空對話" end)
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
SubmitBtn.Text = "發送 ↵"
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
    SubmitBtn.Text = "發送 ↵"
    SubmitBtn.BackgroundColor3 = Color3.fromRGB(50, 120, 240)
end

local function abortCurrentExecution(reason)
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
    if #cur.messages > 0 and cur.messages[#cur.messages].role == "assistant" and cur.messages[#cur.messages].status == "generating" then
        cur.messages[#cur.messages].status = "error"
        cur.messages[#cur.messages].text = cur.messages[#cur.messages].text .. "\n\n⚠️ " .. tostring(reason or "已停止")
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

    local cur = getActiveSession()
    local agentMsg = {
        role = "assistant",
        text = "▶️ 手動重新執行代碼...",
        thinking = "",
        code = codeToRun,
        logs = {},
        status = "running",
        time = os.date("%H:%M:%S")
    }
    table.insert(cur.messages, agentMsg)
    renderActiveSessionChat()

    isBusy = true
    SubmitBtn.Text = "⏹️ 停止"
    SubmitBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)

    currentMainThread = task.spawn(function()
        local runOk, runErr, capturedLogs = executeInSandbox(codeToRun)
        agentMsg.status = runOk and "success" or "error"
        agentMsg.error = (not runOk) and runErr or nil
        agentMsg.logs = capturedLogs
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
    SubmitBtn.Text = "⏹️ 停止"
    SubmitBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)

    local cur = getActiveSession()
    table.insert(cur.messages, {
        role = "user",
        text = prompt,
        time = os.date("%H:%M:%S")
    })
    renderActiveSessionChat()

    currentMainThread = task.spawn(function()
        local currentPrompt = prompt
        local maxSteps = Config.AUTONOMOUS_MODE and (Config.MAX_AUTO_STEPS or 3) or 1
        local step = 1

        while step <= maxSteps and isBusy do
            local agentMsg = {
                role = "assistant",
                text = "",
                thinking = "",
                code = nil,
                logs = {},
                status = "generating",
                time = os.date("%H:%M:%S")
            }
            table.insert(cur.messages, agentMsg)
            renderActiveSessionChat()

            local function onChunkUpdate(replyChunk, thinkChunk)
                agentMsg.text = replyChunk
                agentMsg.thinking = thinkChunk
            end

            local canUseWS = wsConnect and doesModelSupportBidiWS(Config.MODEL)
            local success, reply, thinking

            if canUseWS then
                success, reply, thinking = callGeminiWebSocket(CurrentApiKey, Config.MODEL, currentPrompt, cur, onChunkUpdate)
                if not success then
                    logWarn("Net", "WebSocket 失敗，切換 sUNC HTTP: " .. tostring(reply))
                    success, reply, thinking = callGeminiHTTP(CurrentApiKey, Config.MODEL, Config.THINK_LEVEL, currentPrompt, cur)
                end
            else
                success, reply, thinking = callGeminiHTTP(CurrentApiKey, Config.MODEL, Config.THINK_LEVEL, currentPrompt, cur)
            end

            if not isBusy then break end

            if not success then
                agentMsg.status = "error"
                agentMsg.text = "✗ 通信失敗: " .. tostring(reply)
                renderActiveSessionChat()
                break
            end

            agentMsg.text = reply or ""
            agentMsg.thinking = thinking or ""

            -- 更新 API 對話歷史
            table.insert(cur.history, { role = "user", parts = { { text = currentPrompt } } })
            table.insert(cur.history, { role = "model", parts = { { text = reply } } })
            while #cur.history > (Config.MAX_HISTORY * 2) do
                table.remove(cur.history, 1)
                if #cur.history > 0 then table.remove(cur.history, 1) end
            end

            local luaCode = extractLuaCode(reply)
            if luaCode then
                agentMsg.code = luaCode
                cur.lastCode = luaCode

                if Config.AUTO_EXECUTE then
                    agentMsg.status = "running"
                    renderActiveSessionChat()

                    local runOk, runErr, logs = executeInSandbox(luaCode)
                    agentMsg.status = runOk and "success" or "error"
                    agentMsg.error = (not runOk) and runErr or nil
                    agentMsg.logs = logs

                    renderActiveSessionChat()
                    saveSessionsToWorkspace()

                    if runOk then
                        -- 執行成功，自主任務達成
                        break
                    else
                        -- 執行報錯，檢查是否繼續自主循環修復
                        if Config.AUTONOMOUS_MODE and step < maxSteps and isBusy then
                            logInfo("AutoFix", string.format("自主循環第 %d 步報錯，自動觸發第 %d 步修復...", step, step + 1))
                            currentPrompt = string.format("[沙盒反饋: 執行失敗]\n錯誤原因: %s\n終端日誌:\n%s\n請檢視上述錯誤並輸出修正後的完整 Luau 代碼。", tostring(runErr), table.concat(logs, "\n"))
                            step = step + 1
                        else
                            break
                        end
                    end
                else
                    agentMsg.status = "success"
                    renderActiveSessionChat()
                    break
                end
            else
                agentMsg.status = "success"
                renderActiveSessionChat()
                break
            end
        end

        saveSessionsToWorkspace()
        resetBusyState()
    end)
end)

-- 初始渲染當前會話
renderActiveSessionChat()
