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
    MAX_HISTORY = 8
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
        table.insert(sanitizedList, {
            id = s.id,
            name = s.name,
            history = cleanHist,
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
        lastOutput = "[BloxAgent] 新會話已就緒。支援 WebSocket 雙向流式響應與自動 HTTP 容災。",
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

-- ==================== [ 6. UI 介面構建 ] ====================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "BloxAgent_Framework"
ScreenGui.ResetOnSpawn = false
ScreenGui.Parent = guiParent

local FloatButton = Instance.new("TextButton")
FloatButton.Name = "FloatToggle"
FloatButton.Size = UDim2.new(0, 42, 0, 42)
FloatButton.Position = UDim2.new(0.04, 0, 0.22, 0)
FloatButton.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
FloatButton.Text = "🤖"
FloatButton.TextSize = 20
FloatButton.Active = true
FloatButton.Parent = ScreenGui
Instance.new("UICorner", FloatButton).CornerRadius = UDim.new(1, 0)

local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(0, 375, 0, 380)
MainFrame.Position = UDim2.new(0.5, -187, 0.16, 0)
MainFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Visible = true
MainFrame.Parent = ScreenGui
Instance.new("UICorner", MainFrame).CornerRadius = UDim.new(0, 10)

local function enableDrag(dragHandle, frame, onClick)
    local dragging = false
    local dragInput, dragStart, startPos
    local totalDragDist = 0

    dragHandle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            totalDragDist = 0
            dragStart = input.Position
            startPos = frame.Position

            local inputChangedConn
            inputChangedConn = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    if inputChangedConn then
                        inputChangedConn:Disconnect()
                        inputChangedConn = nil
                    end
                    if totalDragDist < 8 and onClick then
                        onClick()
                    end
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
            totalDragDist = totalDragDist + delta.Magnitude
            frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

enableDrag(FloatButton, FloatButton, function()
    MainFrame.Visible = not MainFrame.Visible
end)

local Header = Instance.new("Frame")
Header.Size = UDim2.new(1, 0, 0, 32)
Header.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
Header.BorderSizePixel = 0
Header.Parent = MainFrame
enableDrag(Header, MainFrame, nil)
Instance.new("UICorner", Header).CornerRadius = UDim.new(0, 10)

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -70, 1, 0)
Title.Position = UDim2.new(0, 10, 0, 0)
Title.Text = "BloxAgent Pro (Direct AI Studio)"
Title.TextColor3 = Color3.fromRGB(255, 255, 255)
Title.Font = Enum.Font.GothamBold
Title.TextSize = 13
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.BackgroundTransparency = 1
Title.Parent = Header

local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(0, 24, 0, 24)
CloseBtn.Position = UDim2.new(1, -28, 0, 4)
CloseBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
CloseBtn.Text = "✕"
CloseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.TextSize = 11
CloseBtn.Parent = Header
Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(0, 6)
CloseBtn.MouseButton1Click:Connect(function() MainFrame.Visible = false end)

local KeyInputBox = Instance.new("TextBox")
KeyInputBox.Size = UDim2.new(1, -20, 0, 24)
KeyInputBox.Position = UDim2.new(0, 10, 0, 38)
KeyInputBox.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
KeyInputBox.TextColor3 = Color3.fromRGB(120, 220, 255)
KeyInputBox.PlaceholderText = "Google AI Studio API Key..."
KeyInputBox.PlaceholderColor3 = Color3.fromRGB(120, 120, 130)
KeyInputBox.ClearTextOnFocus = false
KeyInputBox.Font = Enum.Font.Code
KeyInputBox.TextSize = 11
KeyInputBox.Text = CurrentApiKey
KeyInputBox.Parent = MainFrame
Instance.new("UICorner", KeyInputBox).CornerRadius = UDim.new(0, 6)

local ModelInputBox = Instance.new("TextBox")
ModelInputBox.Size = UDim2.new(0.55, -10, 0, 24)
ModelInputBox.Position = UDim2.new(0, 10, 0, 66)
ModelInputBox.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
ModelInputBox.TextColor3 = Color3.fromRGB(255, 215, 0)
ModelInputBox.PlaceholderText = "Model (gemini-2.0-flash)"
ModelInputBox.PlaceholderColor3 = Color3.fromRGB(120, 120, 130)
ModelInputBox.ClearTextOnFocus = false
ModelInputBox.Font = Enum.Font.Code
ModelInputBox.TextSize = 11
ModelInputBox.Text = Config.MODEL
ModelInputBox.Parent = MainFrame
Instance.new("UICorner", ModelInputBox).CornerRadius = UDim.new(0, 6)

local THINK_LEVELS = {
    { label = "Think: Off",    val = "Off" },
    { label = "Think: Low",    val = "Low" },
    { label = "Think: Medium", val = "Medium" },
    { label = "Think: High",   val = "High" }
}

local DropdownBtn = Instance.new("TextButton")
DropdownBtn.Size = UDim2.new(0.45, -10, 0, 24)
DropdownBtn.Position = UDim2.new(0.55, 5, 0, 66)
DropdownBtn.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
DropdownBtn.TextColor3 = Color3.fromRGB(150, 255, 150)
DropdownBtn.Font = Enum.Font.GothamMedium
DropdownBtn.TextSize = 11
DropdownBtn.Text = "Think: " .. tostring(Config.THINK_LEVEL)
DropdownBtn.Parent = MainFrame
Instance.new("UICorner", DropdownBtn).CornerRadius = UDim.new(0, 6)

local DropdownList = Instance.new("Frame")
DropdownList.Size = UDim2.new(0.45, -10, 0, #THINK_LEVELS * 24)
DropdownList.Position = UDim2.new(0.55, 5, 0, 92)
DropdownList.BackgroundColor3 = Color3.fromRGB(26, 26, 32)
DropdownList.BorderSizePixel = 0
DropdownList.ZIndex = 30
DropdownList.Visible = false
DropdownList.Parent = MainFrame
Instance.new("UICorner", DropdownList).CornerRadius = UDim.new(0, 6)

local DropdownLayout = Instance.new("UIListLayout")
DropdownLayout.SortOrder = Enum.SortOrder.LayoutOrder
DropdownLayout.Parent = DropdownList

for _, item in ipairs(THINK_LEVELS) do
    local ItemBtn = Instance.new("TextButton")
    ItemBtn.Size = UDim2.new(1, 0, 0, 24)
    ItemBtn.BackgroundColor3 = Color3.fromRGB(26, 26, 32)
    ItemBtn.TextColor3 = (item.val == "Off" and Color3.fromRGB(180, 180, 180) or Color3.fromRGB(150, 255, 150))
    ItemBtn.Font = Enum.Font.Gotham
    ItemBtn.TextSize = 11
    ItemBtn.Text = item.label
    ItemBtn.ZIndex = 31
    ItemBtn.Parent = DropdownList

    ItemBtn.MouseButton1Click:Connect(function()
        Config.THINK_LEVEL = item.val
        DropdownBtn.Text = item.label
        DropdownList.Visible = false
        saveConfig()
    end)
end

DropdownBtn.MouseButton1Click:Connect(function()
    DropdownList.Visible = not DropdownList.Visible
end)

local PromptInputBox = Instance.new("TextBox")
PromptInputBox.Size = UDim2.new(1, -20, 0, 38)
PromptInputBox.Position = UDim2.new(0, 10, 0, 94)
PromptInputBox.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
PromptInputBox.TextColor3 = Color3.fromRGB(240, 240, 240)
PromptInputBox.PlaceholderText = "輸入指令 (例如: 啟動 Remote Spy 並走訪目標玩家)..."
PromptInputBox.TextWrapped = true
PromptInputBox.ClearTextOnFocus = false
PromptInputBox.Font = Enum.Font.Gotham
PromptInputBox.TextSize = 12
PromptInputBox.Text = ""
PromptInputBox.Parent = MainFrame
Instance.new("UICorner", PromptInputBox).CornerRadius = UDim.new(0, 6)

local SubmitBtn = Instance.new("TextButton")
SubmitBtn.Size = UDim2.new(1, -20, 0, 28)
SubmitBtn.Position = UDim2.new(0, 10, 0, 136)
SubmitBtn.BackgroundColor3 = Color3.fromRGB(0, 130, 250)
SubmitBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
SubmitBtn.Text = "發送並執行 (Execute)"
SubmitBtn.Font = Enum.Font.GothamBold
SubmitBtn.TextSize = 12
SubmitBtn.Parent = MainFrame
Instance.new("UICorner", SubmitBtn).CornerRadius = UDim.new(0, 6)

-- ==================== [ 7. 4-Tab 導覽系統 ] ====================
local TabBar = Instance.new("Frame")
TabBar.Size = UDim2.new(1, -20, 0, 24)
TabBar.Position = UDim2.new(0, 10, 0, 168)
TabBar.BackgroundColor3 = Color3.fromRGB(26, 26, 32)
TabBar.BorderSizePixel = 0
TabBar.Parent = MainFrame
Instance.new("UICorner", TabBar).CornerRadius = UDim.new(0, 6)

local TabOutputBtn = Instance.new("TextButton")
TabOutputBtn.Size = UDim2.new(0.25, 0, 1, 0)
TabOutputBtn.Position = UDim2.new(0, 0, 0, 0)
TabOutputBtn.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
TabOutputBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
TabOutputBtn.Text = "📋 結果"
TabOutputBtn.Font = Enum.Font.GothamBold
TabOutputBtn.TextSize = 11
TabOutputBtn.Parent = TabBar

local TabCodeBtn = Instance.new("TextButton")
TabCodeBtn.Size = UDim2.new(0.25, 0, 1, 0)
TabCodeBtn.Position = UDim2.new(0.25, 0, 0, 0)
TabCodeBtn.BackgroundColor3 = Color3.fromRGB(26, 26, 32)
TabCodeBtn.TextColor3 = Color3.fromRGB(160, 160, 170)
TabCodeBtn.Text = "💻 代碼"
TabCodeBtn.Font = Enum.Font.Gotham
TabCodeBtn.TextSize = 11
TabCodeBtn.Parent = TabBar

local TabSessionsBtn = Instance.new("TextButton")
TabSessionsBtn.Size = UDim2.new(0.25, 0, 1, 0)
TabSessionsBtn.Position = UDim2.new(0.50, 0, 0, 0)
TabSessionsBtn.BackgroundColor3 = Color3.fromRGB(26, 26, 32)
TabSessionsBtn.TextColor3 = Color3.fromRGB(160, 160, 170)
TabSessionsBtn.Text = "📂 會話"
TabSessionsBtn.Font = Enum.Font.Gotham
TabSessionsBtn.TextSize = 11
TabSessionsBtn.Parent = TabBar

local TabPromptBtn = Instance.new("TextButton")
TabPromptBtn.Size = UDim2.new(0.25, 0, 1, 0)
TabPromptBtn.Position = UDim2.new(0.75, 0, 0, 0)
TabPromptBtn.BackgroundColor3 = Color3.fromRGB(26, 26, 32)
TabPromptBtn.TextColor3 = Color3.fromRGB(160, 160, 170)
TabPromptBtn.Text = "⚙️ 提示詞"
TabPromptBtn.Font = Enum.Font.Gotham
TabPromptBtn.TextSize = 11
TabPromptBtn.Parent = TabBar

-- ==================== [ 8. 滾動排版與節流控制器 ] ====================
local function setupTextServiceScrolling(scrollFrame, textObject, paddingBottom)
    paddingBottom = paddingBottom or 25
    scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.None
    scrollFrame.ElasticBehavior = Enum.ElasticBehavior.Always
    scrollFrame.ScrollingDirection = Enum.ScrollingDirection.Y
    scrollFrame.ScrollBarThickness = 5
    scrollFrame.ScrollBarImageColor3 = Color3.fromRGB(120, 120, 140)
    scrollFrame.CanvasPosition = Vector2.new(0, 0)

    local function refreshCanvas(autoScrollToBottom)
        local text = textObject.Text
        if not text or text == "" then
            textObject.Size = UDim2.new(1, -12, 0, 24)
            scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 30)
            return
        end

        local containerWidth = scrollFrame.AbsoluteSize.X - 16
        if containerWidth <= 10 then containerWidth = 330 end

        local calculatedSize = TextService:GetTextSize(
            text,
            textObject.TextSize,
            textObject.Font,
            Vector2.new(containerWidth, 100000)
        )

        local finalHeight = math.max(calculatedSize.Y, 24)
        textObject.Size = UDim2.new(1, -12, 0, finalHeight)
        scrollFrame.CanvasSize = UDim2.new(0, 0, 0, finalHeight + paddingBottom)

        if autoScrollToBottom then
            scrollFrame.CanvasPosition = Vector2.new(0, math.max(0, finalHeight + paddingBottom - scrollFrame.AbsoluteSize.Y))
        end
    end

    scrollFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
        refreshCanvas(false)
    end)

    return refreshCanvas
