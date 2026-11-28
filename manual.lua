-- Strateg manual demonstration recorder. No gameplay commands are issued.
local BASE="https://raw.githubusercontent.com/protect1337/Strateg/a1fcd533f34fb9dcf8802fff55ad58c076ca485f/"
local function load(name)
    return assert(loadstring(game:HttpGet(BASE..name..".lua"),"@"..name..".lua"))()
end
local rs=game:GetService("RunService")
local hs=game:GetService("HttpService")
local rep=game:GetService("ReplicatedStorage")
local common=rep:WaitForChild("TDX_Shared"):WaitForChild("Common")
local root="LOGS"
if not isfolder(root) then makefolder(root) end
local dir=root.."/manual"
if not isfolder(dir) then makefolder(dir) end
local session=tostring(os.time()).."_"..string.sub(hs:GenerateGUID(false),1,8)
local file=dir.."/"..session.."_manual.jsonl"
writefile(file,"")
local reader=load("reader").new()
local physics=load("physics")
local queue={}
local first,last=1,0
local stopped,busy,pumping=false,false,false
local started,previous,damageSample
local realTime,gameTime,waveAge=0,0,0
local frames,frameTime,slowFrames=0,0,0
local lastSample,lastFull,lastDelta,lastFlush,lastMetrics=-math.huge,-math.huge,-math.huge,-math.huge,-math.huge
local lastError,lastGeometry
local revision=0
local connection
local counts={}
local pendingEvents={}
local pendingFirst,pendingLast=1,0
local dropped=0
local routes
local function clean(v,depth)
    depth=depth or 0
    local typ=typeof(v)
    if typ=="number" then if v==v and math.abs(v)<math.huge then return v end
    elseif typ=="string" or typ=="boolean" then return v
    elseif typ=="Vector3" then return physics.pack(v)
    elseif typ=="EnumItem" then return tostring(v)
    elseif typ=="table" and depth<16 then
        local out={}
        for k,x in pairs(v) do
            if type(k)=="string" or type(k)=="number" then out[k]=clean(x,depth+1) end
        end
        return out
    end
    return nil
end
local function record(event,data,s)
    local v=table.clone(data or {})
    v.event=event
    v.clock=s and s.time or os.clock()
    v.realTime=realTime
    v.gameTime=gameTime
    v.waveAge=s and (s.waveAge or waveAge) or waveAge
    v.wave=s and s.wave or previous and previous.wave
    v.revision=revision
    last+=1 queue[last]=v
    counts[event]=(counts[event] or 0)+1
