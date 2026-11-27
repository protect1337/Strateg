local m = {}

function m.new(c)
    local p={}
    local routes,los,mapKey,spots,search
    local last=-math.huge
    local lastSkip=-math.huge
    local lastSearch=-math.huge
    local lastWave,lastCash,lastCount
    local macro,rollout,queued,reservation
    local scans=0

    local function prepare(s)
        local key=tostring(s.map)..":"..table.concat(s.spawnIndices or {},",")
        local team=c.team.GetLocalPlayerTeamIndex()
        if key~=mapKey then
            mapKey=key
            routes=c.physics.routes(c.path,team,s.spawnIndices)
            if not next(routes) then mapKey=nil return false end
            los=c.physics.los(c.map)
            spots=c.placement.candidates(routes,c.physics,c.placementHandler,c.ranger,team,s,los)
            search=c.strategy.new(c,routes,los,spots)
            scans=s.towerCount
            macro=nil
            queued=nil
            reservation=nil
        elseif s.towerCount>=scans+6 or s.towerCount<scans then
            spots=c.placement.candidates(routes,c.physics,c.placementHandler,c.ranger,team,s,los)
            search=c.strategy.new(c,routes,los,spots)
            scans=s.towerCount
            macro=nil
        end
        return routes~=nil
    end

    local function valid(a,s)
        if not a or a.kind=="hold" then return false end
        if not c.executor.available(a) or (a.price or 0)>s.cash then return false end
        if a.kind=="upgrade" then
            local t=s.towers[a.id]
            if not t then return false end
            for _,u in ipairs(c.ranger.upgrades(t)) do
                if u.path==a.path and u.price<=s.cash then return true end
            end
        elseif a.kind=="place" then
            return s.towerCount<(s.towerLimit or 0) and c.placementHandler.Check(c.physics.vec(a.pos),c.ranger.config,c.team.GetLocalPlayerTeamIndex())
        end
        return false
    end

    local function action(a,s)
        if not valid(a,s) then return end
        if a.kind=="upgrade" then
            for _,u in ipairs(c.ranger.upgrades(s.towers[a.id])) do
                if u.path==a.path then return {kind="upgrade",id=a.id,path=a.path,price=u.price,stats=u,at=0.5} end
            end
        elseif a.kind=="place" then
            return {kind="place",pos=c.physics.vec(a.pos),stats=c.ranger.stats(0,0),price=a.price,at=0.5}
        end
    end

    function p.plan(s)
        if not s.running or s.difficulty~="Easy" or s.playerCount~=1 or not s.wave then return end
        if s.time-last<1.0 then return end
        last=s.time
        if not prepare(s) then return end
        local wi=math.max(1,s.wave)
        local index,short
        for idx,r in pairs(routes) do
            if not short or r.length<short then short=r.length index=idx end
        end
        local w=c.forecast.wave(wi)
        if not w then return end
        local horizon=35
        local scenario=s
        if s.wave==0 then
            scenario=c.forecast.scenario(s,routes,1,-(s.timerRemaining or 0),horizon,index,true)
        elseif s.waveAge~=nil then
            scenario=c.forecast.scenario(s,routes,wi,s.waveAge,horizon,index,true)
        end
        local prepared=table.clone(scenario)
        prepared.enemies={}
        for id,e in pairs(scenario.enemies) do
            local v=table.clone(e)
            if not v.kids then v.kids=c.forecast.children(e.type) end
            prepared.enemies[id]=v
        end
        scenario=prepared
        local base=c.combat.run(scenario,routes,c.physics,los,nil,horizon)
        local skip={allowed=false,reason="vote_unavailable"}
        if c.executor.canSkip(s) then
            if s.time-lastSkip>=2.5 then
                lastSkip=s.time
                skip=c.goodskip.assess(s,c,routes,los,s.waveAge,spots)
                if skip.allowed then
                    queued=skip.purchase and {wave=s.wave+1,action=skip.purchase}
                    return {wave=s.wave,revision=s.revision,baseline=base,recommendation={kind="hold"},skip=skip,mode="auto",future=c.forecast.future(wi),rollout=rollout}
                end
            else
                skip.reason="evaluation_cooldown"
            end
        end
        if queued and s.wave>=queued.wave then
            local a=queued.action
            queued=nil
            if valid(a,s) then
                return {wave=s.wave,revision=s.revision,baseline=base,recommendation=a,skip=skip,mode="auto",goal=a,rollout=rollout}
            end
        end
        local recalc=not macro or s.wave~=lastWave or s.towerCount~=lastCount or s.cash>=(lastCash or 0)+math.max(100,0.12*(lastCash or 0)) or s.cash<(lastCash or 0)-0.1
        if recalc or s.time-lastSearch>=7 then
            local t=os.clock()
            macro,rollout=search.search(s)
            rollout.computeTime=os.clock()-t
            lastSearch=s.time
            lastWave,lastCash,lastCount=s.wave,s.cash,s.towerCount
        end
        local best=macro or {kind="hold",reason="no_plan"}
        if reservation then
            local t=s.towers[reservation.id]
            if not t or t.path1>=reservation.path1 and t.path2>=reservation.path2 or s.wave>reservation.wave+2 then
                reservation=nil
            else
                local wanted
                for _,u in ipairs(c.ranger.upgrades(t)) do
                    if u.path==1 and u.path1<=reservation.path1 or u.path==2 and u.path2<=reservation.path2 then
                        if not wanted or u.path==reservation.path then wanted=u end
                    end
                end
                if wanted then
                    if wanted.price<=s.cash then
                        best={kind="upgrade",id=t.id,path=wanted.path,price=wanted.price,goal=reservation,reason="committed_package"}
                    else
                        best={kind="hold",reason="reserve_package",goal=reservation}
                    end
                else
                    reservation=nil
                end
            end
        end
        local selected=action(best,s)
        local chosen=selected and c.combat.run(scenario,routes,c.physics,los,selected,horizon) or base
        local function merit(r)
            local killGain=r.kills-base.kills
            local finishGain=base.finish-r.finish
            local cashGain=c.economy.income(wi,r.cashDamage-base.cashDamage)
            local speedGain=(base.killTime-r.killTime)/math.max(1,r.kills+base.kills)
            return (base.leaks-r.leaks)*18+(base.remaining-r.remaining)*0.45+(r.shieldDamage-base.shieldDamage)*0.1+killGain*5+finishGain*3+cashGain*0.4+speedGain
        end
        local emergency=base.leaks+base.unknown>math.max(12,s.lives*0.12)
        local rescue
        if emergency or not selected and not next(s.towers) then
            local options={}
            for id,t in pairs(s.towers) do
                if t.owned and t.type=="Ranger" then
                    local old=c.ranger.stats(t.path1,t.path2)
                    for _,u in ipairs(c.ranger.upgrades(t)) do
                        if u.price<=s.cash then
                            local rank=(u.dps-old.dps)/math.max(1,u.price)
                            if u.stealthDetection and not old.stealthDetection then rank+=0.1 end
                            if u.ignoreResistance and not old.ignoreResistance then rank+=0.05 end
                            table.insert(options,{kind="upgrade",id=id,path=u.path,price=u.price,rank=rank})
                        end
                    end
                end
            end
            table.sort(options,function(a,b) return a.rank>b.rank end)
            for i=1,math.min(8,#options) do
                local a=options[i]
                local b=action(a,s)
                if b then
                    local r=c.combat.run(scenario,routes,c.physics,los,b,horizon)
                    local v=merit(r)
                    if v>math.max(0,merit(chosen)) and (not rescue or v>rescue.value) then rescue={a=a,r=r,value=v} end
                end
            end
            if s.towerCount<(s.towerLimit or 0) and s.cash>=250 then
                local n=0
                for _,item in ipairs(spots) do
                    local a={kind="place",pos=c.physics.pack(item.pos),price=250}
                    local b=action(a,s)
                    if b then
                        n+=1
                        local r=c.combat.run(scenario,routes,c.physics,los,b,horizon)
                        local v=merit(r)
                        if v>math.max(0,merit(chosen)) and (not rescue or v>rescue.value) then rescue={a=a,r=r,value=v} end
                        if n>=4 then break end
                    end
                end
            end
        end
        if rescue then
            best,chosen=rescue.a,rescue.r
            best.reason="immediate_threat"
        elseif not selected then
            best={kind="hold",reason=best.reason or "reserve",goal=best.goal}
        elseif best.kind=="place" and s.towerCount>=2 and merit(chosen)<=0 and (not rollout or rollout.loss>0) and not emergency then
            best={kind="hold",reason="avoid_idle_tower",goal=best.goal}
        elseif emergency and merit(chosen)<=0 then
            best={kind="hold",reason="reserve_under_threat",goal=best.goal}
        end
        if best.kind=="hold" and not reservation and not next(s.enemies) and s.towerCount>=(s.towerLimit or math.huge) and s.cash>=250 then
            local st=c.ranger.stats(0,0)
            for id,t in pairs(s.towers) do
                if t.owned and t.type=="Ranger" and t.path1==0 and t.path2==0 then
                    for i=1,math.min(4,#spots) do
                        local item=spots[i]
                        if c.placementHandler.Check(item.pos,c.ranger.config,c.team.GetLocalPlayerTeamIndex()) then
                            local sim=table.clone(scenario)
                            sim.towers=table.clone(scenario.towers)
                            sim.towers[id]=nil
                            local replacement=c.combat.run(sim,routes,c.physics,los,{kind="place",pos=item.pos,stats=st,at=1},horizon)
                            if merit(replacement)>5 and replacement.leaks<=base.leaks then
                                local a={kind="sell",id=id,reason="replacement_improves_combat"}
                                if c.executor.available(a) then
                                    best=a
                                    chosen=replacement
                                    break
                                end
                            end
                        end
                    end
                end
                if best.kind=="sell" then break end
            end
        end
        if best.goal and best.goal.id and best.goal.path1 and best.goal.path2 and not rescue then
            local t=s.towers[best.goal.id]
            if t and (t.path1<best.goal.path1 or t.path2<best.goal.path2) then
                local target=c.ranger.stats(best.goal.path1,best.goal.path2)
                local old=c.ranger.stats(t.path1,t.path2)
                local remaining=target.cost-old.cost
                if remaining>0 and (best.kind=="upgrade" or best.kind=="hold" and best.reason=="reserve_package") then
                    if not reservation then
                        reservation=table.clone(best.goal)
                        reservation.wave=s.wave
                    end
                end
            end
        elseif rescue then
            reservation=nil
        end
        best=table.clone(best)
        best.forecast=chosen
        return {wave=s.wave,revision=s.revision,baseline=base,recommendation=best,skip=skip,mode="auto",future=c.forecast.future(wi),goal=best.goal,rollout=rollout,observedWaveAge=s.waveAge,emergency=emergency}
    end
    return p
end

return m