end

local DisplayScroll = Instance.new("ScrollingFrame")
DisplayScroll.Size = UDim2.new(1, -20, 0, 175)
DisplayScroll.Position = UDim2.new(0, 10, 0, 196)
DisplayScroll.BackgroundColor3 = Color3.fromRGB(12, 12, 16)
DisplayScroll.BorderSizePixel = 0
DisplayScroll.Visible = true
DisplayScroll.Parent = MainFrame
Instance.new("UICorner", DisplayScroll).CornerRadius = UDim.new(0, 6)

local ContentLabel = Instance.new("TextLabel")
ContentLabel.Size = UDim2.new(1, -12, 0, 24)
ContentLabel.Position = UDim2.new(0, 6, 0, 6)
ContentLabel.BackgroundTransparency = 1
ContentLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
ContentLabel.Font = Enum.Font.Code
ContentLabel.TextSize = 11
ContentLabel.TextWrapped = true
ContentLabel.TextTruncate = Enum.TextTruncate.None
ContentLabel.TextXAlignment = Enum.TextXAlignment.Left
ContentLabel.TextYAlignment = Enum.TextYAlignment.Top
ContentLabel.Text = getActiveSession().lastOutput
ContentLabel.Parent = DisplayScroll

local syncDisplayScroll = setupTextServiceScrolling(DisplayScroll, ContentLabel, 25)

