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
    ctx.forecast = load("forecast").new(ctx)
    ctx.strategy = load("strategy")
    log.record("forecast", {event = "catalog", waves = ctx.forecast.catalog()})
    local executor = load("executor").new(common, reader, ctx, log)
    ctx.executor = executor
    local planner = load("planner").new(ctx)
    local net = require(common.NetworkingHandler)
    local enums = require(common.Enums)
    local easy = enums.Difficulties.Easy
    local difficultyVote = net.GetEvent("DifficultyVoteCast")
    local difficultyReady = net.GetEvent("DifficultyVoteReady")
    local voted = false
    local readySent = false
    local votes
    local preflightMap
    local scanning = false
    local preflightFailedMap
    net.GetEvent("DifficultyVoteStateUpdate"):AttachCallback(function(data)
        votes = data
    end)
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
        if elapsed < 0.05 or busy or stopped then return end
        elapsed %= 0.05
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
            if snap.voting and snap.playerCount == 1 then
                if preflightMap ~= snap.map and preflightFailedMap ~= snap.map and not scanning and snap.map and snap.spawnIndices and #snap.spawnIndices > 0 then
                    scanning = true
                    voted = false
                    readySent = false
                    task.spawn(function()
                        local success, problem = xpcall(function()
                            local plan = planner.preflight(snap, function()
                                local now = state.get()
                                return not now or now.map ~= snap.map or not now.voting
                            end)
                            local now = state.get()
                            if plan and now and now.voting and now.map == snap.map and now.playerCount == 1 then
                                log.record("forecast",{event="preflight",map=snap.map,rollout=plan})
                                if plan.loss >= ctx.economy.config.StartingLives then
                                    preflightFailedMap=snap.map
                                    log.record("errors",{stage="preflight",error="no_surviving_plan",loss=plan.loss})
                                    return
                                end
                                preflightMap = snap.map
                                votes = nil
                                voted = true
                                difficultyVote:FireServer(easy)
                            end
                        end,debug.traceback)
                        if not success then errorLog("preflight",problem) end
                        scanning=false
                    end)
                elseif voted and not readySent and votes and votes.VoteMap and (votes.VoteMap[easy] or 0) >= 1 then
                    readySent=true
                    difficultyReady:FireServer()
                    log.record("decisions",{event="difficulty_ready",map=snap.map,difficulty=easy})
                end
                return
            end
            if worker or scanning or not snap.running or snap.difficulty ~= "Easy" or snap.playerCount ~= 1 then return end
            worker = true
            task.spawn(function()
                local success, problem = xpcall(function()
                    if not executor.ready(snap) then return end
                    local plan = planner.plan(snap)
                    if not plan then return end
                    if not plan.emergency and not plan.skip.allowed and plan.recommendation.kind=="hold" then
                        for _, a in ipairs(ctx.ability.rank(snap, ctx.physics)) do
                            if executor.available(a) and executor.run(a) then return end
                        end
                    end
                    log.record("decisions", plan)
                    log.record("skip", {wave=plan.wave,revision=plan.revision,vote=executor.canSkip(snap),result=plan.skip})
                    if plan.future then log.record("forecast", {wave = plan.wave, revision = plan.revision, future = plan.future, recommendation = plan.recommendation, goal = plan.goal, rollout = plan.rollout}) end
                    local now = state.get()
                    if stopped or not now or now.map ~= snap.map or now.wave ~= snap.wave or now.time - snap.time > 12 then
                        log.record("decisions", {event="stale_plan",wave=snap.wave,revision=snap.revision,age=now and now.time-snap.time})
                        return
                    end
                    if plan.skip.allowed and executor.run({kind = "skip", wave = snap.wave, threat = plan.skip.threat, lives = plan.skip.lives}) then return end
                    if executor.run(plan.recommendation) then return end
                    if plan.emergency then
                        for _, a in ipairs(ctx.ability.rank(snap, ctx.physics)) do
                            if executor.available(a) and executor.run(a) then return end
                        end
                    end
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
