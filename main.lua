local rs = game:GetService("RunService")
local rep = game:GetService("ReplicatedStorage")
local base = "https://raw.githubusercontent.com/protect1337/Strateg/8bc7aeb5c4a3fb306516ed5a461a2318578e713c/"

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
    ctx.combat.configure(ctx.ability,ctx.resources)
    ctx.forecast = load("forecast").new(ctx)
    ctx.strategy = load("strategy")
    assert(ctx.strategy.version=="adaptive-v28","strategy version mismatch: "..tostring(ctx.strategy.version))
    print("[Strateg] adaptive-v28 | route fire-time budget | neutral investment | verified skip")
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
    local logBusy=false
    local nextLogPump=0
    local frames,frameTime,frameMax,slowFrames=0,0,0,0
    local readerMs,observeMs=0,0
    local lastDecisionKey,lastDecisionAt=nil,-math.huge
    local lastSkipKey,lastSkipLogAt=nil,-math.huge
    local abilityCursor,abilityNext,abilityLastLog=0,0,-math.huge
    local abilityFocus,restoreQuery
    local reservedGrenades={}
    local preferPurchase=false
    local abilityLast,abilityObserved,abilityExpected={},{},{}
    local abilityWave
    local function reconcile(s)
        if not s.running and not s.outcome then return end
        if abilityWave~=nil and (s.wave~=abilityWave or s.outcome) then
            log.record("debug",{event="ability_reconciliation",wave=abilityWave,expected=abilityExpected[abilityWave],observed=abilityObserved[abilityWave] or 0})
        end
        abilityWave=s.wave
        local nextState={}
        for id,t in pairs(s.towers or {}) do
            if t.owned then
                for name,a in pairs(t.abilities or {}) do
                    if name=="GrenadeLevel1" or name=="GrenadeLevel2" then
                        local key=id..":"..name
                        local cd=a.cooldown or 0
                        local before=abilityLast[key]
                        if before==nil then
                            log.record("debug",{event="ability_config",tower=id,name=name,wave=s.wave,model=ctx.ability.spec(name,a,t.range)})
                        elseif cd>before+0.2 then
                            abilityObserved[s.wave]=(abilityObserved[s.wave] or 0)+1
                        end
                        nextState[key]=cd
                    end
                end
            end
        end
        abilityLast=nextState
    end

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
        frames+=1 frameTime+=dt frameMax=math.max(frameMax,dt)
        if dt>1/30 then slowFrames+=1 end
        if not logBusy and not stopped and os.clock()>=nextLogPump then
            nextLogPump=os.clock()+0.12
            logBusy=true
            task.defer(function()
                local ok,err=pcall(log.pump)
                logBusy=false
                if not ok then warn("[Strateg] log pump: "..tostring(err)) end
            end)
        end
        if elapsed<0.10 or busy or stopped then return end
        elapsed%=0.10
        busy=true

        local success, problem = xpcall(function()
            local readAt=os.clock()
            local snap=reader.read()
            if not snap then return end
            snap=state.publish(snap)
            reconcile(snap)
            readerMs=(os.clock()-readAt)*1000
            if not prev or snap.time-prev.time>=0.4 or snap.wave~=prev.wave or snap.phase~=prev.phase or snap.outcome then
                local observedAt=os.clock()
                log.observe(prev,snap)
                observeMs=(os.clock()-observedAt)*1000
                prev=snap
            end
            if snap.outcome then
                stopped = true
                planner.stop()
                connection:Disconnect()
                task.spawn(function() while logBusy do task.wait() end log.flush() end)
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
                                    if detail.attempt then
                                        if detail.time then print(string.format("[Strateg] game %.1fs | towers %d | tier5 %d",detail.time,detail.towers or 0,detail.maxed or 0)) end
                                        local leak=detail.lastLeak
                                        print(string.format("[Strateg] attempt %d | end wave %d | reused %d | boss HP %.1f | last leak %s %.1f",detail.attempt,detail.wave,detail.reusedWaves or 0,detail.bossHP or 0,leak and tostring(leak.type) or "-",leak and leak.hp or 0))
                                    end
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
                                print(string.format("[Strateg] READY 100%% | 18/18 | HP %.1f | route HP %.1f | attempts %d",plan.lives,plan.routeLives or plan.lives,plan.attempts or 0))
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
                    local purchaseReady=executor.ready(snap)
                    local began=os.clock()
                    local plan = planner.plan(snap)
                    if not plan then return end
                    if plan.plannedGrenadeCasts~=nil then abilityExpected[snap.wave]=plan.plannedGrenadeCasts end
                    if snap.time-lastDebug>=1 then
                        lastDebug=snap.time
                        local a=plan.recommendation
                        local b=plan.baseline
                        local pendingLogs,droppedLogs,writeMs=log.metrics()
                        local maxed=0
                        for _,t in pairs(snap.towers) do if t.owned and t.type=="Ranger" and math.max(t.path1,t.path2)==5 then maxed+=1 end end
                        log.record("debug",{wave=snap.wave,cash=snap.cash,lives=snap.lives,speed=snap.speed,threats=plan.threats,action=a,skip=plan.skip,leaks=b and b.leaks,plannedLoss=b and b.plannedLoss,rescueLoss=b and b.rescueLoss,plannedWaveLoss=plan.plannedWaveLoss,plannedWaveHP=plan.plannedWaveHP,plannedGrenadeCasts=plan.plannedGrenadeCasts,observedGrenadeCasts=abilityObserved[snap.wave] or 0,move=plan.move,computeMs=(os.clock()-began)*1000,targetChanges=plan.targets and #plan.targets or 0,towers=snap.towerCount,towerLimit=snap.towerLimit,maxed=maxed,fps=frames/math.max(0.001,frameTime),maxFrameMs=frameMax*1000,slowFrames=slowFrames,readerMs=readerMs,observeMs=observeMs,logWriteMs=writeMs,pendingLogs=pendingLogs,droppedLogs=droppedLogs,analysis=plan.analysis,analysisMs=plan.analysisMs,analysisWall=plan.analysisWall})
                        frames,frameTime,frameMax,slowFrames=0,0,0,0
                    end


                    if plan.analysisError then errorLog("live_analysis",plan.analysisError) end
                    local a=plan.recommendation
                    local p=a.pos
                    local decisionKey=table.concat({tostring(plan.wave),a.kind or "",a.reason or "",a.id or "",tostring(a.path or ""),tostring(a.levels or ""),tostring(plan.move or ""),p and string.format("%.2f:%.2f",p.x,p.z) or "",tostring(plan.skip.allowed)},"/")
                    if decisionKey~=lastDecisionKey or snap.time-lastDecisionAt>=1 then
                        lastDecisionKey=decisionKey lastDecisionAt=snap.time
                        log.record("decisions",plan)
                    end
                    local skipKey=table.concat({tostring(plan.wave),tostring(executor.canSkip(snap)),tostring(plan.skip.reason),tostring(plan.skip.allowed)},"/")
                    if plan.skip.tested or skipKey~=lastSkipKey or snap.time-lastSkipLogAt>=2 then
                        lastSkipKey=skipKey lastSkipLogAt=snap.time
                        log.record("skip",{wave=plan.wave,revision=plan.revision,vote=executor.canSkip(snap),result=plan.skip})
                    end
                    if plan.future then log.record("forecast", {wave = plan.wave, revision = plan.revision, future = plan.future, recommendation = plan.recommendation, goal = plan.goal, rollout = plan.rollout}) end
                    local now = state.get()
                    if stopped or not now or now.map ~= snap.map or now.wave ~= snap.wave or now.time - snap.time > 0.5 then
                        log.record("decisions", {event="stale_plan",wave=snap.wave,revision=snap.revision,age=now and now.time-snap.time})
                        return
                    end
                    if plan.targets then
                        local n=0
                        for _,a in ipairs(plan.targets) do
                            if (not abilityFocus or a.id~=abilityFocus.id) and (not restoreQuery or a.id~=restoreQuery.id) and executor.target(a,now) then n+=1 end
                            if n>=3 then break end
                        end
                    end
                    local skipSent=purchaseReady and plan.skip.allowed and executor.run({kind="skip",wave=snap.wave,threat=plan.skip.threat,lives=plan.skip.lives},now)
                    if skipSent then purchaseReady=false end
                    for i=#reservedGrenades,1,-1 do
                        if reservedGrenades[i].untilTime<=now.time then table.remove(reservedGrenades,i) end
                    end
                    if abilityFocus and (now.time>=abilityFocus.deadline or not now.towers[abilityFocus.id]) then
                        restoreQuery=abilityFocus
                        restoreQuery.deadline=now.time+1.5
                        abilityFocus=nil
                    end
                    if restoreQuery then
                        local t=now.towers[restoreQuery.id]
                        if not t or t.query==restoreQuery.priorQuery or now.time>=restoreQuery.deadline then restoreQuery=nil
                        elseif plan.analysis~="skip" and not executor.queryBusy(t.id) and t.query==restoreQuery.query then
                            if executor.target({kind="target",id=t.id,query=restoreQuery.priorQuery,reason="grenade_restore"},now) then restoreQuery=nil end
                        end
                    end
                    local buy=plan.recommendation and (plan.recommendation.kind=="upgrade" or plan.recommendation.kind=="place")
                    if purchaseReady and buy and (preferPurchase or plan.recommendation.reason=="emergency_intercept") and executor.run(plan.recommendation,now) then
                        preferPurchase=false
                        purchaseReady=false
                    end
                    if now.wave>=1 and next(now.enemies) and now.time>=abilityNext then
                        abilityNext=now.time+0.10
                        local focus=abilityFocus and abilityFocus.id
                        if not focus or not executor.queryBusy(focus) then
                            local ok,actions,cursor,metrics=pcall(planner.grenades,now,abilityCursor,reservedGrenades,focus)
                            if ok then
                                abilityCursor=cursor
                                if now.time-abilityLastLog>=2 then
                                    abilityLastLog=now.time
                                    log.record("debug",{event="grenade_scan",wave=now.wave,abilities=metrics,candidates=#actions})
                                end
                                for _,a in ipairs(actions) do
                                    if focus and a.id~=focus then continue end
                                    if a.kind=="target" and not abilityFocus and not restoreQuery and plan.analysis~="skip" then
                                        if executor.target(a,now) then
                                            abilityFocus={id=a.id,query=a.query,priorQuery=a.priorQuery,deadline=now.time+1.2}
                                            break
                                        end
                                    elseif a.kind=="ability" and not executor.abilityBusy(a.id) and executor.available(a) then
                                        if executor.run(a,now) then
                                            local impact=now.time+a.flight/math.max(1,now.speed or 1)
                                            reservedGrenades[#reservedGrenades+1]={impact=impact,untilTime=impact+0.3,hits=a.hits}
                                            abilityNext=now.time+0.15
                                            preferPurchase=true
                                            if abilityFocus and abilityFocus.id==a.id then
                                                restoreQuery=abilityFocus
                                                restoreQuery.deadline=now.time+1.5
                                                abilityFocus=nil
                                            end
                                            break
                                        end
                                    end
                                end
                            else errorLog("ability_scan",actions) end
                        end
                    end
                    if purchaseReady and executor.run(plan.recommendation,now) then preferPurchase=false end
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