local SessionsContainer = Instance.new("Frame")
SessionsContainer.Size = UDim2.new(1, -20, 0, 175)
SessionsContainer.Position = UDim2.new(0, 10, 0, 196)
SessionsContainer.BackgroundTransparency = 1
SessionsContainer.Visible = false
SessionsContainer.Parent = MainFrame

local SessionActionFrame = Instance.new("Frame")
SessionActionFrame.Size = UDim2.new(1, 0, 0, 24)
SessionActionFrame.Position = UDim2.new(0, 0, 0, 0)
SessionActionFrame.BackgroundTransparency = 1
SessionActionFrame.Parent = SessionsContainer

local NewSessionBtn = Instance.new("TextButton")
NewSessionBtn.Size = UDim2.new(0.33, -2, 1, 0)
NewSessionBtn.Position = UDim2.new(0, 0, 0, 0)
NewSessionBtn.BackgroundColor3 = Color3.fromRGB(35, 140, 70)
NewSessionBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
NewSessionBtn.Text = "➕ 新增會話"
NewSessionBtn.Font = Enum.Font.GothamBold
NewSessionBtn.TextSize = 11
NewSessionBtn.Parent = SessionActionFrame
Instance.new("UICorner", NewSessionBtn).CornerRadius = UDim.new(0, 4)

