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
    local valueCache=setmetatable({},{__mode="k"})
    local job,finished
    local lastSkipKey
    local lastPreparedWave
    local lastHeavy=-math.huge
    local heavyMs=0
    local lastEmergencyKey
    local function workSlice()
        local j=job
        if not j or j.thread~=coroutine.running() then return end
        if os.clock()-j.sliceAt>=j.budget then
            j.cpu+=os.clock()-j.sliceAt
            local frame=task.wait()
            j.budget=frame>0.010 and 0.0003 or frame>0.006 and 0.00045 or 0.00075
            j.sliceAt=os.clock()
        end
        if j.cancelled then error("strateg_cancelled",0) end
    end
    local function sameDefense(a,b,allowLoss)
        if not a or not b or a.map~=b.map or a.wave~=b.wave or a.towerCount~=b.towerCount or (not allowLoss and b.lives<a.lives-0.01) then return false end
        for id,t in pairs(a.towers) do
            local v=b.towers[id]
            if not v or t.path1~=v.path1 or t.path2~=v.path2 or t.query~=v.query or t.stunned~=v.stunned or t.attackDisabled~=v.attackDisabled then return false end
        end
        return true
    end
    local function launch(kind,s,fn)
        if job then return end
        local j={kind=kind,s=s,cpu=0,sliceAt=os.clock(),budget=0.00075}
        job=j
        task.spawn(function()
            j.thread=coroutine.running()
            j.sliceAt=os.clock()
            local ok,result=xpcall(fn,debug.traceback)
            j.cpu+=os.clock()-j.sliceAt
            heavyMs=j.cpu*1000
            if not j.cancelled then
                if ok then finished={kind=kind,s=s,result=result,wall=os.clock()-s.time,cpu=heavyMs}
                else finished={kind=kind,s=s,error=tostring(result),wall=os.clock()-s.time,cpu=heavyMs} end
            end
            if job==j then job=nil end
        end)
    end
    local queued
    local cursor=1
    local soldWave
    local skipContinuation
    local lastSale=-math.huge
    local lastFinalSpend=-math.huge
    local finalGoal
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
            finalGoal=nil lastSale=-math.huge lastFinalSpend=-math.huge
            if job then job.cancelled=true end
            finished=nil cachedBaseline=nil baselineWave=nil lastEmergencyKey=nil lastSkipKey=nil lastPreparedWave=nil
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
            workSlice()
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

    local function value(st,pos,ts,delay)
        local k=string.format("%.2f:%.2f:%.2f:%d:%d:%.2f:%.2f:%.2f",pos.X,pos.Y,pos.Z,st.path1,st.path2,st.range,st.dps,delay or 0)
        local group=valueCache[ts]
        if not group then group={} valueCache[ts]=group end
        if group[k]~=nil then return group[k] end
        local score=0
        for i=1,math.min(8,#ts) do
            workSlice()
            local q=ts[i]
            local e=q.e
            if not e.air and not e.invulnerable and not e.noDamage and (not e.stealth or st.stealthDetection) then
                local dps=st.dps*(st.ignoreResistance and 1 or 1-math.clamp((e.resist or {})[tostring(st.damageType)] or 0,0,1))
                local time=0
                for t=math.max(0.5,delay or 0),math.min(75,q.eta),1 do
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
        sim.runtimeSlice=workSlice
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
        local expectedLoss=rollout and rollout.history[s.wave] and rollout.history[s.wave].loss or 0
        local deviation=rollout and rollout.history[s.wave] and s.lives<rollout.history[s.wave].lives-20
        if not lethal and not (deviation and loss>math.max(10,expectedLoss)) then return nil,baseline end
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
        if lethal and planLoss<s.lives then return nil,baseline end
        if not lethal and planLoss<=math.max(10,expectedLoss) then return nil,baseline end
        -- Finish an already accepted affordable purchase chain instead of repeatedly replacing it.
        if queuedAction and queueLoss and queueLoss<loss-0.01 then return nil,baseline end
        local budget=s.cash
        local sales={}
        for id,t in pairs(s.towers) do
            workSlice()
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
            workSlice()
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
        -- Use the preflight grid first; cheap geometric filtering avoids a long near() scan.
        local positions={}
        local rough={}
        local maximum=base.range
        for _,st in ipairs(all) do if st.cost<=budget then maximum=math.max(maximum,st.range) end end
        for _,item in ipairs(spots) do
            workSlice()
            local rank=0
            for i=1,math.min(3,#urgent) do
                local q=urgent[i]
                for sec=0,math.min(25,q.eta),3 do
                    if (c.physics.at(q.r,q.d+q.speed*sec)-item.pos).Magnitude<=maximum then rank+=1+q.e.hp/math.max(100,q.eta*20) end
                end
            end
            if rank>0 then rough[#rough+1]={pos=item.pos,rank=rank} end
        end
        table.sort(rough,function(a,b) return a.rank>b.rank end)
        for _,v in ipairs(rough) do
            workSlice()
            if valid({kind="place",pos=v.pos,price=base.cost},s) then positions[#positions+1]=v.pos end
            if #positions>=12 then break end
        end
        if #positions==0 then positions=near(s,urgent) end
        local ranked={}
        for _,pos in ipairs(positions) do
            workSlice()
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
            -- An incremental improvement can be the first part of a rescue;
            -- do not require one purchase to eliminate the entire lethal leak.
            if remaining>=s.lives and #sold>0 then return end
            local score=(remaining<s.lives and 1000000 or 0)+gain*100-#sold*30-a.price*0.002
            if not best or score>best.score then best={a=a,sold=sold,r=r,score=score,loss=remaining} end
        end
        for i=1,math.min(6,#options) do workSlice() assess(options[i]) end
        if not best then return nil,baseline end
        local a=best.a
        baseline.rescueLoss=best.loss
        local goal={kind=a.kind,id=a.id,pos=a.pos and c.physics.pack(a.pos),path1=a.stats.path1,path2=a.stats.path2,live=true}
        if #best.sold>0 then
            return {kind="sell",id=best.sold[1].id,reason="emergency_fund",predictedLoss=best.loss},baseline,goal,true
        end
        if a.kind=="upgrade" then
            local step=nextStep(s.towers[a.id],a.stats,s.cash)
            if step then step.reason="emergency_upgrade" step.predictedLoss=best.loss return pack(step),baseline,goal end
        else
            return {kind="place",pos=goal.pos,price=base.cost,reason="emergency_intercept",predictedLoss=best.loss},baseline,goal
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
            workSlice()
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
            -- Placement and upgrade use the same marginal-value scale.
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

    local function finalInvestment(s,ts)
        if #ts==0 or s.cash<base.cost then return end
        local best
        local speed=math.max(1,s.speed or 1)
        local function consider(action,goal,gain,cost)
            if gain<=0 or cost>s.cash or not action then return end
            -- Money has no terminal value. Prefer earlier useful damage; cost only breaks ties.
            local rank=gain/(1+cost/math.max(1,s.cash)*0.15)
            if not best or rank>best.rank then best={action=pack(action),goal=goal,rank=rank,gain=gain,cost=cost} end
        end
        local function delay(a,b)
            return (0.25+(math.max(0,a)+math.max(0,b))*0.25)*speed
        end
        for _,t in pairs(s.towers) do
            workSlice()
            if t.owned and t.type=="Ranger" then
                local old=c.ranger.stats(t.path1,t.path2)
                local pos=c.physics.vec(t.pos)
                local current=value(old,pos,ts)
                for _,st in ipairs(all) do
                    workSlice()
                    if st.path1>=t.path1 and st.path2>=t.path2 and st.cost>old.cost and st.cost-old.cost<=s.cash then
                        local action=nextStep(t,st,s.cash)
                        if action then
                            local gain=value(st,pos,ts,delay(st.path1-t.path1,st.path2-t.path2))-current
                            consider(action,{id=t.id,pos=t.pos,path1=st.path1,path2=st.path2,live=true},gain,st.cost-old.cost)
                        end
                    end
                end
            end
        end
        if s.towerCount<(s.towerLimit or 0) then
            local goals={}
            for _,st in ipairs(all) do
                if st.cost<=s.cash then goals[#goals+1]=st end
            end
            local maxRange=base.range
            for _,st in ipairs(goals) do maxRange=math.max(maxRange,st.range) end
            local seen={}
            local short={}
            local samples={}
            for i=1,math.min(4,#ts) do
                local q=ts[i]
                local points={}
                for sec=0,math.min(75,q.eta),3 do points[#points+1]=c.physics.at(q.r,q.d+q.speed*sec) end
                samples[#samples+1]={q=q,points=points}
            end
            local function add(pos)
                workSlice()
                local key=string.format("%.2f:%.2f:%.2f",pos.X,pos.Y,pos.Z)
                if seen[key] then return end
                seen[key]=true
                local rough=0
                for _,g in ipairs(samples) do
                    for _,point in ipairs(g.points) do
                        if (point-pos).Magnitude<=maxRange then rough+=1 end
                    end
                end
                if rough>0 then short[#short+1]={pos=pos,rank=rough} end
            end
            for _,v in ipairs(spots) do add(v.pos) end
            -- Reuse the preflight grid first; add legal forward placements when its coverage is exhausted.
            table.sort(short,function(a,b) return a.rank>b.rank end)
            local tested=0
            local function assess(list)
                for _,v in ipairs(list) do
                    workSlice()
                    local action={kind="place",pos=v.pos,price=base.cost}
                    if valid(action,s) then
                        tested+=1
                        for _,st in ipairs(goals) do
                            workSlice()
                            local gain=value(st,v.pos,ts,delay(st.path1,st.path2)+0.45*speed)
                            consider(action,{pos=c.physics.pack(v.pos),path1=st.path1,path2=st.path2,live=true},gain,st.cost)
                        end
                        if tested>=12 then break end
                    end
                end
            end
            assess(short)
            if tested<4 or not best then
                short={}
                for _,pos in ipairs(near(s,ts)) do add(pos) end
                table.sort(short,function(a,b) return a.rank>b.rank end)
                assess(short)
            end
        end
        return best
    end

    function x.stop()
        if job then job.cancelled=true end
        finished=nil
    end
    function x.grenades(s,offset,reserved,focus)
        if not routes or not los then return {},offset,{} end
        return c.ability.rank(s,c.physics,los,routes,4,offset,reserved,focus)
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
        if job and not sameDefense(job.s,s,job.kind=="emergency") and (job.kind~="final_invest" or job.s.wave~=s.wave or job.s.map~=s.map or s.lives<job.s.lives) then job.cancelled=true end
        local ts=threat(s)
        local w=c.forecast.wave(s.wave)
        local final=s.wave==#c.economy.config.Waves and w and s.waveAge and s.waveAge>=w.last+1
        local planned,plannedAction=false,nil
        while cursor<=#rollout.moves do
            local goal=rollout.moves[cursor]
            if final and not goal.finalChain then goal=table.clone(goal) goal.live=true end
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
        local investmentAction
        if final and finalGoal then
            local done
            investmentAction,done=follow(s,finalGoal,ts)
            if done then finalGoal=nil end
            if investmentAction then investmentAction.reason="final_investment_chain" end
        elseif not final then finalGoal=nil end
        local baseline=cachedBaseline
        if baselineWave~=s.wave then baseline=nil cachedBaseline=nil end
        local a=queuedAction or investmentAction or plannedAction
        local skip={allowed=false,reason=job and "analysis_running" or "priority"}
        local targets
        local errorMessage
        local result=finished
        finished=nil
        if result then
            local ttl=result.kind=="skip" and 8 or result.kind=="emergency" and 4 or result.kind=="final_invest" and 5 or 2
            local fresh=(sameDefense(result.s,s,result.kind=="emergency") or result.kind=="final_invest" and final and result.s.wave==s.wave and result.s.map==s.map and s.lives>=result.s.lives) and s.time-result.s.time<=ttl
            if result.error then errorMessage=result.error
            elseif fresh and result.result then
                local v=result.result
                if result.kind=="emergency" then
                    baseline=v.baseline
                    cachedBaseline=baseline baselineWave=s.wave
                    if v.action and valid(v.action,s) then
                        a=v.action queued=v.goal
                        if v.sold then soldWave=s.wave end
                    elseif not a and v.targets then targets=v.targets end
                elseif result.kind=="skip" then
                    skip=v
                    if skip.allowed and (skip.plan or skip.prepared) and c.executor.canSkip(s) and s.timerRemaining and s.timerRemaining>3.5*(s.speed or 1)+0.5 then
                        local hp=0
                        for _,e in pairs(s.enemies) do hp+=e.hp+(e.shield or 0) end
                        if hp<=skip.threat+math.max(8,skip.threat*0.05) and s.lives>=skip.lives then
                            if skip.plan then skipContinuation={wave=s.wave,at=s.time,plan=skip.plan} end
                        else skip.allowed=false skip.reason="forecast_changed" end
                    else if skip.allowed then skip.reason="vote_window_closed" end skip.allowed=false end
                    skip.plan=nil
                elseif result.kind=="final_invest" and final and not finalGoal and v.goal then
                    local candidate,done=follow(s,v.goal,ts)
                    if candidate and not done and valid(candidate,s) then
                        local old=v.goal.id and s.towers[v.goal.id]
                        local price=c.ranger.stats(v.goal.path1,v.goal.path2).cost-(old and c.ranger.stats(old.path1,old.path2).cost or 0)
                        if price<=s.cash then
                            finalGoal=v.goal
                            candidate.reason="final_investment"
                            if not queuedAction then a=candidate end
                        end
                    end
                elseif result.kind=="spend" and not a and not planned and v.action and valid(v.action,s) then
                    a=v.action queued=v.goal
                end
            end
        end
        local urgent=false
        local nearest=math.huge
        local threatHP=0
        for _,q in ipairs(ts) do
            if q.eta<=25 then threatHP+=q.e.hp nearest=math.min(nearest,q.eta) end
        end
        local expected=rollout.history[s.wave]
        local behind=expected and s.lives+0.01<expected.lives
        local projectedDanger=0
        for _,q in ipairs(ts) do if q.eta<=45 then projectedDanger+=q.e.hp end end
        urgent=threatHP>0 and (nearest<=10 or threatHP>=s.lives or behind) or behind and projectedDanger>=math.max(50,s.lives*0.35)
        -- Never spend a skip budget while a real defense mismatch is developing.
        if urgent and job and (job.kind=="skip" or job.kind=="spend") then job.cancelled=true end
        if urgent then skip.allowed=false skip.reason="emergency_priority" end
        local emergencyKey=string.format("%d:%d:%d:%d",s.wave,s.towerCount,math.floor(s.lives/10),math.floor(threatHP/100))
        local levels=0
        for _,t in pairs(s.towers) do levels+=(t.path1 or 0)+(t.path2 or 0) end
        local plannedSkip=rollout.skips and rollout.skips[s.wave]
        local plannedDue=plannedSkip and s.waveAge and s.waveAge+3.5*(s.speed or 1)>=plannedSkip
        local preparedDue=plannedDue and lastPreparedWave~=s.wave
        if preparedDue and job and job.s.wave==s.wave and (job.kind=="spend" or job.kind=="skip" and job.s.waveAge+3.5*(job.s.speed or 1)<plannedSkip) then job.cancelled=true end
        local skipKey=string.format("%d:%d:%d:%d:%d",s.wave,s.towerCount,levels,math.floor(s.lives/10),math.floor(s.cash/500))
        local skipChanged=preparedDue or skipKey~=lastSkipKey or s.time-lastSkip>=2
        -- A prepared time is a candidate, not a prohibition on earlier votes.
        local dueSkip=s.wave>=1 and s.wave<#c.economy.config.Waves and w and s.waveAge and c.executor.canSkip(s) and s.timerRemaining and s.timerRemaining>3.5*(s.speed or 1)+1
            and s.waveAge+3.5*(s.speed or 1)>=w.last+0.25
            and next(s.enemies)~=nil
        if not job and not skip.allowed and not errorMessage then
            if final and not finalGoal and #ts>0 and s.cash>=base.cost and s.time-lastFinalSpend>=0.5 then
                lastFinalSpend=s.time
                launch("final_invest",s,function() return finalInvestment(s,ts) end)
            elseif urgent and s.time-lastEmergency>=1 and (emergencyKey~=lastEmergencyKey or s.time-lastEmergency>=2) then
                lastEmergency=s.time lastEmergencyKey=emergencyKey
                launch("emergency",s,function()
                    local action,b,goal,sold=emergency(s,ts,plannedAction,queuedAction)
                    local targetActions
                    if not action and not plannedAction and not queuedAction and s.wave>=12 and b and b.leaks+b.unknown>=s.lives then
                        local options=c.tactics.target(s,ts,los,workSlice)
                        if options and options[1] then
                            local sim=table.clone(s)
                            sim.runtimeSlice=workSlice
                            sim.towers=table.clone(s.towers)
                            sim.enemies={}
                            for id,e in pairs(s.enemies) do
                                workSlice()
                                local v=table.clone(e) v.kids=c.forecast.children(e.type)
                                sim.enemies[id]=v
                            end
                            local h=math.min(66,math.max(5,ts[1] and ts[1].eta+1 or 5))
                            for _,q in ipairs(ts) do h=math.max(h,math.min(66,q.eta+0.5)) end
                            local initial=c.combat.run(sim,routes,c.physics,los,nil,h)
                            local candidate=options[1]
                            local t=table.clone(sim.towers[candidate.id])
                            t.query=candidate.query sim.towers[candidate.id]=t
                            local trial=c.combat.run(sim,routes,c.physics,los,nil,h)
                            if trial.leaks+trial.unknown+0.01<initial.leaks+initial.unknown then targetActions={candidate} end
                        end
                    end
                    return {action=action,baseline=b,goal=goal,sold=sold,targets=targetActions}
                end)
            elseif dueSkip and not urgent and not queued and skipChanged and (preparedDue or s.time-lastSkip>=1.5) and (not a or plannedDue) then
                lastSkip=s.time lastSkipKey=skipKey
                if plannedDue then lastPreparedWave=s.wave end
                local snap=table.clone(s)
                local moveIndex=cursor
                snap.runtimeSlice=workSlice
                launch("skip",s,function()
                    return c.goodskip.assess(snap,c,routes,los,s.waveAge,spots,nil,search,rollout,moveIndex)
                end)
            elseif not a and not planned and s.wave>=1 and s.time-lastHeavy>=1.5 and (s.cash>=1500 or #ts>0 and s.cash>=165 or not next(s.towers) or baseline and baseline.leaks>0) then
                lastHeavy=s.time
                launch("spend",s,function()
                    local v
                    if final then
                        v=c.tactics.rebuild(s,ts,los,workSlice)
                        if v then return {action=v,goal=v.goal} end
                    end
                    local liveOnly=final or #ts>0 and (baseline and baseline.leaks>0 or s.cash<1500)
                    local extra
                    if liveOnly then
                        extra={}
                        for _,p in ipairs(near(s,ts)) do
                            workSlice()
                            local rank=value(base,p,ts)
                            if rank>0 then extra[#extra+1]={pos=p,rank=rank} end
                        end
                        table.sort(extra,function(a,b) return a.rank>b.rank end)
                    end
                    v=spend(s,ts,liveOnly,extra)
                    if v then v.reason="available_power" end
                    return {action=v}
                end)
            end
        end
        -- Independent bounded sale scan; do not wait for the expensive investment search.
        -- The existing confirmed action dispatcher remains the single authority for spending.
        if final and s.time-lastSale>=0.25 then
            local sales=c.tactics.safeSales(s,routes,all,16)
            for _,sale in ipairs(sales) do
                if not a and valid(sale,s) and (not finalGoal or finalGoal.id~=sale.id) then
                    a=sale
                    lastSale=s.time
                    break
                end
            end
        end
        local top={}
        for i=1,math.min(3,#ts) do
            local q=ts[i]
            top[i]={id=q.id,type=q.e.type,hp=q.e.hp,eta=q.eta,etaReal=q.eta/math.max(0.01,s.speed or 1),dist=q.d,boss=q.e.boss}
        end
        return {wave=s.wave,revision=s.revision,threats=top,baseline=baseline,recommendation=a or {kind="hold",reason=urgent and "emergency_search" or planned and "saving_for_verified_move" or "no_affordable_useful_action",cash=s.cash,move=planned and cursor or nil},skip=skip,mode="auto",targets=targets,emergency=urgent,analysis=job and job.kind or result and result.kind,analysisMs=result and result.cpu,analysisWall=result and result.wall,analysisError=errorMessage,move=cursor,plannedGrenadeCasts=rollout.history[s.wave] and rollout.history[s.wave].grenadeCasts,plannedWaveLoss=rollout.history[s.wave] and rollout.history[s.wave].loss,plannedWaveHP=rollout.history[s.wave] and rollout.history[s.wave].lives}
    end
    return x
end
return m
