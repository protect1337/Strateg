local rs = game:GetService("RunService")
local rep = game:GetService("ReplicatedStorage")
local base = "https://raw.githubusercontent.com/protect1337/Strateg/refs/heads/main/"

local function load(name)
    local src = game:HttpGet(base .. name .. ".lua")
    return assert(loadstring(src, "@" .. name .. ".lua"))()
end

local log = load("logger").new()
local ok, err = xpcall(function()
    local state = load("state").new()
    local reader = load("reader").new()
    local common = rep:WaitForChild("TDX_Shared"):WaitForChild("Common")
    local ctx = {
        physics = load("physics"),
        ranger = load("ranger").new(common),
        combat = load("combat"),
        economy = load("economy").new(common),
        placement = load("placement"),
        ability = load("ability"),
        goodskip = load("goodskip"),
        path = require(common.PathHandler),
        map = require(common.MapHandler),
        team = require(common.TeamUtilities),
        resources = require(common.ResourceManager),
        placementHandler = require(common.PlacementHandler)
    }
    local executor = load("executor").new(common, reader, ctx, log)
    ctx.executor = executor
    local planner = load("planner").new(ctx)
    local elapsed = 0
    local prev
    local lastError
    local busy = false
    local worker = false
    local stopped = false
    local connection

    local function errorLog(stage, problem)
        local key = stage .. tostring(problem)
        if key ~= lastError then
            lastError = key
            pcall(log.record, "errors", {stage = stage, error = tostring(problem)})
        end
    end

    log.record("decisions", {stage = "startup", mode = "auto", difficulty = "Easy", players = 1})
    connection = rs.Heartbeat:Connect(function(dt)
        elapsed += dt
        if elapsed < 0.1 or busy or stopped then return end
        elapsed %= 0.1
        busy = true

        local success, problem = xpcall(function()
            local snap = reader.read()
            if not snap then return end
            snap = state.publish(snap)
            log.observe(prev, snap)
            prev = snap
            if snap.outcome then
                stopped = true
                connection:Disconnect()
                return
            end
            if worker or not snap.running or snap.difficulty ~= "Easy" or snap.playerCount ~= 1 then return end
            worker = true
            task.spawn(function()
                local success, problem = xpcall(function()
                    if not executor.ready(snap) then return end
                    for _, a in ipairs(ctx.ability.rank(snap, ctx.physics)) do
                        if executor.available(a) and executor.run(a) then return end
                    end
                    local plan = planner.plan(snap)
                    if not plan then return end
                    log.record("decisions", plan)
                    local now = state.get()
                    if stopped or not now or now.map ~= snap.map or now.wave ~= snap.wave or now.time - snap.time > 5 then return end
                    if plan.skip.allowed and executor.run({kind = "skip", wave = snap.wave, threat = plan.skip.threat, lives = plan.skip.lives}) then return end
                    executor.run(plan.recommendation)
                end, debug.traceback)
                if not success then errorLog("planner", problem) end
                worker = false
            end)
        end, debug.traceback)
        if not success then errorLog("sample", problem) end
        busy = false
    end)
end, debug.traceback)

if not ok then
    log.record("errors", {stage = "startup", error = err})
end