local ClearHistBtn = Instance.new("TextButton")
ClearHistBtn.Size = UDim2.new(0.33, -2, 1, 0)
ClearHistBtn.Position = UDim2.new(0.33, 2, 0, 0)
ClearHistBtn.BackgroundColor3 = Color3.fromRGB(180, 120, 30)
ClearHistBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
ClearHistBtn.Text = "🧹 清空記憶"
ClearHistBtn.Font = Enum.Font.GothamBold
ClearHistBtn.TextSize = 11
ClearHistBtn.Parent = SessionActionFrame
Instance.new("UICorner", ClearHistBtn).CornerRadius = UDim.new(0, 4)

local DelSessionBtn = Instance.new("TextButton")
DelSessionBtn.Size = UDim2.new(0.34, -2, 1, 0)
DelSessionBtn.Position = UDim2.new(0.66, 4, 0, 0)
DelSessionBtn.BackgroundColor3 = Color3.fromRGB(160, 40, 40)
DelSessionBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
DelSessionBtn.Text = "🗑️ 刪除會話"
DelSessionBtn.Font = Enum.Font.GothamBold
DelSessionBtn.TextSize = 11
DelSessionBtn.Parent = SessionActionFrame
Instance.new("UICorner", DelSessionBtn).CornerRadius = UDim.new(0, 4)

local SessionListScroll = Instance.new("ScrollingFrame")
SessionListScroll.Size = UDim2.new(1, 0, 1, -30)
SessionListScroll.Position = UDim2.new(0, 0, 0, 30)
SessionListScroll.BackgroundColor3 = Color3.fromRGB(12, 12, 16)
SessionListScroll.BorderSizePixel = 0
SessionListScroll.ScrollBarThickness = 4
SessionListScroll.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 120)
SessionListScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
SessionListScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
SessionListScroll.ElasticBehavior = Enum.ElasticBehavior.Always
SessionListScroll.Parent = SessionsContainer
Instance.new("UICorner", SessionListScroll).CornerRadius = UDim.new(0, 6)

local SessionListLayout = Instance.new("UIListLayout")
SessionListLayout.SortOrder = Enum.SortOrder.LayoutOrder
SessionListLayout.Padding = UDim.new(0, 4)
SessionListLayout.Parent = SessionListScroll

local PromptEditorContainer = Instance.new("Frame")
PromptEditorContainer.Size = UDim2.new(1, -20, 0, 175)
PromptEditorContainer.Position = UDim2.new(0, 10, 0, 196)
PromptEditorContainer.BackgroundTransparency = 1
PromptEditorContainer.Visible = false
PromptEditorContainer.Parent = MainFrame

local PromptScroll = Instance.new("ScrollingFrame")
PromptScroll.Size = UDim2.new(1, 0, 1, -28)
PromptScroll.Position = UDim2.new(0, 0, 0, 0)
PromptScroll.BackgroundColor3 = Color3.fromRGB(12, 12, 16)
PromptScroll.BorderSizePixel = 0
PromptScroll.Parent = PromptEditorContainer
Instance.new("UICorner", PromptScroll).CornerRadius = UDim.new(0, 6)

local PromptEditBox = Instance.new("TextBox")
PromptEditBox.Size = UDim2.new(1, -12, 0, 24)
PromptEditBox.Position = UDim2.new(0, 6, 0, 6)
PromptEditBox.BackgroundTransparency = 1
PromptEditBox.TextColor3 = Color3.fromRGB(240, 240, 240)
PromptEditBox.Font = Enum.Font.Code
PromptEditBox.TextSize = 10
PromptEditBox.ClearTextOnFocus = false
PromptEditBox.MultiLine = true
PromptEditBox.TextWrapped = true
PromptEditBox.TextTruncate = Enum.TextTruncate.None
PromptEditBox.TextXAlignment = Enum.TextXAlignment.Left
PromptEditBox.TextYAlignment = Enum.TextYAlignment.Top
PromptEditBox.Text = CurrentSystemPrompt
PromptEditBox.Parent = PromptScroll

local syncPromptScroll = setupTextServiceScrolling(PromptScroll, PromptEditBox, 35)
PromptEditBox:GetPropertyChangedSignal("Text"):Connect(function()
    syncPromptScroll(false)
end)

local PromptActionFrame = Instance.new("Frame")
PromptActionFrame.Size = UDim2.new(1, 0, 0, 24)
PromptActionFrame.Position = UDim2.new(0, 0, 1, -24)
PromptActionFrame.BackgroundTransparency = 1
PromptActionFrame.Parent = PromptEditorContainer

local SavePromptBtn = Instance.new("TextButton")
SavePromptBtn.Size = UDim2.new(0.5, -4, 1, 0)
SavePromptBtn.Position = UDim2.new(0, 0, 0, 0)
SavePromptBtn.BackgroundColor3 = Color3.fromRGB(35, 140, 70)
SavePromptBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
SavePromptBtn.Text = "💾 儲存修改"
SavePromptBtn.Font = Enum.Font.GothamBold
SavePromptBtn.TextSize = 11
SavePromptBtn.Parent = PromptActionFrame
Instance.new("UICorner", SavePromptBtn).CornerRadius = UDim.new(0, 4)

local ResetPromptBtn = Instance.new("TextButton")
ResetPromptBtn.Size = UDim2.new(0.5, -4, 1, 0)
ResetPromptBtn.Position = UDim2.new(0.5, 4, 0, 0)
ResetPromptBtn.BackgroundColor3 = Color3.fromRGB(150, 40, 40)
ResetPromptBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
ResetPromptBtn.Text = "🔄 還原預設"
ResetPromptBtn.Font = Enum.Font.GothamBold
ResetPromptBtn.TextSize = 11
ResetPromptBtn.Parent = PromptActionFrame
Instance.new("UICorner", ResetPromptBtn).CornerRadius = UDim.new(0, 4)

