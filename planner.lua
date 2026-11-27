local m={}

function m.new(c)
    local x={}
    local routes,los,spots,search,mapKey,rollout
    local last=-math.huge
    local lastSkip=-math.huge
    local lastScan=-math.huge
    local lastEmergency=-math.huge
    local cachedBaseline
    local baselineWave
    local valueCache={}
    local queued
    local cursor=1
    local soldWave
    local skipContinuation
    local all=c.ranger.all()
    local base=c.ranger.stats(0,0)

    local function prepare(s)
        if not s.map or not s.spawnIndices or #s.spawnIndices==0 then return false end
        local indices=table.clone(s.spawnIndices)
        table.sort(indices)
        local key=s.map..":"..table.concat(indices,",")
        if key~=mapKey then
            local team=c.team.GetLocalPlayerTeamIndex() or 1
            routes=c.physics.routes(c.path,team,s.spawnIndices)
            if not next(routes) then return false end
            los=c.physics.los(c.map)
            spots=c.placement.candidates(routes,c.physics,c.placementHandler,c.ranger,team,s,los)
            if #spots==0 then return false end
            search=c.strategy.new(c,routes,los,spots)
            mapKey=key
            c.tactics.reset(key)
            rollout=nil
            cursor=1
            soldWave=nil
            skipContinuation=nil
            queued=nil
        end
        return true
    end

    function x.preflight(s,cancel,progress)
        if not prepare(s) then return end
        local init=table.clone(s)
        init.wave=0
        init.cash=c.economy.config.StartingCash
        init.lives=c.economy.config.StartingLives
        init.towers={}
        init.towerCount=0
        init.cancel=cancel
        init.progress=progress
        local first,plan=search.search(init)
        if not plan then return end
        if plan.ready and plan.to==#c.economy.config.Waves then rollout=plan cursor=1 end
        return plan
    end

    local function nextStep(t,st,budget)
        local old=c.ranger.stats(t.path1,t.path2)
        local best
        for path=1,2 do
            local count=path==1 and st.path1-t.path1 or st.path2-t.path2
            for n=1,count do
                local a=t.path1+(path==1 and n or 0)
                local b=t.path2+(path==2 and n or 0)
                if c.ranger.valid(a,b) then
                    local v=c.ranger.stats(a,b)
                    local price=v.cost-old.cost
                    if price<=budget and (not best or v.dps-old.dps>best.gain) then
                        best={kind="upgrade",id=t.id,path=path,levels=n,price=price,gain=v.dps-old.dps,stats=v,goal={path1=st.path1,path2=st.path2}}
                    end
                end
            end
        end
        return best
    end

    local function pack(a)
        local b=table.clone(a)
        b.stats=nil
        if typeof(b.pos)=="Vector3" then b.pos=c.physics.pack(b.pos) end
        return b
    end

    local function valid(a,s)
        if not a or not c.executor.available(pack(a)) or (a.price or 0)>s.cash then return false end
        if a.kind=="upgrade" then return s.towers[a.id]~=nil end
        if a.kind=="sell" then return s.towers[a.id]~=nil end
        if a.kind=="place" then
            local pos=typeof(a.pos)=="Vector3" and a.pos or c.physics.vec(a.pos)
            return s.towerCount<(s.towerLimit or 0) and c.placementHandler.Check(pos,c.ranger.config,c.team.GetLocalPlayerTeamIndex())
        end
        return false
    end

    local function threat(s)
        local list={}
        for id,e in pairs(s.enemies) do
            local r=routes[e.pathIndex]
            if r and not e.reverse then
                local d=c.physics.project(r,c.physics.vec(e.pathPos))
                local speed=e.speed or 0
                if speed<=0.01 then
                    local cfg=c.resources.GetEnemyConfig(e.type)
                    speed=cfg and cfg.Speed or 1
                end
                local t=(r.length-d)/math.max(0.01,speed)
                list[#list+1]={id=id,e=e,r=r,d=d,speed=speed,eta=t,risk=e.hp/math.max(0.5,t)}
            end
        end
        table.sort(list,function(a,b) return a.risk>b.risk end)
        return list
    end

    local function near(s,ts)
        local out={}
        local seen={}
        local team=c.team.GetLocalPlayerTeamIndex()
        local function add(p)
            local key=string.format("%.1f:%.1f",p.X,p.Z)
            if not seen[key] then
                seen[key]=true
                if c.placementHandler.Check(p,c.ranger.config,team) then out[#out+1]=p end
            end
        end
        for i=1,math.min(2,#ts) do
            local q=ts[i]
            for _,seconds in ipairs({0,3,7,13,22}) do
                local d=math.min(q.r.length-0.1,q.d+q.speed*seconds)
                local center=c.physics.at(q.r,d)
                for _,radius in ipairs({2.5,5.5,8.5}) do
                    for k=0,5 do
                        local a=k*math.pi/3
                        local px=math.round((center.X+radius*math.cos(a))*2)/2
                        local pz=math.round((center.Z+radius*math.sin(a))*2)/2
                        local y=c.placementHandler.GetGroundHeightAtXZ(px,pz,center.Y)
                        if type(y)=="number" then add(Vector3.new(px,y,pz)) end
                    end
                end
            end
        end
        local anchors=0
        for _,t in pairs(s.towers) do
            if t.owned and t.type=="Ranger" and anchors<6 then
                local pos=c.physics.vec(t.pos)
                local useful=false
                for i=1,math.min(2,#ts) do
                    if c.tactics.reach(pos,t.range,ts[i],los,0)>0 then useful=true break end
                end
                if useful then
                    anchors+=1
                    for k=0,5 do
                        local a=k*math.pi/3
                        local px=pos.X+3.1*math.cos(a)
                        local pz=pos.Z+3.1*math.sin(a)
                        local y=c.placementHandler.GetGroundHeightAtXZ(px,pz,pos.Y)
                        if type(y)=="number" then add(Vector3.new(px,y,pz)) end
                    end
                end
            end
        end
        return out
    end

    local function value(st,pos,ts)
        local k=string.format("%.2f:%.2f:%.2f:%d:%d:%.2f:%.2f",pos.X,pos.Y,pos.Z,st.path1,st.path2,st.range,st.dps)
        local group=valueCache[ts]
        if not group then group={} valueCache[ts]=group end
        if group[k]~=nil then return group[k] end
        local score=0
        for i=1,math.min(8,#ts) do
            local q=ts[i]
            local e=q.e
            if not e.air and not e.invulnerable and not e.noDamage and (not e.stealth or st.stealthDetection) then
                local dps=st.dps*(st.ignoreResistance and 1 or 1-math.clamp((e.resist or {})[tostring(st.damageType)] or 0,0,1))
                local time=0
                for t=0.5,math.min(45,q.eta),1 do
                    local p=c.physics.at(q.r,q.d+q.speed*t)
                    if (p-pos).Magnitude<=st.range and los(pos,p) then time+=1 end
                end
                score+=math.min(e.hp+(e.shield or 0),dps*time)*(1+e.hp/math.max(1,q.eta)*0.1)
            end
        end
        group[k]=score
        return score
    end

    local function emergency(s,ts,plannedAction,queuedAction)
        if #ts==0 then return end
        local urgent={}
        for _,q in ipairs(ts) do
            if q.eta<=45 or q.e.hp>=s.lives and q.eta<=65 then urgent[#urgent+1]=q end
        end
        if #urgent==0 then return end
        local h=math.min(66,math.max(5,urgent[1].eta+1))
        for _,q in ipairs(urgent) do h=math.max(h,math.min(66,q.eta+0.5)) end
        local sim=table.clone(s)
        sim.enemies={}
        for id,e in pairs(s.enemies) do
            local v=table.clone(e)
            v.kids=c.forecast.children(e.type)
            sim.enemies[id]=v
        end
        local baseline=c.combat.run(sim,routes,c.physics,los,nil,h)
        local loss=baseline.leaks+baseline.unknown
        if loss<=0 then return nil,baseline end
        local lethal=loss>=s.lives
        if not lethal then return nil,baseline end
        local function simulateStep(a)
            if not a then return end
            local v=table.clone(a)
            if v.kind=="upgrade" then
                local t=s.towers[v.id]
                if not t then return end
                local n=v.levels or 1
                v.stats=c.ranger.stats(t.path1+(v.path==1 and n or 0),t.path2+(v.path==2 and n or 0))
            elseif v.kind=="place" then
                v.pos=c.physics.vec(v.pos)
                v.stats=base
            else return end
            v.at=0.45*(s.speed or 1)
            local r=c.combat.run(sim,routes,c.physics,los,v,h)
            return r.leaks+r.unknown
        end
        local planLoss=simulateStep(plannedAction) or loss
        local queueLoss=simulateStep(queuedAction)
        if queueLoss then planLoss=math.min(planLoss,queueLoss) end
        baseline.plannedLoss=planLoss
        if planLoss<s.lives then return nil,baseline end
        -- Finish an already accepted affordable purchase chain instead of repeatedly replacing it.
        if queuedAction then return nil,baseline end
        local budget=s.cash
        local sales={}
        for id,t in pairs(s.towers) do
            if t.owned and t.type=="Ranger" and t.sellValue and t.sellValue>0 then
                local st=c.ranger.stats(t.path1,t.path2)
                sales[#sales+1]={id=id,price=t.sellValue,value=value(st,c.physics.vec(t.pos),urgent)}
            end
        end
        table.sort(sales,function(a,b) return a.value/math.max(1,a.price)<b.value/math.max(1,b.price) end)
        local allowSale=lethal and s.wave>=12 and (s.wave==#c.economy.config.Waves or soldWave~=s.wave) and not queued
        local saleLimit=s.wave==#c.economy.config.Waves and 2 or 1
        if allowSale then
            for i=1,math.min(saleLimit,#sales) do budget+=sales[i].price end
        end
        local options={}
        local function add(a,st,pos,old)
            if a.price>budget or a.price<=0 then return end
            local gain=value(st,pos,urgent)-(old and value(old,pos,urgent) or 0)
            if gain>0 then
                a.rank=gain/math.max(1,a.price)^0.25
                options[#options+1]=a
            end
        end
        for id,t in pairs(s.towers) do
            if t.owned and t.type=="Ranger" then
                local old=c.ranger.stats(t.path1,t.path2)
                for _,st in ipairs(all) do
                    if st.path1>=t.path1 and st.path2>=t.path2 and st.cost>old.cost then
                        local a=nextStep(t,st,budget)
                        if a then
                            a.price=st.cost-old.cost
                            a.stats=st
                            a.at=0.45+(st.path1-t.path1>0 and st.path2-t.path2>0 and 0.45 or 0)
                            add(a,st,c.physics.vec(t.pos),old)
                        end
                    end
                end
            end
        end
        local positions=near(s,urgent)
        local ranked={}
        for _,pos in ipairs(positions) do
            local rank=0
            for _,st in ipairs({base,c.ranger.stats(1,1),c.ranger.stats(2,3),c.ranger.stats(3,2)}) do
                if st.cost<=budget then rank=math.max(rank,value(st,pos,urgent)/st.cost^0.25) end
            end
            ranked[#ranked+1]={pos=pos,rank=rank}
        end
        table.sort(ranked,function(a,b) return a.rank>b.rank end)
        for i=1,math.min(5,#ranked) do
            local pos=ranked[i].pos
            for _,st in ipairs(all) do
                if st.cost<=budget then
                    add({kind="place",pos=pos,price=st.cost,stats=st,at=0.65+(st.path1>0 and 0.45 or 0)+(st.path2>0 and 0.45 or 0),goal={path1=st.path1,path2=st.path2}},st,pos)
                end
            end
        end
        table.sort(options,function(a,b) return a.rank>b.rank end)
        local best
        local function assess(a)
            local sold={}
            local money=s.cash
            local cap=s.towerCount
            if money<a.price or a.kind=="place" and cap>=(s.towerLimit or 0) then
                if not allowSale then return end
                for _,sale in ipairs(sales) do
                    if sale.id~=a.id and c.executor.available({kind="sell",id=sale.id}) then
                        sold[#sold+1]=sale
                        money+=sale.price
                        cap-=1
                        if money>=a.price and (a.kind~="place" or cap<(s.towerLimit or 0)) then break end
                        if #sold>=saleLimit then break end
                    end
                end
            end
            if money<a.price or a.kind=="place" and cap>=(s.towerLimit or 0) then return end
            local trial=table.clone(sim)
            trial.towers=table.clone(sim.towers)
            for _,v in ipairs(sold) do trial.towers[v.id]=nil end
            local action=table.clone(a)
            action.at=(action.at+#sold*0.45)*(s.speed or 1)
            local r=c.combat.run(trial,routes,c.physics,los,action,h)
            local remaining=r.leaks+r.unknown
            local gain=loss-remaining
            if gain<=0.01 or remaining>=planLoss-0.01 then return end
            if remaining>=s.lives and (#sold>0 or plannedAction or a.kind=="place" and s.wave<#c.economy.config.Waves) then return end
            local score=(remaining<s.lives and 1000000 or 0)+gain*100-#sold*30-a.price*0.002
            if not best or score>best.score then best={a=a,sold=sold,r=r,score=score,loss=remaining} end
        end
        for i=1,math.min(6,#options) do assess(options[i]) end
        if not best then return nil,baseline end
        local a=best.a
        baseline.rescueLoss=best.loss
        local goal={kind=a.kind,id=a.id,pos=a.pos and c.physics.pack(a.pos),path1=a.stats.path1,path2=a.stats.path2,live=true}
        if #best.sold>0 then
            soldWave=s.wave
            queued=goal
            return {kind="sell",id=best.sold[1].id,reason="emergency_fund",predictedLoss=best.loss},baseline
        end
        queued=goal
        if a.kind=="upgrade" then
            local step=nextStep(s.towers[a.id],a.stats,s.cash)
            if step then step.reason="emergency_upgrade" step.predictedLoss=best.loss return pack(step),baseline end
        else
            return {kind="place",pos=goal.pos,price=base.cost,reason="emergency_intercept",predictedLoss=best.loss},baseline
        end
        return nil,baseline
    end

    local function follow(s,goal,ts)
        if not goal then return end
        local st=c.ranger.stats(goal.path1,goal.path2)
        local t=goal.id and s.towers[goal.id]
        if not t and goal.pos then
            for _,v in pairs(s.towers) do
                if v.owned and v.type=="Ranger" and (c.physics.vec(v.pos)-c.physics.vec(goal.pos)).Magnitude<2 then t=v break end
            end
        end
        if goal.live then
            local pos=t and c.physics.vec(t.pos) or goal.pos and c.physics.vec(goal.pos)
            if not pos or value(st,pos,ts or {})<=0 then return nil,true end
        end
        if t then
            if t.path1>=st.path1 and t.path2>=st.path2 then return nil,true end
            if st.path1<t.path1 or st.path2<t.path2 then return nil,true end
            local a=nextStep(t,st,s.cash)
            if a and valid(a,s) then return pack(a) end
        elseif goal.pos then
            local a={kind="place",pos=goal.pos,price=base.cost}
            if valid(a,s) then return a end
        end
    end

    local function spend(s,ts,liveOnly,extraSpots)
        local wi=math.max(1,s.wave)
        local best,rank
        local function check(a,st,pos,old)
            if not valid(a,s) then return end
            local current=value(st,pos,ts)-(old and value(old,pos,ts) or 0)
            local future=0
            for _,r in pairs(routes) do
                local first=math.huge
                local count=0
                for d=0,r.length,3 do
                    local p=c.physics.at(r,d)
                    if (p-pos).Magnitude<=st.range and los(pos,p) then first=math.min(first,d) count+=1 end
                end
                if count>0 then future+=count/(1+first/16) end
            end
            local gain=st.dps-(old and old.dps or 0)
            if st.ignoreResistance and not (old and old.ignoreResistance) then gain+=st.dps*0.8 end
            if st.stealthDetection and not (old and old.stealthDetection) and wi>=6 then gain+=st.dps*1.6 end
            if future<=0 or liveOnly and current<=0 then return end
            local v=(current+(liveOnly and 0 or future*gain*0.35))/math.max(1,a.price)^0.55
            if old then v*=1.6 elseif s.towerCount>=3 then v*=0.35 end
            if not best or v>rank then best,rank=a,v end
        end
        for _,t in pairs(s.towers) do
            if t.owned and t.type=="Ranger" then
                local old=c.ranger.stats(t.path1,t.path2)
                for _,st in ipairs(all) do
                    if st.path1>=t.path1 and st.path2>=t.path2 and st.cost>old.cost then
                        local a=nextStep(t,st,s.cash)
                        if a then check(a,a.stats,c.physics.vec(t.pos),old) end
                    end
                end
            end
        end
        if not best and s.towerCount<(s.towerLimit or 0) and s.cash>=base.cost then
            local n=0
            for _,item in ipairs(extraSpots or spots) do
                local a={kind="place",pos=item.pos,price=base.cost}
                if valid(a,s) then
                    check(a,base,item.pos)
                    n+=1
                    if n>=(liveOnly and 18 or 5) then break end
                end
            end
        end
        if best and rank>0 then return pack(best) end
    end

    function x.plan(s)
        if not s.running or s.difficulty~="Easy" or s.playerCount~=1 or not s.wave then return end
        if s.time-last<0.08 then return end
        last=s.time
        if not prepare(s) then return end
        if not rollout then return {wave=s.wave,revision=s.revision,recommendation={kind="hold",reason="no_validated_plan"},skip={allowed=false,reason="no_validated_plan"},mode="auto"} end
        if skipContinuation and s.wave>skipContinuation.wave and c.executor.skipConfirmed(skipContinuation.wave) then
            local plan=skipContinuation.plan
            local moves={}
            for _,v in ipairs(plan.moves) do if v.wave>=s.wave then moves[#moves+1]=v end end
            rollout.moves=moves
            rollout.history=plan.history
            rollout.skips=plan.skips
            rollout.policy=plan.policy
            cursor=1
            queued=nil
            skipContinuation=nil
        elseif skipContinuation and (s.wave>skipContinuation.wave or s.time-skipContinuation.at>5) then skipContinuation=nil end
        valueCache={}
        local ts=threat(s)
        local w=c.forecast.wave(s.wave)
        local final=s.wave==#c.economy.config.Waves and w and s.waveAge and s.waveAge>=w.last+1
        local planned,plannedAction=false,nil
        while cursor<=#rollout.moves do
            local goal=rollout.moves[cursor]
            if final then goal=table.clone(goal) goal.live=true end
            local v,done=follow(s,goal,ts)
            if done then cursor+=1
            else
                planned=true
                if goal.wave<=s.wave and v then plannedAction=v v.reason="verified_plan" end
                break
            end
        end
        local queuedAction
        if queued then
            local done
            queuedAction,done=follow(s,queued,ts)
            if done then queued=nil end
        end
        local rescue,baseline
        local refreshed=false
        if s.wave>=1 and (s.time-lastEmergency>=0.7 or baselineWave~=s.wave) then
            lastEmergency=s.time
            baselineWave=s.wave
            rescue,baseline=emergency(s,ts,plannedAction,queuedAction)
            cachedBaseline=baseline
            refreshed=true
        else baseline=cachedBaseline end
        local targets
        if refreshed and s.wave>=12 and not rescue and not queuedAction and not plannedAction and baseline and baseline.leaks+baseline.unknown>=s.lives then
            local candidates=c.tactics.target(s,ts,los)
            if candidates and candidates[1] then
                local sim=table.clone(s)
                sim.towers=table.clone(s.towers)
                sim.enemies={}
                for id,e in pairs(s.enemies) do
                    local v=table.clone(e)
                    v.kids=c.forecast.children(e.type)
                    sim.enemies[id]=v
                end
                local h=math.min(66,math.max(5,ts[1] and ts[1].eta+1 or 5))
                for _,q in ipairs(ts) do h=math.max(h,math.min(66,q.eta+0.5)) end
                local initial=c.combat.run(sim,routes,c.physics,los,nil,h)
                local a=candidates[1]
                local t=table.clone(sim.towers[a.id])
                t.query=a.query
                sim.towers[a.id]=t
                local trial=c.combat.run(sim,routes,c.physics,los,nil,h)
                if trial.leaks+trial.unknown+0.01<initial.leaks+initial.unknown then targets={a} end
            end
        end
        local liveSpots
        local function livePositions()
            if not liveSpots then
                liveSpots={}
                for _,p in ipairs(near(s,ts)) do
                    local v=value(base,p,ts)
                    if v>0 then liveSpots[#liveSpots+1]={pos=p,rank=v} end
                end
                table.sort(liveSpots,function(a,b) return a.rank>b.rank end)
            end
            return liveSpots
        end
        local skip={allowed=false,reason=s.wave<1 and "setup" or "priority"}
        local a=rescue or queuedAction or plannedAction
        if not a and final and not planned and not queued then
            a=c.tactics.recycle(s,ts,los)
            if not a then
                a=c.tactics.rebuild(s,ts,los)
                if a then queued=a.goal end
            end
        end
        if not a and not planned and (final or s.wave>=1) and (s.cash>=1500 or #ts>0 and s.cash>=165 or not next(s.towers) or baseline and baseline.leaks>0) then
            local liveOnly=final or #ts>0 and (baseline and baseline.leaks>0 or s.cash<1500)
            a=spend(s,ts,liveOnly,liveOnly and livePositions() or nil)
            if a then a.reason="available_power" end
        end
        if s.wave>=1 and not rescue and not queued and w and s.waveAge and c.executor.canSkip(s) and s.time-lastSkip>=3 and (not a or a.kind=="hold" or rollout.skips and rollout.skips[s.wave] and s.waveAge>=rollout.skips[s.wave]) then
            lastSkip=s.time
            skip=c.goodskip.assess(s,c,routes,los,s.waveAge,spots,nil,search,rollout)
            if skip.allowed and skip.plan then
                skipContinuation={wave=s.wave,at=s.time,plan=skip.plan}
                skip.plan=nil
            end
        end
        local top={}
        for i=1,math.min(3,#ts) do
            local q=ts[i]
            top[i]={id=q.id,type=q.e.type,hp=q.e.hp,eta=q.eta,etaReal=q.eta/math.max(0.01,s.speed or 1),dist=q.d,boss=q.e.boss}
        end
        return {wave=s.wave,revision=s.revision,threats=top,baseline=baseline,recommendation=a or {kind="hold",reason=planned and "saving_for_verified_move" or "no_affordable_useful_action",cash=s.cash,move=planned and cursor or nil},skip=skip,mode="auto",targets=targets,emergency=rescue~=nil or baseline~=nil and baseline.leaks+baseline.unknown>=s.lives,move=cursor,plannedWaveLoss=rollout.history[s.wave] and rollout.history[s.wave].loss,plannedWaveHP=rollout.history[s.wave] and rollout.history[s.wave].lives}
    end
    return x
end
return m