end
local function flush(all)
    if first>last then return false end
    local lines={}
    local finish=math.min(last,first+63)
    local began=os.clock()
    for i=first,finish do
        local ok,line=pcall(function() return hs:JSONEncode(clean(queue[i])) end)
        if ok then lines[#lines+1]=line else dropped+=1 warn("[Strateg Manual] JSON error: "..tostring(line)) end
        if not all and os.clock()-began>0.002 then finish=i break end
    end
    if #lines>0 then
        local ok,err=pcall(appendfile,file,table.concat(lines,"\n").."\n")
        if not ok then warn("[Strateg Manual] write failed: "..tostring(err)) return false end
    end
    for i=first,finish do queue[i]=nil end
    first=finish+1
    if first>last then first,last=1,0 end
    return true
end
local function errorLog(stage,err)
    local msg=stage..":"..tostring(err)
    if msg~=lastError then
        lastError=msg
        record("error",{stage=stage,message=tostring(err)},previous)
        warn("[Strateg Manual] "..msg)
    end
end
local function event(name,data)
    if stopped then return end
    pendingLast+=1
    pendingEvents[pendingLast]={name=name,data=data,clock=os.clock()}
end
-- Observe existing notifications only; no hooks, mutations or requests.
local net=require(common.NetworkingHandler)
local bind=require(common.BindableHandler)
local ok,err=pcall(function()
    net.GetEvent("SkipWaveVoteStateUpdate"):AttachCallback(function(data)
        event("skip_vote_state",{enabled=data.VotingEnabled,readyCount=data.ReadyCount,voteCount=data.VoteCount})
    end)
end)
if not ok then errorLog("skip_listener",err) end
ok,err=pcall(function()
    bind.GetEvent("WaveChanged"):AttachCallback(function(n,rewind,active)
        event("wave_signal",{number=n,rewind=rewind,started=active})
    end)
end)
if not ok then errorLog("wave_listener",err) end
ok,err=pcall(function()
    net.GetEvent("EnemyUsedAbility"):AttachCallback(function(data)
        local a=data[2]
        event("enemy_ability_signal",{enemyHandle=tostring(data[1]),ability=a and tostring(a[1]) or nil})
    end)
end)
if not ok then errorLog("enemy_ability_listener",err) end
local function drain(s)
    for i=pendingFirst,pendingLast do
        local v=pendingEvents[i]
        record(v.name,{signalClock=v.clock,details=v.data},s)
        pendingEvents[i]=nil
    end
    pendingFirst,pendingLast=1,0
end
local function status(s)
    return {map=s.map,difficulty=s.difficulty,phase=s.phase,players=s.playerCount,cash=s.cash,lives=s.lives,maxLives=s.maxLives,speed=s.speed,timer=s.timerRemaining or s.timeLeft,towerCount=s.towerCount,towerLimit=s.towerLimit,damage=s.damage,kills=s.kills}
end
local function geometry(s)
    local indices=s.spawnIndices
    if not s.map or not indices or #indices==0 then return end
    local key=tostring(s.map)..":"..table.concat(indices,",")
    if lastGeometry==key then return end
    local path=require(common.PathHandler)
    local team=require(common.TeamUtilities)
    local r=physics.routes(path,team.GetLocalPlayerTeamIndex(),indices)
    local data={}
    for idx,route in pairs(r) do
        local points={}
        for i,p in ipairs(route.points) do points[i]=physics.pack(p) end
        data[tostring(idx)]={points=points,lengths=route.lengths,length=route.length}
    end
    if next(data) then
        routes=r
        lastGeometry=key
        record("map_geometry",{map=s.map,spawnIndices=indices,routes=data},s)
    end
end
local function catalog(s)
    local ctx={ranger=load("ranger").new(common),economy=load("economy").new(common),resources=require(common.ResourceManager),physics=physics}
    local forecast=load("forecast").new(ctx)
    local waves={}
    for i,w in ipairs(ctx.economy.config.Waves) do
        local f=forecast.wave(i)
        waves[i]={number=i,bonus=w.CashBonus,time=w.CustomWaveTime,events=f and f.events,groups=f and f.groups,last=f and f.last,cashRate=ctx.economy.rate(i)}
    end
    local ability=load("ability")
    local cfg=ability.catalog(ctx.resources)
    record("catalog",{tower="Ranger",stats=ctx.ranger.all(),waves=waves,abilities={GrenadeLevel1=ability.spec("GrenadeLevel1",cfg.GrenadeLevel1,ctx.ranger.stats(2,4).range),GrenadeLevel2=ability.spec("GrenadeLevel2",cfg.GrenadeLevel2,ctx.ranger.stats(2,5).range)},startingCash=ctx.economy.config.StartingCash,startingLives=ctx.economy.config.StartingLives},s)
end
local function owned(s)
    local out={}
    for id,t in pairs(s.towers or {}) do if t.owned then out[id]=t end end
    return out
end
local function enemyContext(s,t)
    if not t then return nil end
    local target=t.target and s.enemies[t.target]
    local nearby={}
    local origin=physics.vec(t.pos)
    local range=t.range or 0
    for _,a in pairs(t.abilities or {}) do if type(a.aimRange)=="number" then range=math.max(range,a.aimRange) end end
    for id,e in pairs(s.enemies or {}) do
        local p=physics.vec(e.pos)
        if (p-origin).Magnitude<=range+8 then
            nearby[#nearby+1]={id=id,type=e.type,hp=e.hp,shield=e.shield,pos=e.pos,pathPos=e.pathPos,pathIndex=e.pathIndex,speed=e.speed,progress=e.pathProgress,stealth=e.stealth}
        end
    end
    return {gunTarget=target,nearby=nearby}
end
local function observe(old,s)
    if not old or old.map~=s.map then return end
    local actions={}
    local function action(kind,id,before,after,extra)
        actions[#actions+1]={kind=kind,tower=id,before=before,after=after,details=extra}
        counts[kind]=(counts[kind] or 0)+1
    end
    local prev=owned(old)
    local now=owned(s)
    for id,t in pairs(now) do
        local prior=prev[id]
        if not prior then
            action("place_observed",id,nil,t)
        else
            if prior.path1~=t.path1 or prior.path2~=t.path2 then
                action("upgrade_observed",id,prior,t,{costDelta=(t.cost or 0)-(prior.cost or 0)})
            end
            if prior.query~=t.query then
                action("query_change_observed",id,{query=prior.query,target=prior.target},{query=t.query,target=t.target})
            end
            for name,a in pairs(t.abilities or {}) do
                local b=prior.abilities and prior.abilities[name]
                if not b then
                    action("ability_unlocked",id,nil,a,{name=name})
                elseif type(a.cooldown)=="number" and type(b.cooldown)=="number" and a.cooldown>b.cooldown+0.2 then
                    action("ability_cooldown_increase",id,{cooldown=b.cooldown},a,{name=name,context=enemyContext(s,t),confirmation="cooldown_only",passive=a.passive,custom=a.custom})
                end
            end
        end
    end
    for id,t in pairs(prev) do
        if not now[id] then action("tower_removed",id,t,nil,{cause="unknown_sale_or_destruction"}) end
    end
    if #actions>0 then record("actions",{actions=actions,before=status(old),after=status(s)},s) end
    if old.speed~=s.speed then record("speed_change",{before=old.speed,after=s.speed},s) end
    if old.wave~=s.wave then
        record("wave_transition",{from=old.wave,to=s.wave,before=status(old),after=status(s),previousWaveAge=old.waveAge or waveAge,classification="transition_only"},s)
    elseif old.running and s.running and type(old.timerRemaining)=="number" and type(s.timerRemaining)=="number" and old.timerRemaining-s.timerRemaining>math.max(1.5,(s.time-old.time)*(s.speed or 1)+1) then
        record("timer_drop",{before=old.timerRemaining,after=s.timerRemaining,classification="skip_or_natural_clear_or_server_correction"},s)
    end
    local spawned,removed={},{}
    for id,e in pairs(s.enemies or {}) do if not old.enemies[id] then spawned[#spawned+1]=e end end
    for id,e in pairs(old.enemies or {}) do if not s.enemies[id] then removed[#removed+1]=e end end
    if #spawned>0 or #removed>0 then
        record("enemy_lifecycle",{spawned=spawned,removed=removed,damageDelta=s.damage-old.damage,killsDelta=s.kills-old.kills,livesDelta=s.lives-old.lives,removalCause="unclassified"},s)
    end
end
local function deltas(old,s)
    if not old or old.map~=s.map then return end
    local enemies,towers={},{}
    for id,e in pairs(s.enemies) do
        local b=old.enemies[id]
        if b and (e.hp~=b.hp or e.shield~=b.shield or e.stunned~=b.stunned or e.stopped~=b.stopped or e.speed~=b.speed) then
            enemies[#enemies+1]={id=id,type=e.type,hpBefore=b.hp,hpAfter=e.hp,shieldBefore=b.shield,shieldAfter=e.shield,pos=e.pos,pathPos=e.pathPos,pathIndex=e.pathIndex,speed=e.speed,burn=e.burn,stunned=e.stunned,stopped=e.stopped}
        end
    end
    for id,t in pairs(s.towers) do
        local b=old.towers[id]
        if t.owned and b and (t.damageDealt~=b.damageDealt or t.target~=b.target or t.burstIndex~=b.burstIndex) then
            towers[#towers+1]={id=id,damageBefore=b.damageDealt,damageAfter=t.damageDealt,targetBefore=b.target,targetAfter=t.target,burstBefore=b.burstIndex,burstAfter=t.burstIndex,nextAttack=t.nextAttack,burstReset=t.burstReset}
        end
    end
    if #enemies>0 or #towers>0 or s.cash~=old.cash or s.lives~=old.lives or s.kills~=old.kills then
        record("combat_delta",{fromClock=old.time,cashBefore=old.cash,cashAfter=s.cash,livesBefore=old.lives,livesAfter=s.lives,damageDelta=s.damage-old.damage,killsDelta=s.kills-old.kills,enemies=enemies,towers=towers},s)
    end
end
local function finish(reason,s)
    if stopped then return end
    stopped=true
    if connection then connection:Disconnect() end
    record("session_end",{reason=reason,outcome=s and s.outcome,status=s and status(s),counts=table.clone(counts),encodingDrops=dropped},s)
    -- Drain the queue before announcing completion. Failed writes are visible.
    while pumping do task.wait() end
    while first<=last do
        if not flush(true) then warn("[Strateg Manual] incomplete log: "..file) return end
        task.wait()
    end
    print("[Strateg Manual] saved "..file.." | drops "..tostring(dropped))
end
record("session_start",{version="manual-v1",baseRevision="a1fcd533f34fb9dcf8802fff55ad58c076ca485f",mode="observe_only",sampleInterval=0.1,combatInterval=0.25,snapshotInterval=1,notes="Actions inferred from observed state; no request interception."})
print("[Strateg Manual] recording only: "..file)
if type(shared)=="table" then
    if type(shared.StrategManualStop)=="function" then pcall(shared.StrategManualStop) end
    shared.StrategManualStop=function() task.spawn(finish,"manual_stop",previous) end
end
local catalogDone=false
connection=rs.Heartbeat:Connect(function(dt)
    if stopped then return end
    frames+=1 frameTime+=dt
    if dt>1/30 then slowFrames+=1 end
    local now=os.clock()
    if not pumping and now-lastFlush>=0.15 and first<=last then
        pumping=true lastFlush=now
        task.defer(function()
            local good,why=pcall(flush,false)
            pumping=false
            if not good then errorLog("flush",why) end
        end)
    end
    if busy or now-lastSample<0.10 then return end
    busy=true lastSample=now
    local good,why=xpcall(function()
        local s=reader.read()
        if not s then return end
        revision+=1
        if s.running and not started then
            started=s.time
            realTime,gameTime,waveAge=0,0,s.waveAge or 0
            record("match_start",{status=status(s),lateStart=(s.wave or 0)>0},s)
        elseif started then
            realTime=s.time-started
            local elapsed=previous and math.max(0,s.time-previous.time) or 0
            gameTime+=elapsed*(previous and previous.speed or s.speed or 1)
            if previous and s.wave~=previous.wave then waveAge=0 else waveAge+=elapsed*(previous and previous.speed or s.speed or 1) end
        end
        drain(s)
        if not catalogDone and s.map then
            catalogDone=true
            local ok,err=pcall(catalog,s)
            if not ok then errorLog("catalog",err) end
        end
        local ok,err=pcall(geometry,s)
        if not ok then errorLog("geometry",err) end
        if s.running or s.outcome or previous and previous.running then
            observe(previous,s)
            if s.time-lastDelta>=0.25 or s.outcome then
                deltas(damageSample,s)
                damageSample=s lastDelta=s.time
            end
            if s.time-lastFull>=1 or not previous or s.wave~=previous.wave or s.outcome then
                record("snapshot",{status=status(s),towers=owned(s),enemies=s.enemies},s)
                lastFull=s.time
            end
        end
        if s.time-lastMetrics>=5 then
            record("performance",{fps=frames/math.max(0.001,frameTime),slowFrames=slowFrames,queue=last-first+1,dropped=dropped},s)
            frames,frameTime,slowFrames=0,0,0
            lastMetrics=s.time
        end
        previous=s
        if s.outcome then task.defer(finish,"end_screen",s) end
    end,debug.traceback)
    busy=false
    if not good then errorLog("sample",why) end
end)