-- ==================== [ 9. Tab 切換與視圖管理 ] ====================
local CurrentView = "OUTPUT"
local renderSessionList

local function switchTab(viewName)
    CurrentView = viewName
    local activeSession = getActiveSession()

    TabOutputBtn.BackgroundColor3 = (viewName == "OUTPUT" and Color3.fromRGB(45, 45, 55) or Color3.fromRGB(26, 26, 32))
    TabOutputBtn.TextColor3 = (viewName == "OUTPUT" and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(160, 160, 170))

    TabCodeBtn.BackgroundColor3 = (viewName == "CODE" and Color3.fromRGB(45, 45, 55) or Color3.fromRGB(26, 26, 32))
    TabCodeBtn.TextColor3 = (viewName == "CODE" and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(160, 160, 170))

    TabSessionsBtn.BackgroundColor3 = (viewName == "SESSIONS" and Color3.fromRGB(45, 45, 55) or Color3.fromRGB(26, 26, 32))
    TabSessionsBtn.TextColor3 = (viewName == "SESSIONS" and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(160, 160, 170))

    TabPromptBtn.BackgroundColor3 = (viewName == "PROMPT" and Color3.fromRGB(45, 45, 55) or Color3.fromRGB(26, 26, 32))
    TabPromptBtn.TextColor3 = (viewName == "PROMPT" and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(160, 160, 170))

    if viewName == "OUTPUT" then
        DisplayScroll.Visible = true
        SessionsContainer.Visible = false
        PromptEditorContainer.Visible = false
        ContentLabel.Text = activeSession.lastOutput
        ContentLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
        syncDisplayScroll(false)
    elseif viewName == "CODE" then
        DisplayScroll.Visible = true
        SessionsContainer.Visible = false
        PromptEditorContainer.Visible = false
        ContentLabel.Text = activeSession.lastCode or "-- 尚未生成代碼"
        ContentLabel.TextColor3 = Color3.fromRGB(140, 255, 170)
        syncDisplayScroll(false)
    elseif viewName == "SESSIONS" then
        DisplayScroll.Visible = false
        SessionsContainer.Visible = true
        PromptEditorContainer.Visible = false
        renderSessionList()
    elseif viewName == "PROMPT" then
        DisplayScroll.Visible = false
        SessionsContainer.Visible = false
        PromptEditorContainer.Visible = true
        syncPromptScroll(false)
    end
end

