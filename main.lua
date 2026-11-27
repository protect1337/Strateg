local rs = game:GetService("RunService")
local rep = game:GetService("ReplicatedStorage")
local base = "https://raw.githubusercontent.com/protect1337/Strateg/refs/heads/main/"

local function load(name)
    local src = game:HttpGet(base .. name .. ".lua?v=adaptive-v6")
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
    assert(ctx.strategy.version=="adaptive-v6","stale strategy module")
    print("[Strateg] adaptive-v6 | unlimited repair search")
    ctx.tactics = load("tactics").new(ctx)
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
    local voteAt=-math.huge
    local readyAt=-math.huge
    local voteAttempts=0
    local readyAttempts=0
    local lastVoteStatus
    local retryScanAt=0
    local rejectedMap
    local lastPrint=-math.huge
    net.GetEvent("DifficultyVoteStateUpdate"):AttachCallback(function(data)
        votes = data
    end)
    local elapsed = 0
    local prev
    local lastDebug=-math.huge
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
            if not prev or snap.time-prev.time>=0.2 or snap.wave~=prev.wave or snap.phase~=prev.phase or snap.outcome then
                log.observe(prev, snap)
                prev = snap
            end
            if snap.outcome then
                stopped = true
                connection:Disconnect()
                return
            end
            if snap.voting and snap.playerCount == 1 then
                if preflightMap ~= snap.map and rejectedMap~=snap.map and not scanning and snap.map and snap.spawnIndices and #snap.spawnIndices > 0 and os.clock()>=retryScanAt then
                    scanning = true
                    voted = false
                    readySent = false
                    voteAttempts=0
                    readyAttempts=0
                    log.record("decisions",{event="preflight_start",map=snap.map,paths=#snap.spawnIndices,speed=snap.speed,timer=snap.timerRemaining})
                    print("[Strateg] 0% | scanning map and tower grid")
                    task.spawn(function()
                        local success, problem = xpcall(function()
                            local plan = planner.preflight(snap, function()
                                local now = state.get()
                                return not now or now.map ~= snap.map or not now.voting
                            end,function(i,n,w,lives,phase,detail)
                                if detail then
                                    print(string.format("[Strateg] %s | %s | HP %.1f | early loss %.1f | remaining %d (%.1f HP) | unknown %d | cash %.1f | income %.1f | bonus %.1f | spent %.1f | ledger error %.4f",phase,detail.reason,lives,detail.earlyLoss,detail.remaining,detail.remainingHP,detail.unknown,detail.cash,detail.income,detail.bonuses,detail.spent,detail.ledgerError))
                                    if detail.blockedMove then
                                        local v=detail.blockedMove
                                        print(string.format("[Strateg] blocked purchase | wave %d | move %d | cost %.1f | cash %.1f | age %.2f",v.wave,v.index,v.required,v.cash,v.age))
                                    end
                                    return
                                end
                                local pct=math.floor((i-1+w/18)/n*100)
                                if os.clock()-lastPrint>=0.2 or w==18 or w==1 and string.find(phase,"repair") then
                                    lastPrint=os.clock()
                                    print(string.format("[Strateg] %s | variant %d/%d | wave %d/18 | search %d%% | HP %.1f",phase,i,n,w,math.min(99,pct),lives))
                                end
                            end)
                            local now = state.get()
                            if plan and now and now.voting and now.map == snap.map and now.playerCount == 1 then
                                log.record("forecast",{event="preflight",map=snap.map,rollout=plan})
                                if not plan.ready or plan.to~=#ctx.economy.config.Waves then
                                    retryScanAt=os.clock()+0.5
                                    print(string.format("[Strateg] retrying | reached %d/18 | HP %.1f",plan.to,plan.lives or 0))
                                    log.record("decisions",{event="preflight_rejected",loss=plan.loss,wave=plan.to})
                                    return
                                end
                                print(string.format("[Strateg] READY 100%% | 18/18 | HP %.1f | stress HP %.1f | attempts %d",plan.lives,plan.stressLives,plan.attempts or 0))
                                preflightMap = snap.map
                                votes = nil
                                difficultyVote:FireServer(easy)
                                voted = true
                                voteAt=os.clock()
                                voteAttempts=1
                                log.record("decisions",{event="difficulty_vote_sent",map=snap.map,difficulty=easy,attempt=voteAttempts})
                            elseif now and now.voting and now.map==snap.map then
                                retryScanAt=os.clock()+0.5
                                log.record("decisions",{event="preflight_incomplete",map=snap.map})
                            end
                        end,debug.traceback)
                        if not success then
                            retryScanAt=os.clock()+1
                            errorLog("preflight",problem)
                            print("[Strateg] NOT READY | preflight error: "..tostring(problem))
                        end
                        scanning=false
                    end)
                elseif snap.map and preflightMap==snap.map then
                    local confirmed=votes and votes.VoteMap and (votes.VoteMap[easy] or 0)>=1
                    if not confirmed and os.clock()-voteAt>=0.75 and voteAttempts<4 then
                        difficultyVote:FireServer(easy)
                        voted=true
                        voteAt=os.clock()
                        voteAttempts+=1
                        log.record("decisions",{event="difficulty_vote_retry",attempt=voteAttempts})
                    elseif confirmed and not readySent then
                        difficultyReady:FireServer()
                        readySent=true
                        readyAt=os.clock()
                        readyAttempts=1
                        log.record("decisions",{event="difficulty_ready_sent",map=snap.map,difficulty=easy})
                    elseif confirmed and readySent and votes.ReadyCount==0 and os.clock()-readyAt>=1 and readyAttempts<3 then
                        difficultyReady:FireServer()
                        readyAt=os.clock()
                        readyAttempts+=1
                    end
                end
                local status=scanning and "scanning" or rejectedMap==snap.map and "not_ready" or snap.map and preflightMap==snap.map and (readySent and "ready_sent" or "waiting_vote") or "waiting_map"
                if status~=lastVoteStatus then
                    lastVoteStatus=status
                    log.record("decisions",{event="voting_state",status=status,map=snap.map,paths=snap.spawnIndices and #snap.spawnIndices or 0,timer=snap.timerRemaining})
                end
                return
            end
            if worker or scanning or not snap.running or snap.difficulty ~= "Easy" or snap.playerCount ~= 1 or preflightMap~=snap.map then return end
            worker = true
            task.spawn(function()
                local success, problem = xpcall(function()
                    if not executor.ready(snap) then return end
                    local began=os.clock()
                    local plan = planner.plan(snap)
                    if not plan then return end
                    if snap.time-lastDebug>=1 then
                        lastDebug=snap.time
                        local a=plan.recommendation
                        local b=plan.baseline
                        log.record("debug",{wave=snap.wave,cash=snap.cash,lives=snap.lives,speed=snap.speed,threats=plan.threats,action=a,skip=plan.skip,leaks=b and b.leaks,computeMs=math.floor((os.clock()-began)*1000),targetChanges=plan.targets and #plan.targets or 0,towers=snap.towerCount})
                    end


                    log.record("decisions", plan)
                    log.record("skip", {wave=plan.wave,revision=plan.revision,vote=executor.canSkip(snap),result=plan.skip})
                    if plan.future then log.record("forecast", {wave = plan.wave, revision = plan.revision, future = plan.future, recommendation = plan.recommendation, goal = plan.goal, rollout = plan.rollout}) end
                    local now = state.get()
                    if stopped or not now or now.map ~= snap.map or now.wave ~= snap.wave or now.time - snap.time > 12 then
                        log.record("decisions", {event="stale_plan",wave=snap.wave,revision=snap.revision,age=now and now.time-snap.time})
                        return
                    end
                    if plan.targets then
                        local n=0
                        for _,a in ipairs(plan.targets) do
                            if executor.target(a,now) then n+=1 end
                            if n>=3 then break end
                        end
                    end
                    if plan.skip.allowed and executor.run({kind = "skip", wave = snap.wave, threat = plan.skip.threat, lives = plan.skip.lives}) then return end
                    if executor.run(plan.recommendation) then return end
                    if plan.emergency or plan.recommendation.kind=="hold" then
                        for _, a in ipairs(ctx.ability.rank(now, ctx.physics)) do
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
