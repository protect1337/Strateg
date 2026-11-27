local m={}

function m.new(c)
    local x={}
    local routes,los,spots,search,mapKey,rollout
    local last=-math.huge
    local lastSkip=-math.huge
    local lastScan=-math.huge
    local queued
    local all=c.ranger.all()
    local base=c.ranger.stats(0,0)

    local function prepare(s)
        if not s.map or not s.spawnIndices or #s.spawnIndices==0 then return false end
        local key=s.map..":"..table.concat(s.spawnIndices,",")
        if key~=mapKey then
            local team=c.team.GetLocalPlayerTeamIndex() or 1
            routes=c.physics.routes(c.path,team,s.spawnIndices)
            if not next(routes) then return false end
            los=c.physics.los(c.map)
            spots=c.placement.candidates(routes,c.physics,c.placementHandler,c.ranger,team,s,los)
            if #spots==0 then return false end
            search=c.strategy.new(c,routes,los,spots)
            mapKey=key
            rollout=nil
            queued=nil
        end
        return true
    end

    function x.preflight(s,cancel)
        if not prepare(s) then return end
        local init=table.clone(s)
        init.wave=0
        init.cash=c.economy.config.StartingCash
        init.lives=c.economy.config.StartingLives
        init.towers={}
        init.towerCount=0
        init.cancel=cancel
        local first,plan=search.search(init)
        if not plan or plan.to~=#c.economy.config.Waves then return end
        rollout=plan
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
                local t=(r.length-d)/math.max(0.01,e.speed or 0)
                if not e.stopped and not e.stunned and not e.stasis then
                    list[#list+1]={id=id,e=e,r=r,d=d,eta=t,risk=e.hp/math.max(0.5,t)}
                end
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
        for i=1,math.min(4,#ts) do
            local q=ts[i]
            for _,seconds in ipairs({1,3,6,10}) do
                local d=math.min(q.r.length-0.1,q.d+math.max(0,q.e.speed)*seconds)
                local center=c.physics.at(q.r,d)
                for _,radius in ipairs({3.5,6}) do
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
        return out
    end

    local function value(st,pos,ts)
        local score=0
        for i=1,math.min(8,#ts) do
            local q=ts[i]
            local e=q.e
            if not e.air and not e.invulnerable and not e.noDamage and (not e.stealth or st.stealthDetection) then
                local dps=st.dps*(st.ignoreResistance and 1 or 1-math.clamp((e.resist or {})[tostring(st.damageType)] or 0,0,1))
                if st.path2>=4 then dps+=st.path2==5 and 12 or 5 end
                local time=0
                for t=0.5,math.min(25,q.eta),0.75 do
                    local p=c.physics.at(q.r,q.d+(e.speed or 0)*t)
                    if (p-pos).Magnitude<=st.range and los(pos,p) then time+=0.75 end
                end
                score+=math.min(e.hp+(e.shield or 0),dps*time)*(1+e.hp/math.max(1,q.eta)*0.1)
            end
        end
        return score
    end

    local function emergency(s,ts)
        if #ts==0 then return end
        local urgent={}
        for _,q in ipairs(ts) do
            if q.eta<=35 then urgent[#urgent+1]=q end
        end
        if #urgent==0 then return end
        local h=math.min(40,math.max(5,urgent[1].eta+1))
        for _,q in ipairs(urgent) do h=math.max(h,math.min(40,q.eta+0.5)) end
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
        if not lethal and loss<math.max(10,s.lives*0.08) then return nil,baseline end
        local budget=s.cash
        local sales={}
        for id,t in pairs(s.towers) do
            if t.owned and t.type=="Ranger" and t.sellValue and t.sellValue>0 then
                local st=c.ranger.stats(t.path1,t.path2)
                sales[#sales+1]={id=id,price=t.sellValue,value=value(st,c.physics.vec(t.pos),urgent)}
            end
        end
        table.sort(sales,function(a,b) return a.value/math.max(1,a.price)<b.value/math.max(1,b.price) end)
        if lethal then
            for i=1,math.min(3,#sales) do budget+=sales[i].price end
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
                if not lethal then return end
                for _,sale in ipairs(sales) do
                    if sale.id~=a.id and c.executor.available({kind="sell",id=sale.id}) then
                        sold[#sold+1]=sale
                        money+=sale.price
                        cap-=1
                        if money>=a.price and (a.kind~="place" or cap<(s.towerLimit or 0)) then break end
                        if #sold>=3 then break end
                    end
                end
            end
            if money<a.price or a.kind=="place" and cap>=(s.towerLimit or 0) then return end
            local trial=table.clone(sim)
            trial.towers=table.clone(sim.towers)
            for _,v in ipairs(sold) do trial.towers[v.id]=nil end
            local action=table.clone(a)
            action.at+=#sold*0.45
            local r=c.combat.run(trial,routes,c.physics,los,action,h)
            local remaining=r.leaks+r.unknown
            local gain=loss-remaining
            if gain<=0.01 then return end
            local score=(remaining<s.lives and 1000000 or 0)+gain*100-#sold*30-a.price*0.002
            if not best or score>best.score then best={a=a,sold=sold,r=r,score=score,loss=remaining} end
        end
        for i=1,math.min(10,#options) do assess(options[i]) end
        if not best then return nil,baseline end
        local a=best.a
        local goal={kind=a.kind,id=a.id,pos=a.pos and c.physics.pack(a.pos),path1=a.stats.path1,path2=a.stats.path2}
        if #best.sold>0 then
            queued=goal
            return {kind="sell",id=best.sold[1].id,reason="emergency_fund",predictedLoss=best.loss},baseline
        end
        queued=goal
        if a.kind=="upgrade" then
            local step=nextStep(s.towers[a.id],a.stats,s.cash)
            if step then step.reason="emergency_upgrade" return pack(step),baseline end
        else
            return {kind="place",pos=goal.pos,price=base.cost,reason="emergency_intercept"},baseline
        end
        return nil,baseline
    end

    local function follow(s,goal)
        if not goal then return end
        local st=c.ranger.stats(goal.path1,goal.path2)
        local t=goal.id and s.towers[goal.id]
        if not t and goal.pos then
            for _,v in pairs(s.towers) do
                if v.owned and v.type=="Ranger" and (c.physics.vec(v.pos)-c.physics.vec(goal.pos)).Magnitude<2 then t=v break end
            end
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

    local function spend(s,ts)
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
            if st.path2>=4 and (not old or old.path2<st.path2) then gain+=8 end
            local v=(current+future*gain*0.35)/math.max(1,a.price)^0.55
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
        if s.towerCount<(s.towerLimit or 0) and s.cash>=base.cost then
            local n=0
            for _,item in ipairs(spots) do
                local a={kind="place",pos=item.pos,price=base.cost}
                if valid(a,s) then
                    check(a,base,item.pos)
                    n+=1
                    if n>=5 then break end
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
        local ts=threat(s)
        local rescue,baseline=emergency(s,ts)
        local skip={allowed=false,reason="priority"}
        local a=rescue
        if not a and queued then
            local done
            a,done=follow(s,queued)
            if done then queued=nil end
        end
        if not a and rollout then
            for _,goal in ipairs(rollout.moves or {}) do
                if goal.wave<=math.max(1,s.wave+1) then
                    local v,done=follow(s,goal)
                    if v then a=v a.reason="opening_plan" break end
                    if not done and s.cash<250 then break end
                else break end
            end
        end
        if not a and (s.cash>=1500 or not next(s.towers) or baseline and baseline.leaks>0) then
            a=spend(s,ts)
            if a then a.reason="available_power" end
        end
        if not a and not rescue and (not baseline or baseline.leaks+baseline.unknown<s.lives) and c.executor.canSkip(s) and s.time-lastSkip>=2 then
            lastSkip=s.time
            skip=c.goodskip.assess(s,c,routes,los,s.waveAge,spots)
            if skip.allowed and skip.purchase then
                local v=skip.purchase
                if v.kind=="upgrade" and s.towers[v.id] then
                    local t=s.towers[v.id]
                    queued={id=v.id,path1=t.path1+(v.path==1 and 1 or 0),path2=t.path2+(v.path==2 and 1 or 0)}
                elseif v.kind=="place" then queued={pos=v.pos,path1=0,path2=0} end
            end
        end
        return {wave=s.wave,revision=s.revision,baseline=baseline,recommendation=a or {kind="hold",reason="no_affordable_useful_action",cash=s.cash},skip=skip,mode="auto",emergency=rescue~=nil or baseline~=nil and baseline.leaks+baseline.unknown>=s.lives}
    end
    return x
end
return m