renderSessionList = function()
    for _, item in ipairs(SessionListScroll:GetChildren()) do
        if item:IsA("Frame") then item:Destroy() end
    end

    for _, sess in ipairs(SessionManager.List) do
        local isCurrent = (sess.id == SessionManager.ActiveId)

        local ItemCard = Instance.new("Frame")
        ItemCard.Size = UDim2.new(1, -6, 0, 36)
        ItemCard.BackgroundColor3 = isCurrent and Color3.fromRGB(34, 40, 52) or Color3.fromRGB(22, 22, 28)
        ItemCard.BorderSizePixel = 0
        ItemCard.Parent = SessionListScroll
        Instance.new("UICorner", ItemCard).CornerRadius = UDim.new(0, 4)

        local NameLabel = Instance.new("TextLabel")
        NameLabel.Size = UDim2.new(0.68, -8, 1, 0)
        NameLabel.Position = UDim2.new(0, 8, 0, 0)
        NameLabel.BackgroundTransparency = 1
        NameLabel.Text = string.format("%s (%d輪記憶)", sess.name, math.floor(#sess.history / 2))
        NameLabel.TextColor3 = isCurrent and Color3.fromRGB(100, 200, 255) or Color3.fromRGB(200, 200, 200)
        NameLabel.Font = isCurrent and Enum.Font.GothamBold or Enum.Font.Gotham
        NameLabel.TextSize = 11
        NameLabel.TextXAlignment = Enum.TextXAlignment.Left
        NameLabel.Parent = ItemCard

        local ActionBtn = Instance.new("TextButton")
        ActionBtn.Size = UDim2.new(0.30, -6, 0, 24)
        ActionBtn.Position = UDim2.new(0.70, 0, 0.5, -12)
        ActionBtn.BackgroundColor3 = isCurrent and Color3.fromRGB(30, 100, 50) or Color3.fromRGB(45, 45, 55)
        ActionBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        ActionBtn.Text = isCurrent and "✓ 啟用中" or "切換"
        ActionBtn.Font = Enum.Font.GothamMedium
        ActionBtn.TextSize = 10
        ActionBtn.Parent = ItemCard
        Instance.new("UICorner", ActionBtn).CornerRadius = UDim.new(0, 4)

        ActionBtn.MouseButton1Click:Connect(function()
            if not isCurrent then
                SessionManager.ActiveId = sess.id
                saveSessionsToWorkspace()
                renderSessionList()
            end
        end)
    end
end

TabOutputBtn.MouseButton1Click:Connect(function() switchTab("OUTPUT") end)
TabCodeBtn.MouseButton1Click:Connect(function() switchTab("CODE") end)
TabSessionsBtn.MouseButton1Click:Connect(function() switchTab("SESSIONS") end)
TabPromptBtn.MouseButton1Click:Connect(function() switchTab("PROMPT") end)

NewSessionBtn.MouseButton1Click:Connect(function()
    createNewSession()
    renderSessionList()
end)

ClearHistBtn.MouseButton1Click:Connect(function()
    local cur = getActiveSession()
    cur.history = {}
    cur.lastOutput = "[BloxAgent] 當前會話記憶已清空。"
    saveSessionsToWorkspace()
    renderSessionList()
    ClearHistBtn.Text = "✓ 已清空"
    task.delay(1.2, function() ClearHistBtn.Text = "🧹 清空記憶" end)
end)

DelSessionBtn.MouseButton1Click:Connect(function()
    if #SessionManager.List <= 1 then
        DelSessionBtn.Text = "✗ 需保留一個"
        task.delay(1.2, function() DelSessionBtn.Text = "🗑️ 刪除會話" end)
        return
    end

    for i, s in ipairs(SessionManager.List) do
        if s.id == SessionManager.ActiveId then
            table.remove(SessionManager.List, i)
            break
        end
    end

    SessionManager.ActiveId = SessionManager.List[1].id
    saveSessionsToWorkspace()
    renderSessionList()
end)

SavePromptBtn.MouseButton1Click:Connect(function()
    CurrentSystemPrompt = PromptEditBox.Text
    savePrompt(CurrentSystemPrompt)
    SavePromptBtn.Text = "✓ 已儲存！"
    task.delay(1.5, function() SavePromptBtn.Text = "💾 儲存修改" end)
end)

ResetPromptBtn.MouseButton1Click:Connect(function()
    CurrentSystemPrompt = DEFAULT_SYSTEM_INSTRUCTION
    PromptEditBox.Text = DEFAULT_SYSTEM_INSTRUCTION
    savePrompt(CurrentSystemPrompt)
    ResetPromptBtn.Text = "✓ 已重設！"
    task.delay(1.5, function() ResetPromptBtn.Text = "🔄 還原預設" end)
end)

-- ==================== [ 10. 通信層 (WebSocket & HTTP) ] ====================
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

    -- 構建多輪會話歷史
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

    -- 多種 Executor WebSocket 事件相容綁定
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
    table.insert(targetSession.history, { role = "user", parts = { { text = userPrompt } } })
    table.insert(targetSession.history, { role = "model", parts = { { text = fullReply } } })

    while #targetSession.history > (Config.MAX_HISTORY * 2) do
        table.remove(targetSession.history, 1)
        if #targetSession.history > 0 then table.remove(targetSession.history, 1) end
    end

    return true, fullReply, fullThinking
end

local function callGeminiHTTP(apiKey, modelName, thinkLevel, userPrompt, targetSession)
    local cleanModel = (modelName:gsub("^models/", ""))
    -- 雙重認證：同時在 URL 參數 (?key=) 與 Header (x-goog-api-key) 傳遞，保證 sUNC 最大相容
    local endpoint = string.format("https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s", cleanModel, apiKey)

    logInfo("HTTP", "正在發起 sUNC HTTP 請求至: " .. cleanModel)

    table.insert(targetSession.history, { role = "user", parts = { { text = userPrompt } } })
    while #targetSession.history > (Config.MAX_HISTORY * 2) do
        table.remove(targetSession.history, 1)
        if #targetSession.history > 0 then table.remove(targetSession.history, 1) end
    end

    local payload = {
        systemInstruction = { parts = { { text = CurrentSystemPrompt } } },
        contents = targetSession.history,
        generationConfig = { temperature = 0.1, maxOutputTokens = 8192 }
    }

    local encodedBody = HttpService:JSONEncode(payload)
    local headers = {
        ["Content-Type"] = "application/json",
        ["x-goog-api-key"] = apiKey
    }

    -- 執行 HTTP 請求 (包含針對 503 / 429 臨時高負載的自動重試)
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
        if #targetSession.history > 0 and targetSession.history[#targetSession.history].role == "user" then
            table.remove(targetSession.history)
        end
        local errMsg = "sUNC 網路請求異常: " .. tostring(reqErr or "未知錯誤")
        logError("HTTP", errMsg)
        return false, errMsg, "", ""
    end

    local statusCode = response.StatusCode
    local body = response.Body

    logInfo("HTTP", string.format("HTTP 伺服器響應狀態碼: %s", tostring(statusCode or "無")))

    if statusCode ~= 200 then
        if #targetSession.history > 0 and targetSession.history[#targetSession.history].role == "user" then
            table.remove(targetSession.history)
        end

        local detailedMsg = ""
        if body and #body > 0 then
            local parseOk, errJson = pcall(HttpService.JSONDecode, HttpService, body)
            if parseOk and errJson and errJson.error then
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

    local parseOk, data = pcall(HttpService.JSONDecode, HttpService, body)
    if not parseOk or typeof(data) ~= "table" then
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
    table.insert(targetSession.history, { role = "model", parts = { { text = replyText } } })
    return true, replyText, thoughtText
end

-- ==================== [ 11. 執行排程與沙盒執行器 ] ====================
KeyInputBox.FocusLost:Connect(function()
    local text = (KeyInputBox.Text:gsub("%s+", ""))
    if text ~= "" and text ~= CurrentApiKey then
        CurrentApiKey = text
        saveApiKey(text)
    end
end)

ModelInputBox.FocusLost:Connect(function()
    local modelText = (ModelInputBox.Text:gsub("%s+", ""))
    if modelText ~= "" then
        Config.MODEL = modelText
        saveConfig()
    end
end)

local isBusy = false
local currentMainThread = nil
local currentCodeThread = nil

local function resetBusyState()
    isBusy = false
    currentMainThread = nil
    currentCodeThread = nil
    SubmitBtn.Text = "發送並執行 (Execute)"
    SubmitBtn.BackgroundColor3 = Color3.fromRGB(0, 130, 250)
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

    local targetSession = getActiveSession()
    if #targetSession.history > 0 and targetSession.history[#targetSession.history].role == "user" then
        table.remove(targetSession.history)
    end

    if reason then
        targetSession.lastOutput = targetSession.lastOutput .. "\n\n[BloxAgent] ⚠️ " .. reason
        ContentLabel.Text = targetSession.lastOutput
        syncDisplayScroll(true)
        saveSessionsToWorkspace()
    end

    resetBusyState()
end

local function checkDangerousLoops(code)
    if not code or typeof(code) ~= "string" then return true end
    -- 靜態檢測死循環中是否缺少任何讓步語句 (wait, task.wait, Heartbeat 等)
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

SubmitBtn.MouseButton1Click:Connect(function()
    if isBusy then
        logWarn("Core", "使用者點擊停止執行...")
        abortCurrentExecution("已由使用者手動強制停止。")
        return
    end

    DropdownList.Visible = false

    local currentKey = (KeyInputBox.Text:gsub("%s+", ""))
    local currentModel = (ModelInputBox.Text:gsub("%s+", ""))
    local currentLevel = Config.THINK_LEVEL
    local prompt = PromptInputBox.Text
    local targetSession = getActiveSession()

    if currentKey == "" then
        targetSession.lastOutput = "錯誤: API Key 不可為空。"
        logWarn("Input", targetSession.lastOutput)
        switchTab("OUTPUT")
        return
    end

    if currentModel == "" then
        targetSession.lastOutput = "錯誤: Model 名稱不可為空。"
        logWarn("Input", targetSession.lastOutput)
        switchTab("OUTPUT")
        return
    end

    if not prompt:match("%S") then
        targetSession.lastOutput = "錯誤: 請輸入要執行的指令。"
        logWarn("Input", targetSession.lastOutput)
        switchTab("OUTPUT")
        return
    end

    -- 格式提示
    if not currentKey:match("^AIzaSy") then
        logWarn("Auth", "提醒：輸入的金鑰不是以 'AIzaSy' 開頭，Google AI Studio 金鑰格式應為 AIzaSy...")
    end

    if currentKey ~= CurrentApiKey then
        CurrentApiKey = currentKey
        saveApiKey(currentKey)
    end
    Config.MODEL = currentModel
    saveConfig()

    isBusy = true
    SubmitBtn.Text = "⏹️ 停止執行 (Stop)"
    SubmitBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)

    targetSession.lastOutput = string.format("⚡ 正在建立連線至 [%s]...", currentModel)
    logInfo("Net", string.format("開始執行指令: '%s' (模型: %s)", prompt, currentModel))
    switchTab("OUTPUT")

    local isRunFinished = false
    local watchdogThread = task.delay(35, function()
        if not isRunFinished and isBusy then
            logWarn("Watchdog", "請求超過 35 秒無回應，看門狗進行自動重置")
            abortCurrentExecution("請求逾時 (35 秒 Executor 網路無回應，看門狗已強制釋放)。")
        end
    end)

    currentMainThread = task.spawn(function()
        local executionSuccess, executionError = pcall(function()
            local success, reply, thinking
            local lastRenderTime = 0
            local pendingReply = ""
            local pendingThinking = ""

            local function flushRenderUI(force)
                local now = os.clock()
                if not force and (now - lastRenderTime < 0.08) then return end
                lastRenderTime = now

                local displayParts = {}
                if pendingThinking:match("%S") then
                    table.insert(displayParts, "╔════════ 🧠 實時思考中... ════════╗")
                    table.insert(displayParts, (pendingThinking:gsub("^%s+", ""):gsub("%s+$", "")))
                    table.insert(displayParts, "╚══════════════════════════════════╝\n")
                end
                table.insert(displayParts, pendingReply)

                ContentLabel.Text = table.concat(displayParts, "\n")
                syncDisplayScroll(true)

                -- 即時同步至代碼分頁
                local liveCode = extractLuaCode(pendingReply)
                if liveCode then
                    targetSession.lastCode = liveCode
                end
            end

            local function streamUpdateUI(currReply, currThinking)
                pendingReply = currReply
                pendingThinking = currThinking
                flushRenderUI(false)
            end

            -- 智慧路由：檢查模型與環境是否支援 WebSocket
            local canUseWS = wsConnect and doesModelSupportBidiWS(currentModel)

            if canUseWS then
                logInfo("Net", "模型支援 Bidi 協議，嘗試使用 WebSocket 雙向串流連線...")
                success, reply, thinking = callGeminiWebSocket(currentKey, currentModel, prompt, targetSession, streamUpdateUI)
                if not success then
                    logWarn("Net", "WebSocket 連線不支援或失敗 (" .. tostring(reply) .. ")，自動切換至 sUNC HTTP 降級重試...")
                    targetSession.lastOutput = string.format("[BloxAgent] WebSocket 連線切換 (理由: %s)\n正在使用 sUNC HTTP 降級重試...", tostring(reply))
                    ContentLabel.Text = targetSession.lastOutput
                    syncDisplayScroll(true)
                    task.wait(0.3)
                    success, reply, thinking = callGeminiHTTP(currentKey, currentModel, currentLevel, prompt, targetSession)
                end
            else
                local reason = (not wsConnect and "當前 Executor 缺少 WebSocket 支援") or ("此模型不支援 Bidi WS 協議，選用 sUNC HTTP")
                logInfo("Net", string.format("%s，直接發起 HTTP 請求...", reason))
                targetSession.lastOutput = string.format("⚡ 正在建立連線至 [%s] (sUNC HTTP 模式)...", currentModel)
                ContentLabel.Text = targetSession.lastOutput
                syncDisplayScroll(true)
                success, reply, thinking = callGeminiHTTP(currentKey, currentModel, currentLevel, prompt, targetSession)
            end

            if success then
                pendingReply = reply or ""
                pendingThinking = thinking or ""
            end
            flushRenderUI(true)

            if not success then
                logError("Exec", "通信最終失敗: " .. tostring(reply))
                targetSession.lastOutput = "✗ " .. tostring(reply)
                ContentLabel.Text = targetSession.lastOutput
                syncDisplayScroll(true)
                return
            end

            local luaCode = extractLuaCode(reply)
            if not luaCode then
                logWarn("Exec", "模型回覆未包含有效的 Luau 代碼區塊")
                targetSession.lastOutput = "✗ 響應內容未包含有效的 Luau 代碼區塊。\n\n" .. reply
                ContentLabel.Text = targetSession.lastOutput
                syncDisplayScroll(true)
                return
            end
            targetSession.lastCode = luaCode

            -- 靜態死循環防禦檢測
            local isSafe, loopErr = checkDangerousLoops(luaCode)
            if not isSafe then
                logWarn("Exec", loopErr)
                targetSession.lastOutput = "✗ " .. loopErr
                ContentLabel.Text = targetSession.lastOutput
                syncDisplayScroll(true)
                return
            end

            logInfo("Exec", "代碼靜態檢測通過，開始編譯與沙盒載入...")

            local capturedLogs = {}
            local func, compileErr
            local okLoad, loadRes = pcall(loadstring, luaCode)
            if okLoad and type(loadRes) == "function" then
                func = loadRes
            else
                compileErr = tostring(loadRes or "語法解析失敗")
            end

            local runOk, runErr = false, ""

            if not func then
                runErr = "代碼編譯失敗: " .. tostring(compileErr)
                logError("Exec", runErr)
            else
                -- 安全沙盒構建 (阻斷主程序 script，包裝 task.wait / wait 自動喂看門狗心跳)
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
                            str[i] = typeof(v) == "table" and (pcall(HttpService.JSONEncode, HttpService, sanitizeForJSON(v)) and HttpService:JSONEncode(sanitizeForJSON(v)) or tostring(v)) or tostring(v)
                        end
                        local line = table.concat(str, " ")
                        table.insert(capturedLogs, line)
                        logInfo("AgentPrint", line) -- 同步輸出至 F9 控制台！
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

                local finished = false
                lastWatchdogHeartbeat = os.clock()

                logInfo("Exec", "沙盒環境就緒，啟動執行線程...")

                currentCodeThread = task.spawn(function()
                    runOk, runErr = pcall(func)
                    finished = true
                end)

                local TIMEOUT = 15
                while not finished do
                    -- 心跳超時判定 (若代碼讓步等待中，wrappedTask.wait 會自動調用 heartbeat 重設計時器)
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
            end

            local resultSections = {}
            if thinking and thinking:match("%S") then
                table.insert(resultSections, "╔════════ 🧠 思考過程 (Thinking) ════════╗")
                table.insert(resultSections, (thinking:gsub("^%s+", ""):gsub("%s+$", "")))
                table.insert(resultSections, "╚════════════════════════════════════════╝\n")
            end

            if func then
                if runOk then
                    logInfo("Exec", "Luau 代碼執行成功！")
                    table.insert(resultSections, "✓ 執行成功！已完成操作。")
                else
                    logError("Exec", "代碼執行報錯: " .. tostring(runErr))
                    table.insert(resultSections, "✗ 執行報錯: " .. tostring(runErr))
                end
            else
                table.insert(resultSections, "✗ " .. runErr)
            end

            if #capturedLogs > 0 then
                table.insert(resultSections, "\n--- [📋 沙盒終端輸出] ---")
                for _, logLine in ipairs(capturedLogs) do
                    table.insert(resultSections, logLine)
                end
            else
                table.insert(resultSections, "\n(該操作執行完成，無 print 輸出)")
            end

            targetSession.lastOutput = table.concat(resultSections, "\n")
            ContentLabel.Text = targetSession.lastOutput
            syncDisplayScroll(true)
            saveSessionsToWorkspace()
        end)

        if not executionSuccess then
            logError("Core", "腳本內部崩潰: " .. tostring(executionError))
            targetSession.lastOutput = "✗ 腳本內部崩潰: " .. tostring(executionError)
            ContentLabel.Text = targetSession.lastOutput
            syncDisplayScroll(true)
        end

        isRunFinished = true
        pcall(task.cancel, watchdogThread)
        resetBusyState()
    end)
end)
