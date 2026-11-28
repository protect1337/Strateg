local m={version="adaptive-v26"}

function m.new(c,routes,los,spots)
    local x={}
    local cfg=c.economy.config
    local maxWave=#cfg.Waves
    local stats={}
    local base=c.ranger.stats(0,0)
    local radius=base.radius or 1.5
    local spacing=radius*2+0.05
    for _,v in ipairs(c.ranger.all()) do stats[v.path1*10+v.path2]=v end
    local maxRange=base.range
    for _,st in pairs(stats) do maxRange=math.max(maxRange,st.range) end
    local abilityCatalog=c.ability.catalog(c.resources)
    local function grenadeSpec(st)
        if st.path2<4 then return nil end
        local name=st.path2==5 and "GrenadeLevel2" or "GrenadeLevel1"
        return c.ability.spec(name,abilityCatalog[name],st.range)
    end
    local profiles={}
    local routePoints={}
    for idx,r in pairs(routes) do
        local p={}
        for d=0,math.ceil(r.length) do p[d]=c.physics.at(r,d) end
        routePoints[idx]=p
    end
    local function profile(pos,range,idx,slice)
        local k=string.format("%.3f:%.3f:%.3f:%.2f:%s",pos.X,pos.Y,pos.Z,range,tostring(idx))
        if profiles[k] then return profiles[k] end
        local hit={}
        local length,first=0,math.huge
        for d,p in pairs(routePoints[idx]) do
            if slice and d%32==0 then slice() end
            if (p-pos).Magnitude<=range-0.2 and los(pos,p) then
                hit[d]=true
                length+=1
                first=math.min(first,d)
            end
        end
        local v={hit=hit,length=length,first=first}
        profiles[k]=v
        return v
    end
    local function tail(p,d,stride,last)
        local key="tail"..stride
        local a=p[key]
        if not a then
            a={}
            for i=last,0,-1 do a[i]=(p.hit[i] and stride or 0)+(a[i+stride] or 0) end
            p[key]=a
        end
        return a[d] or 0
    end
    local siteProfiles={}
    local function path(st,upper,cross)
        local a,b=st.path1,st.path2
        if b<1 then return stats[a*10+b+1] end
        if a<2 then return stats[(a+1)*10+b] end
        if cross and b<2 then return stats[a*10+b+1] end
        if upper and a<5 then return stats[(a+1)*10+b] end
        if not upper and b<5 then return stats[a*10+b+1] end
        if upper and b<2 then return stats[a*10+b+1] end
    end
    local function bossKids(name)
        local out={}
        local ok,ability=pcall(c.resources.GetEnemyAbilityConfig,name)
        if not ok or not ability then return out end
        for _,g in ipairs(ability.SpawnEnemies or {}) do
            local ok2,v=pcall(c.resources.GetEnemyConfig,g.EnemyType)
            if ok2 and v then
                local resist={}
                for _,d in pairs(v.DamageReductionTable or {}) do resist[tostring(d.DamageType)]=d.DamageReduction end
                for i=1,g.Count or 0 do
                    out[#out+1]={type=g.EnemyType,hp=v.Health,shield=v.Shield or 0,speed=v.Speed,resist=resist,noCash=v.NoCash,stealth=v.Stealth,air=v.AirUnit,offset=g.MaxSpawnOffsetStuds or 0}
                end
            end
        end
        return out
    end
    local summon1=bossKids("PlagueDoctorSummonFirst")
    local summon2=bossKids("PlagueDoctorSummon")
    local bossDataOK=#summon1==15 and #summon2==14
    local policies={}
    for i=1,24 do
        policies[i]={core=1+(i-1)%3,upper=i%4~=0,mix=i%4==0 or i%5==0,crossEarly=i%3==0,depth=16+(i%6)*12,longRange=0.35+(i%4)*0.18,seed=i*31,risk=0.7+(i%5)*0.14,fast=i%3~=0,earlySkip=i%4==0,skipDelay=({0,2,5,10,20,35})[(i-1)%6+1],placeBias=0.65+(i%5)*0.25,focus=1+(i%4)*0.25}
    end
    local oldPolicies=table.clone(policies)
    for i=1,24 do
        local p=table.clone(oldPolicies[i])
        p.allocator=1
        p.placeBias=({0.7,1,1.3})[(i-1)%3+1]
        p.focus=({0.7,1,1.5,2})[(i-1)%4+1]
        p.capitalHorizon=({18,30,45,65})[(i-1)%4+1]
        p.fast=i%4~=3
        p.earlySkip=false
        p.skipDelay=({0,5,12,25})[(i-1)%4+1]
        policies[i]=p
    end
    for i=1,12 do
        local p=table.clone(oldPolicies[i])
        p.allocator=2
        p.placeBias=0.45+(i%4)*0.15
        p.fast=i%3~=0
        p.earlySkip=false
        policies[#policies+1]=p
    end
    local capital=table.clone(policies)
    policies={}
    for i=1,24 do
        if i<=12 then policies[#policies+1]=capital[24+i] end
        policies[#policies+1]=capital[i]
        policies[#policies+1]=oldPolicies[i]
    end
    -- Explore investment-chain policies before the broad legacy search.
    local focused={}
    for i=1,24 do
        focused[i]={allocator=3,core=1+(i-1)%3,upper=i%4==0,mix=i%4==3,crossEarly=i%3==0,depth=({18,40,75,110})[(i-1)%4+1],longRange=0.35+(i%4)*0.18,seed=i*71,risk=0.8+(i%4)*0.2,fast=false,earlySkip=false,skipDelay=0,placeBias=0.75+(i%3)*0.15,focus=1.5,capitalHorizon=45,grenades=true,legacySite=i%3==0}
    end
    for _,p in ipairs(policies) do p.legacySite=true p.grenades=true focused[#focused+1]=p end
    policies=focused
    local dt=0.05
    local earlyLimit=cfg.StartingLives*0.10
    local stressEarlyLimit=cfg.StartingLives*0.15
    local function settings(policy,wi)
        local a=policy
        for _,patch in ipairs(policy.repairs or {}) do
            if wi>=patch.from and wi<=patch.to then a=patch end
        end
        return a
    end
    local function sameSettings(a,b)
        if a==b then return true end
        for k,v in pairs(a) do if k~="repairs" and k~="skipAges" and b[k]~=v then return false end end
        for k,v in pairs(b) do if k~="repairs" and k~="skipAges" and a[k]~=v then return false end end
        return true
    end
    local function copyList(a)
        local b={}
        for i,v in ipairs(a) do b[i]=table.clone(v) end
        return b
    end
    local function copyState(a)
        local b=table.clone(a)
        b.towers=copyList(a.towers)
        b.enemies=copyList(a.enemies)
        b.moves=table.clone(a.moves)
        b.history=table.clone(a.history)
        b.skips=table.clone(a.skips)
        return b
    end
    local prepared
    local function simulate(s,idx,policy,stress,replay,notify,parent,keep,replaySkips,live)
        local r=routes[idx]
        local slice=s.runtimeSlice
        local function pause() if slice then slice() end end
        local z={cash=cfg.StartingCash,lives=cfg.StartingLives,towers={},enemies={},moves={},history={},skips={},time=0,loss=0,earlyLoss=0,spent=0,income=0,bonuses=0}
        local cap=(s.towerLimit and s.towerLimit>0) and s.towerLimit or 140
        local cursor=1
        local blockedMove
        local serial=0
        local nextBuy=0
        local unknown=0
        local sludge={}
        local pending={}
        local fires={}
        local danger=0
        local hpDamage,shieldDamage,paidDamage,sludgeHits=0,0,0,0
        local checkpoints={}
        local firstWave=1
        local initialCash=cfg.StartingCash
        local last=math.ceil(r.length)
        if not live and keep and parent and policy.grenades==parent.p.grenades then
            for wi=0,maxWave-1 do
                local cp=parent.checkpoints[wi]
                if not cp or not sameSettings(settings(policy,wi),settings(parent.p,wi)) or (policy.skipAges and policy.skipAges[wi])~=(parent.p.skipAges and parent.p.skipAges[wi]) then break end
                checkpoints[wi]=cp
                firstWave=wi+1
            end
            local cp=checkpoints[firstWave-1]
            if cp then
                z=copyState(cp.z)
                sludge=copyList(cp.sludge)
                pending=copyList(cp.pending)
                fires=copyList(cp.fires)
                danger=cp.danger or 0
                serial,nextBuy,unknown=cp.serial,cp.nextBuy,cp.unknown
                hpDamage,shieldDamage,paidDamage,sludgeHits=cp.hpDamage,cp.shieldDamage,cp.paidDamage,cp.sludgeHits
            end
        end
        local function checkpoint(wi)
            if not keep then return end
            checkpoints[wi]={z=copyState(z),sludge=copyList(sludge),pending=copyList(pending),fires=copyList(fires),danger=danger,serial=serial,nextBuy=nextBuy,unknown=unknown,hpDamage=hpDamage,shieldDamage=shieldDamage,paidDamage=paidDamage,sludgeHits=sludgeHits}
        end
        local function add(e,d)
            local a=table.clone(e)
            serial+=1
            a.id=serial
            a.dist=math.clamp(d or 0,0,r.length)
            a.speed=(a.speed or 1)*(stress and 1.05 or 1)
            a.shield=a.shield or 0
            a.cashLeft=a.hp
            if stress and a.complex and a.type~="Plague Doctor" then a.hp*=1.1 end
            if a.type=="Plague Doctor" and not bossDataOK then unknown+=1 end
            a.resist=a.resist or {}
            a.born=z.time
            a.healAt=z.time+12+0.9167
            a.summonAt=z.time+7+0.75
            a.smokeAt=math.huge
            a.summons=0
            a.smoke=false
            a.maxHp=a.maxHp or a.hp
            z.enemies[#z.enemies+1]=a
        end
        local function free(pos)
            for _,t in ipairs(z.towers) do if (t.pos-pos).Magnitude<spacing-0.01 then return false end end
            return true
        end
        local nearest={}
        local indexed=0
        local function site(wi,urgent)
            local best,score
            local opt=settings(policy,wi)
            local list=siteProfiles[idx]
            if not list then
                list={}
                for i,item in ipairs(spots) do
                    local p=item.pos
                    local a=profile(p,base.range,idx,slice)
                    local b=profile(p,maxRange,idx,slice)
                    if b.length>0 then list[#list+1]={i=i,pos=p,a=a,b=b,legacy=profile(p,20,idx,slice)} end
                end
                siteProfiles[idx]=list
            end
            for j=indexed+1,#z.towers do
                local pos=z.towers[j].pos
                for i,item in ipairs(list) do nearest[i]=math.min(nearest[i] or math.huge,(pos-item.pos).Magnitude) end
            end
            indexed=#z.towers
            local liveStarts={}
            local useLive=urgent or wi==maxWave
            if useLive then
                for _,e in ipairs(z.enemies) do
                    if not e.dead then
                        local d=math.floor(e.dist+0.5)
                        liveStarts[d]=(liveStarts[d] or 0)+(e.type=="Plague Doctor" and 3 or 1)
                    end
                end
            end
            for i,item in ipairs(list) do
                if i%16==0 then pause() end
                local p=item.pos
                local near=nearest[i] or math.huge
                if near>=spacing-0.01 then
                    local a,b=item.a,opt.legacySite and item.legacy or item.b
                    if a.length>0 then
                        local density=near==math.huge and 1 or 1+0.55/(1+math.max(0,near-spacing)/spacing)
                        local depth=opt.depth or (opt.siteMode==2 and 40 or opt.siteMode==3 and 65 or 17)
                        local early=1/(1+a.first/math.max(1,wi<8 and depth or (opt.legacySite and 55 or depth*1.5)))
                        local v=(a.length+b.length*(opt.longRange or 0.55))*early*density
                        if opt.seed then v*=1+0.12*math.sin(item.i*12.9898+opt.seed*78.233) end
                        if useLive then
                            local reach=0
                            local baseReach=0
                            local live=0
                            for d,weight in pairs(liveStarts) do
                                live+=1
                                reach+=tail(b,d,3,last)*weight/3
                                baseReach+=tail(a,d,3,last)*weight/3
                            end
                            if (urgent or wi==maxWave) and live>0 then
                                v=(baseReach+reach*(opt.legacySite and 0.35 or opt.longRange or 0.35))*density
                                if opt.seed and not opt.legacySite then v*=1+0.12*math.sin(item.i*12.9898+opt.seed*78.233) end
                            else
                                v*=1+math.min(3,reach*0.07)
                            end
                        end
                        if v>0 and (not score or v>score) then best,score=p,v end
                    end
                end
            end
            return best
        end
        local function install(pos,upper)
            if not pos or not free(pos) or z.cash<base.cost or #z.towers>=cap then return false end
            z.cash-=base.cost
            z.spent+=base.cost
            local t={pos=pos,st=base,profile=profile(pos,base.range,idx,slice),upper=upper,nextShot=z.time+0.45,left=base.burstSize,active=z.time+0.45}
            z.towers[#z.towers+1]=t
            return t,base.cost
        end
        local function upgrade(t,st)
            local cost=st.cost-t.st.cost
            if cost<=0 or cost>z.cash then return false end
            if st.path1<t.st.path1 or st.path2<t.st.path2 then return false end
            z.cash-=cost
            z.spent+=cost
            if st.path2==5 and t.st.path2<5 then t.fireAt=z.time+0.3 end
            if st.path2>=4 and t.st.path2<st.path2 then t.grenadeAt=z.time+0.3 end
            t.grenadeSpec=grenadeSpec(st)
            t.st=st
            t.liveAbility=false
            t.profile=profile(t.pos,st.range,idx,slice)
            t.left=st.burstSize
            t.active=z.time+0.3
            t.nextShot=math.max(t.active,math.min(t.nextShot,z.time+st.reload))
            t.lastShot=nil
            return t,cost
        end
        local function purchase(wi,age)
            pause()
            if z.cash<165 then return end
            if replay then
                local a=replay[cursor]
                if not a or a.wave>wi or a.wave==wi and (a.age or 0)>age+1e-6 then return end
                local p=c.physics.vec(a.pos)
                local t
                for _,v in ipairs(z.towers) do if (v.pos-p).Magnitude<0.1 then t=v break end end
                local st=stats[a.path1*10+a.path2]
                if not st then return end
                local success
                if t then success=upgrade(t,st) elseif st.cost==base.cost then success=install(p,a.upper) end
                if success then cursor+=1 blockedMove=nil
                else blockedMove={wave=wi,age=age,index=cursor,required=t and st.cost-t.st.cost or st.cost,cash=z.cash,pos=a.pos,path1=a.path1,path2=a.path2} end
                return
            end
            local opt=settings(policy,wi)
            local need=math.clamp(opt.core or 2,1,wi<=5 and 3 or math.min(cap,12))
            local elapsed=math.max(dt,z.time-(z.cashSampleAt or z.time-dt))
            local earned=math.max(0,z.income-(z.cashSampleIncome or z.income))
            local alpha=1-math.exp(-elapsed/6)
            z.cashRate=(z.cashRate or 0)*(1-alpha)+earned/elapsed*alpha
            z.cashSampleAt=z.time
            z.cashSampleIncome=z.income
            local t,cost
            local function build(urgent)
                local upper=opt.upper~=false
                if opt.mix and #z.towers%3==1 then upper=not upper end
                if opt.forceUpper~=nil then upper=opt.forceUpper end
                return install(site(wi,urgent),upper)
            end
            -- Count potential individual shots during the enemy's remaining exposure.
            local function impact(st,p,e,d)
                if not st or not p or e.air or e.stealth and not st.stealthDetection then return 0 end
                local speed=math.max(0.1,e.speed or 1)
                if (e.sludgeUntil or 0)>z.time then speed*=1.8 end
                local seconds=tail(p,d,1,last)/speed
                local n=math.max(1,st.burstSize or 1)
                local interval=math.max(dt,st.burstInterval or dt)
                local cycle=math.max(dt,st.reload)+(n-1)*interval
                local bursts=math.floor(seconds/cycle)
                local rem=seconds-bursts*cycle
                local shots=bursts*n+math.min(n,math.floor(rem/interval+1e-6)+1)
                if seconds<=0 then shots=0 end
                local resist=st.ignoreResistance and 0 or math.clamp((e.resist or {})[tostring(st.damageType)] or 0,0,1)
                local damage=st.damage*(1-resist)*(1-math.clamp(e.allReduction or 0,0,1))
                if e.maxDamage and e.maxDamage>=0 then damage=math.min(damage,e.maxDamage) end
                return damage*shots
            end
            local urgent={}
            danger=0
            local congestion=0
            for _,e in ipairs(z.enemies) do
                pause()
                if not e.dead and not e.air then
                    congestion+=1
                    local d=math.floor(e.dist+0.5)
                    local demand=e.hp+(e.shield or 0)+(e.extra or 0)
                    local capacity=0
                    for _,v in ipairs(z.towers) do capacity+=impact(v.st,v.profile,e,d) end
                    local share=1+math.max(0,congestion-1)*0.14
                    local ratio=demand/math.max(1,capacity/share)
                    local weight=1+(d/math.max(1,r.length))^2*3
                    danger=math.max(danger,ratio*weight)
                    urgent[#urgent+1]={e=e,d=d,ratio=ratio,weight=weight}
                end
            end
            table.sort(urgent,function(a,b) return a.ratio*a.weight>b.ratio*b.weight end)
            while #urgent>8 do table.remove(urgent) end
            local threatened=danger>(opt.risk or 1.0)
            local function merit(st,pos,p)
                local value=0
                for _,q in ipairs(urgent) do
                    local v=impact(st,p,q.e,q.d)
                    value+=math.min(q.e.hp+(q.e.shield or 0)+(q.e.extra or 0),v)*q.weight*(0.2+math.min(3,q.ratio))
                end
                local key=wi*100+st.path1*10+st.path2
                p.future=p.future or {}
                local cached=p.future[key]
                if not cached then
                    local future,norm=0,0
                    for offset=0,2 do
                        local w=c.forecast.wave(math.max(1,wi)+offset)
                        if w then
                            local weight=1/(1+offset)
                            local total=0
                            for _,g in ipairs(w.groups or {}) do
                                local hp=g.hp+(g.shield or 0)+(g.extra or 0)
                                local n=g.count or 1
                                local v=impact(st,p,g,0)
                                local exposure=p.length/math.max(0.1,g.speed)
                                local concurrent=math.max(1,n*exposure/math.max(1,(g.last or 0)-(g.first or 0)+exposure))
                                total+=n*math.min(hp,v/concurrent)
                            end
                            future+=weight*total/math.max(1,w.count or #w.events)
                            norm+=weight
                        end
                    end
                    cached={value=future/math.max(1,norm)+st.dps*p.length/math.max(1,r.length)*0.8,norm=math.max(1,norm)}
                    p.future[key]=cached
                end
                return value/cached.norm+cached.value
            end
            -- At the end of the match a saved dollar has no value. Compare
            -- funded chains by damage deliverable AFTER their construction time.
            -- Preserve the same individual purchases in the verified replay.
            if wi==maxWave and #urgent>0 then
                local bestChain
                local function reachable(st,p,delay)
                    local value=0
                    for _,q in ipairs(urgent) do
                        local e=q.e
                        local speed=math.max(0.1,e.speed or 1)
                        if (e.sludgeUntil or 0)>z.time then speed*=1.8 end
                        local d=math.min(last,math.floor(e.dist+speed*delay+0.5))
                        if d<last then
                            local damage=impact(st,p,e,d)
                            local demand=e.hp+(e.shield or 0)
                            local g=grenadeSpec(st)
                            if g and not g.manual and not g.passive and not g.custom and not (e.stealth and not st.stealthDetection) then
                                local sec=tail(p,d,1,last)/speed
                                local casts=math.floor(math.max(0,sec-1)/g.cooldown)
                                damage+=casts*g.damage*(g.estimated and 0.65 or 1)
                            end
                            value+=math.min(demand,damage)*q.weight*(e.type=="Plague Doctor" and 2 or 1)
                        end
                    end
                    return value
                end
                local function chainStep(old,goal,pos)
                    local a,b=old.path1,old.path2
                    local best,rank
                    for _,step in ipairs({goal.path1>a and stats[(a+1)*10+b] or false,goal.path2>b and stats[a*10+b+1] or false}) do
                        if step and step.cost>old.cost then
                            local gain=reachable(step,profile(pos,step.range,idx,slice),0.45)-reachable(old,profile(pos,old.range,idx,slice),0.45)
                            local value=gain+step.dps*0.001
                            if not best or value>rank then best,rank=step,value end
                        end
                    end
                    return best
                end
                local function consider(v,pos,goal,step,upper)
                    local old=v and v.st
                    local price=goal.cost-(old and old.cost or 0)
                    if price<=0 or price>z.cash then return end
                    local count=goal.path1+goal.path2-(old and old.path1+old.path2 or 0)+(v and 0 or 1)
                    local delay=0.45*count
                    local gain=reachable(goal,profile(pos,goal.range,idx,slice),delay)-(old and reachable(old,v.profile,delay) or 0)
                    if gain<=0 then return end
                    local rank=gain/(1+price/math.max(1,z.cash)*0.15)
                    if not bestChain or rank>bestChain.rank then bestChain={v=v,pos=pos,goal=goal,step=step,upper=upper,rank=rank} end
                end
                -- Commit to a funded chain rather than buying its first level and
                -- restarting the ranking from scratch every purchase tick.
                local chain=z.finalChain
                if chain then
                    local tower
                    for _,v in ipairs(z.towers) do if (v.pos-chain.pos).Magnitude<0.1 then tower=v break end end
                    local goal=stats[chain.path1*10+chain.path2]
                    if tower and goal and goal.cost>tower.st.cost and goal.cost-tower.st.cost<=z.cash then
                        local step=chainStep(tower.st,goal,tower.pos)
                        local delay=0.45*(goal.path1+goal.path2-tower.st.path1-tower.st.path2)
                        if step and reachable(goal,profile(tower.pos,goal.range,idx,slice),delay)>0 then
                            t,cost=upgrade(tower,step)
                            if t then
                                z.moves[#z.moves+1]={wave=wi,age=age,pos=c.physics.pack(t.pos),path1=t.st.path1,path2=t.st.path2,price=cost,upper=t.upper,finalChain=true}
                                if t.st.cost>=goal.cost then z.finalChain=nil end
                                return
                            end
                        end
                    end
                    z.finalChain=nil
                end
                for _,v in ipairs(z.towers) do
                    pause()
                    local a,b=v.st.path1,v.st.path2
                    for _,goal in pairs(stats) do
                        if goal.path1>=a and goal.path2>=b and goal.cost>v.st.cost and goal.cost-v.st.cost<=z.cash then
                            local step=chainStep(v.st,goal,v.pos)
                            if step then consider(v,v.pos,goal,step,goal.path1>=goal.path2) end
                        end
                    end
                end
                if #z.towers<cap and z.cash>=base.cost then
                    -- Scan sites by remaining reach; the shortlist includes
                    -- the end of every route, not just the spawn area.
                    local options={}
                    for i,item in ipairs(siteProfiles[idx] or {}) do
                        if i%16==0 then pause() end
                        if free(item.pos) then
                            local v=reachable(base,item.a,0.45)
                            for _,goal in ipairs({stats[52] or base,stats[25] or base}) do
                                if goal.cost<=z.cash then v=math.max(v,reachable(goal,profile(item.pos,goal.range,idx,slice),0.45*(goal.path1+goal.path2+1))) end
                            end
                            if v>0 then options[#options+1]={pos=item.pos,rank=v} end
                        end
                    end
                    table.sort(options,function(a,b) return a.rank>b.rank end)
                    for i=1,math.min(16,#options) do
                        local pos=options[i].pos
                        for _,goal in ipairs({base,stats[21],stats[22],stats[32],stats[42],stats[52],stats[23],stats[24],stats[25]}) do
                            consider(nil,pos,goal,base,goal.path1>=goal.path2)
                        end
                    end
                end
                if bestChain then
                    if bestChain.v then
                        t,cost=upgrade(bestChain.v,bestChain.step)
                    else t,cost=install(bestChain.pos,bestChain.upper) end
                    if t then
                        z.moves[#z.moves+1]={wave=wi,age=age,pos=c.physics.pack(t.pos),path1=t.st.path1,path2=t.st.path2,price=cost,upper=t.upper,finalChain=true}
                        if bestChain.goal.cost>t.st.cost then z.finalChain={pos=t.pos,path1=bestChain.goal.path1,path2=bestChain.goal.path2} end
                    end
                    return
                end
                -- Before the last spawn, allow general future-wave investment
                -- when the current targets cannot use another funded chain.
                if age>=c.forecast.wave(wi).last+1 then return end
            end
            local best,affordable
            if opt.allocator==3 then
                -- A distinct candidate policy: finish a productive chain instead of
                -- continually choosing a cheap first step. Other policies still
                -- explore mass placement and flexible investment.
                local function power(st,p)
                    local dps=st.dps or 0
                    local g=grenadeSpec(st)
                    if g and not g.manual and not g.passive and not g.custom then dps+=g.damage/g.cooldown*0.65 end
                    return dps*p.length/math.max(1,r.length)
                end
                local focus,affordable
                for _,v in ipairs(z.towers) do
                    pause()
                    local step=path(v.st,v.upper,opt.crossEarly)
                    if step then
                        local goal=stats[v.upper and 52 or 25] or step
                        local price=step.cost-v.st.cost
                        local current=power(v.st,v.profile)
                        local long=power(goal,profile(v.pos,goal.range,idx,slice))
                        if wi>=12 then
                            for _,q in ipairs(urgent) do
                                local demand=q.e.hp+(q.e.shield or 0)
                                current+=math.min(demand,impact(v.st,v.profile,q.e,q.d))/math.max(1,#urgent)
                                long+=math.min(demand,impact(goal,profile(v.pos,goal.range,idx,slice),q.e,q.d))/math.max(1,#urgent)
                            end
                        end
                        local gain=math.max(0,power(step,profile(v.pos,step.range,idx,slice))-power(v.st,v.profile))
                        local remaining=math.max(price,goal.cost-v.st.cost)
                        local level=math.max(v.st.path1,v.st.path2)
                        local rank=(math.max(0,long-current)/math.max(1,remaining)^0.5+gain/math.max(1,price)^0.5)*(1+level*0.45)
                        local item={tower=v,step=step,price=price,rank=rank,gain=gain}
                        if not focus or rank>focus.rank then focus=item end
                        if price<=z.cash and (not affordable or gain/math.max(1,price)^0.5>affordable.gain/math.max(1,affordable.price)^0.5) then affordable=item end
                    end
                end
                local readyCore=true
                for _,v in ipairs(z.towers) do
                    if v.st.path1<2 or v.st.path2<1 then readyCore=false break end
                end
                if #z.towers==0 or #z.towers<need and readyCore or not focus then
                    if z.cash>=base.cost and #z.towers<cap then t,cost=build(wi>=12 or threatened) end
                elseif focus.price<=z.cash then
                    t,cost=upgrade(focus.tower,focus.step)
                else
                    local imminent=false
                    for _,q in ipairs(urgent) do
                        local eta=(r.length-q.d)/math.max(0.1,q.e.speed or 1)
                        if eta<5 and q.ratio>1.5 and q.e.hp>math.min(100,z.lives*0.25) then imminent=true break end
                    end
                    -- Preserve the reserve unless a real near-exit threat can
                    -- be reduced by a different affordable upgrade.
                    if imminent and affordable and affordable.gain>0 then
                        t,cost=upgrade(affordable.tower,affordable.step)
                    end
                end
                if t then z.moves[#z.moves+1]={wave=wi,age=age,pos=c.physics.pack(t.pos),path1=t.st.path1,path2=t.st.path2,price=cost,upper=t.upper} end
                return
            end
            if opt.allocator==1 then
                -- Compare complete investment alternatives on the same horizon.
                -- A tower placement pays for its entire chain, an upgrade only for additional levels.
                local horizon=opt.capitalHorizon or 30
                local upcoming={}
                local availableIncome=0
                local weightedDemand=0
                local throughput=0
                for _,v in ipairs(z.towers) do throughput+=v.st.dps end
                for _,e in ipairs(z.enemies) do
                    if not e.dead and not e.air then
                        weightedDemand+=e.hp+(e.shield or 0)
                        if not e.noCash then availableIncome+=math.min(e.hp,e.cashLeft or e.hp) end
                    end
                end
                for offset=0,5 do
                    local w=c.forecast.wave(math.max(1,wi)+offset)
                    if w then
                        local weight=1/(1+offset*0.5)
                        for _,g in ipairs(w.groups or {}) do
                            if not g.air then upcoming[#upcoming+1]={e=g,weight=weight} end
                        end
                    end
                end
                local function worth(st,pos,p)
                    if not st then return 0 end
                    local key="capital"..wi..":"..st.path1..":"..st.path2
                    p.future=p.future or {}
                    local future=p.future[key]
                    if not future then
                        local sum,weight=0,0
                        for _,g in ipairs(upcoming) do
                            local e=g.e
                            local duration=p.length/math.max(0.1,e.speed)
                            local concurrency=math.max(1,(e.count or 1)*duration/math.max(1,(e.last or 0)-(e.first or 0)+duration))
                            local demand=e.hp+(e.shield or 0)+(e.extra or 0)
                            local damage=impact(st,p,e,0)/concurrency
                            -- Count usable rather than nominal damage; allow strong tiers to exploit high-HP and resistance-heavy waves.
                            sum+=g.weight*(e.count or 1)*math.min(demand,damage)
                            weight+=g.weight*(e.count or 1)
                        end
                        future=sum/math.max(1,weight)
                        p.future[key]=future
                    end
                    local current=0
                    for _,q in ipairs(urgent) do
                        local demand=q.e.hp+(q.e.shield or 0)+(q.e.extra or 0)
                        local damage=impact(st,p,q.e,q.d)
                        current+=math.min(demand,damage)*q.weight*math.min(1.5,q.ratio)
                    end
                    return future*(opt.focus or 1)+current/math.max(1,#urgent)
                end
                local incomeRate=math.max(z.cashRate or 0,math.min(throughput,availableIncome/math.max(1,horizon))*c.economy.income(math.max(1,wi),1)*0.55)
                local nextBonus=wi<maxWave and c.economy.bonus(wi+1) or 0
                local nextAge=wi==0 and (cfg.SetUpTime or 15) or math.max(0,(cfg.Waves[wi].CustomWaveTime or 60)-age)
                local function funding(price)
                    local missing=math.max(0,price-z.cash)
                    if missing<=0 then return 0 end
                    local wait=missing/math.max(0.01,incomeRate)
                    if wi<maxWave and nextBonus>0 and wait>nextAge then
                        wait=nextAge+math.max(0,missing-incomeRate*nextAge-nextBonus)/math.max(0.01,incomeRate)
                    end
                    return wait
                end
                local function evaluate(v,pos,old,step,goal,place)
                    local price=step.cost-(old and old.cost or 0)
                    local cost=goal.cost-(old and old.cost or 0)
                    if price<=0 or cost<price then return end
                    local wait=funding(price)
                    local fullWait=funding(cost)
                    if wait>horizon then return end
                    local oldValue=old and worth(old,pos,v.profile) or 0
                    local current=worth(step,pos,profile(pos,step.range,idx,slice))-oldValue
                    local gain=worth(goal,pos,profile(pos,goal.range,idx,slice))-oldValue
                    local discount=math.max(0,1-fullWait/horizon)
                    local immediate=math.max(0,current)*math.max(0,1-wait/horizon)
                    local final=math.max(0,gain)*discount
                    local rank=math.max(immediate/price^0.85,final/cost^0.85)
                    if place then rank*=opt.placeBias or 1 end
                    local item={t=v,st=step,goal=goal,price=price,pos=pos,rank=rank,place=place,wait=wait}
                    if rank>0 and (not best or rank>best.rank) then best=item end
                    if rank>0 and price<=z.cash and (not affordable or rank>affordable.rank) then affordable=item end
                end
                local function upgrades(v)
                    local old=v.st
                    local a,b=old.path1,old.path2
                    for _,step in ipairs({stats[(a+1)*10+b] or false,stats[a*10+b+1] or false}) do
                        if step and step.path1>=a and step.path2>=b and step.cost>old.cost then
                            evaluate(v,v.pos,old,step,step,false)
                            for _,goal in ipairs({stats[52] or false,stats[25] or false,stats[42] or false,stats[24] or false,stats[32] or false,stats[23] or false}) do
                                if goal and goal.path1>=step.path1 and goal.path2>=step.path2 then evaluate(v,v.pos,old,step,goal,false) end
                            end
                        end
                    end
                end
                for _,v in ipairs(z.towers) do pause() upgrades(v) end
                if #z.towers<cap and z.cash>=base.cost then
                    local pos=site(wi,threatened)
                    if pos then
                        evaluate(nil,pos,nil,base,base,true)
                        for _,goal in ipairs({stats[52] or false,stats[25] or false,stats[32] or false,stats[23] or false}) do
                            if goal then evaluate(nil,pos,nil,base,goal,true) end
                        end
                    end
                end
                local choice=best and best.price<=z.cash and best or nil
                -- Waiting is a real candidate. Only override it for an immediate danger,
                -- using a discounted benefit comparison, not a tower-count requirement.
                if not choice and affordable and (opt.spend and threatened or threatened and best and best.wait>math.max(2,horizon*0.18) or best and affordable.rank>=best.rank*0.95) then choice=affordable end
                if choice then
                    if choice.place then
                        local upper=choice.goal.path1>choice.goal.path2 or choice.goal.path1==choice.goal.path2 and opt.upper~=false
                        t,cost=install(choice.pos,upper)
                    else
                        t,cost=upgrade(choice.t,choice.st)
                    end
                end
                if t then
                    z.moves[#z.moves+1]={wave=wi,age=age,pos=c.physics.pack(t.pos),path1=t.st.path1,path2=t.st.path2,price=cost,upper=t.upper}
                end
                return
            end
            for _,v in ipairs(z.towers) do
                pause()
                local st=path(v.st,v.upper,opt.crossEarly)
                if st then
                    local price=st.cost-v.st.cost
                    local goal=stats[v.upper and 52 or 25] or st
                    local old=merit(v.st,v.pos,v.profile)
                    local gain=math.max(0,merit(st,v.pos,profile(v.pos,st.range,idx,slice))-old)
                    local long=math.max(0,merit(goal,v.pos,profile(v.pos,goal.range,idx,slice))-old)
                    local totalPrice=math.max(price,goal.cost-v.st.cost)
                    local level=math.max(v.st.path1,v.st.path2)
                    local rank=gain/math.max(1,price)^0.65+long/totalPrice^0.65*(opt.focus or 1)
                    if st.stealthDetection and not v.st.stealthDetection then rank+=0.1 end
                    local item={t=v,st=st,rank=rank,price=price}
                    if not best or rank>best.rank then best=item end
                    if price<=z.cash and (not affordable or rank>affordable.rank) then affordable=item end
                end
            end
            local placeOption
            if #z.towers<cap and z.cash>=base.cost then
                local pos=site(wi,threatened)
                if pos then
                    local upper=opt.upper~=false
                    if opt.mix and #z.towers%3==1 then upper=not upper end
                    if opt.forceUpper~=nil then upper=opt.forceUpper end
                    local goal=stats[upper and 52 or 25] or base
                    local immediate=merit(base,pos,profile(pos,base.range,idx,slice))
                    local later=merit(goal,pos,profile(pos,goal.range,idx,slice))
                    local rank=(immediate/base.cost^0.65+later/goal.cost^0.65*(opt.focus or 1))*(opt.placeBias or 0.9)
                    if threatened then rank*=1.3 elseif best and best.price>z.cash then rank*=0.65 end
                    if wi==0 and #z.towers>=need then rank=0 end
                    placeOption={pos=pos,upper=upper,rank=rank}
                end
            end
            local choice=best and best.price<=z.cash and best or (threatened or opt.spend) and affordable or nil
            if #z.towers==0 then
                if placeOption then t,cost=install(placeOption.pos,placeOption.upper) end
            elseif opt.allocator==2 then
                if placeOption and placeOption.rank>0 and threatened and #z.towers<need and (not affordable or placeOption.rank>=affordable.rank*(opt.placeBias or 0.9)) then
                    t,cost=install(placeOption.pos,placeOption.upper)
                elseif best and best.price<=z.cash then
                    t,cost=upgrade(best.t,best.st)
                elseif (threatened or opt.spend) and affordable then
                    t,cost=upgrade(affordable.t,affordable.st)
                elseif placeOption and (not best or #z.towers<need and (wi==0 or threatened) or threatened and urgent[1] and urgent[1].ratio>1.3 and placeOption.rank>best.rank*1.25) then
                    t,cost=install(placeOption.pos,placeOption.upper)
                end
            elseif placeOption and placeOption.rank>0 and (not best or placeOption.rank>(choice and choice.rank or best.rank)) then
                t,cost=install(placeOption.pos,placeOption.upper)
            elseif choice then
                t,cost=upgrade(choice.t,choice.st)
            end
            if t then
                z.moves[#z.moves+1]={wave=wi,age=age,pos=c.physics.pack(t.pos),path1=t.st.path1,path2=t.st.path2,price=cost,upper=t.upper}
            end
        end
        local function hit(e,damage,kind,ignore,wi)
            if e.dead or damage<=0 then return end
            local resist=ignore and 0 or math.clamp(e.resist[tostring(kind)] or 0,0,1)
            local v=damage*(1-resist)*(1-math.clamp(e.allReduction or 0,0,1))*(stress and 0.85 or 1)
            if e.maxDamage and e.maxDamage>=0 then v=math.min(v,e.maxDamage) end
            local sh=math.min(e.shield,v)
            e.shield-=sh
            local hp=math.min(e.hp,v-sh)
            e.hp-=hp
            hpDamage+=hp
            shieldDamage+=sh
            if not e.noCash then
                local paid=math.min(e.cashLeft or 0,hp)
                e.cashLeft=math.max(0,(e.cashLeft or 0)-paid)
                paidDamage+=paid
                local earned=c.economy.income(wi,paid)*(stress and 0.95 or 1)
                z.cash+=earned
                z.income+=earned
            end
            if e.hp<=0.0001 then
                e.dead=true
                c.physics.sludgeAdd(sludge,e,r,z.time)
                for _,kid in ipairs(e.kids or {}) do
                    if (kid.delay or 0)>0 then
                        pending[#pending+1]={e=kid,d=e.dist,at=z.time+kid.delay}
                    else add(kid,e.dist) end
                end
            end
        end
        if live then
            firstWave=live.wave
            z.cash=s.cash
            initialCash=s.cash
            z.lives=s.lives
            z.time=live.age
            nextBuy=z.time
            for wi=1,firstWave-1 do
                z.history[wi]=live.history and live.history[wi] or {wave=wi,lives=s.lives,loss=0,time=0}
            end
            for _,e in pairs(s.enemies or {}) do
                local er=routes[e.pathIndex]
                if not er then unknown+=1 continue end
                local v=table.clone(e)
                v.kids=c.forecast.children and c.forecast.children(e.type) or e.kids
                local d=c.physics.project(er,c.physics.vec(e.pathPos))
                if er~=r then d=d/math.max(1,er.length)*r.length end
                add(v,d)
                local q=z.enemies[#z.enemies]
                q.burnUntil=z.time+math.max(0,e.burn and e.burn.Burn or 0)
                q.burnTick=z.time
                q.healAt=z.time+(e.bossHealIn or 12)
                q.smoke=e.smokeHealed or false
                if q.smoke then q.smokeAt=z.time end
            end
            for _,v in pairs(s.towers or {}) do
                if v.owned and v.type=="Ranger" then
                    local st=stats[v.path1*10+v.path2]
                    if not st then unknown+=1 continue end
                    local pos=c.physics.vec(v.pos)
                    local interval=math.max(dt,v.burstInterval or st.burstInterval or dt)
                    local left=math.clamp((st.burstSize or 1)-(v.burstIndex or 1)+1,1,st.burstSize or 1)
                    if (v.burstReset or 0)<=0 then left=st.burstSize end
                    local lastShot=z.time+(v.burstReset or 0)-2*interval
                    local shot=z.time+math.max(0,v.nextAttack or 0)
                    if left<st.burstSize then shot=math.max(z.time,lastShot+interval) end
                    local stun=0
                    for _,b in pairs(v.debuffs or {}) do if b.type=="Stun" or b.type=="Freeze" then stun=math.max(stun,b.remaining or 0) end end
                    if v.stunned and stun==0 then stun=1 end
                    local up=v.path1>=3 or v.path2<3 and (v.path1>v.path2 or v.path1==v.path2 and policy.upper~=false)
                    local t={pos=pos,st=st,profile=profile(pos,st.range,idx,slice),upper=up,nextShot=shot+stun,left=left,active=z.time,stunUntil=z.time+stun,lastShot=lastShot,query=v.query or 0,fireAt=z.time+(v.abilities and v.abilities.M203 and v.abilities.M203.cooldown or 0),grenadeAt=z.time+(v.abilities and (v.abilities.GrenadeLevel2 or v.abilities.GrenadeLevel1) and (v.abilities.GrenadeLevel2 or v.abilities.GrenadeLevel1).cooldown or 0)}
                    local name=v.abilities and (v.abilities.GrenadeLevel2 and "GrenadeLevel2" or v.abilities.GrenadeLevel1 and "GrenadeLevel1")
                    t.grenadeSpec=name and c.ability.spec(name,v.abilities[name],v.range) or nil
                    t.liveAbility=true
                    z.towers[#z.towers+1]=t
                end
            end
            table.sort(z.towers,function(a,b)
                if a.pos.X~=b.pos.X then return a.pos.X<b.pos.X end
                if a.pos.Z~=b.pos.Z then return a.pos.Z<b.pos.Z end
                return a.pos.Y<b.pos.Y
            end)
        elseif not checkpoints[0] then
            for i=1,12 do purchase(0,0) end
            z.time=cfg.SetUpTime or 15
            checkpoint(0)
        end
        local endWave=live and live.endWave or maxWave
        for wi=firstWave,endWave do
            if s.cancel and s.cancel() then return end
            local w=c.forecast.wave(wi)
            unknown+=w.unknown or 0
            local currentLive=live and wi==live.wave
            local bonus=currentLive and 0 or c.economy.bonus(wi)
            z.cash+=bonus
            z.bonuses+=bonus
            local start=currentLive and 0 or z.time
            local event=1
            local firstStep=currentLive and math.ceil(live.age/dt-1e-6) or 0
            if currentLive then
                while event<=#w.events and w.events[event].at<=live.age do event+=1 end
            end
            local lossBefore=z.loss
            local grenadeBefore=z.grenadeCount or 0
            local skipped=false
            local limit=math.max(w.last or 0,cfg.Waves[wi].CustomWaveTime or 60)
            if currentLive then limit=math.max(live.age+live.delay,firstStep*dt+dt) end
            if wi==maxWave then limit=math.max(180,w.last+r.length/0.8+30,limit) end
            local steps=math.ceil(limit/dt)
            local clearedAt
            for k=firstStep,steps-1 do
                pause()
                if slice and k%32==0 and s.cancel and s.cancel() then return end
                local age=k*dt
                z.time=start+age
                c.physics.sludgePrune(sludge,z.time)
                for j=#pending,1,-1 do
                    local v=pending[j]
                    if v.at<=z.time+1e-6 then add(v.e,v.d) table.remove(pending,j) end
                end
                while event<=#w.events and w.events[event].at<=age+1e-6 do add(w.events[event].enemy,0) event+=1 end
                if z.time+1e-6>=nextBuy then
                    if not (currentLive and live.freezePurchases) then purchase(wi,age) end
                    nextBuy=z.time+0.45
                end
                for j=#fires,1,-1 do
                    local f=fires[j]
                    if f.grenade then
                        if z.time>=f.at then
                            for _,e in ipairs(z.enemies) do
                                if not e.dead and not e.air and not e.invulnerable and not e.noDamage and not e.stasis then
                                    local pos=c.physics.at(r,e.dist)
                                    if (pos-f.pos).Magnitude<=f.radius and (pos-f.lead).Magnitude<=f.radius then hit(e,f.damage,f.kind or "Explosive",false,wi) end
                                end
                            end
                            table.remove(fires,j)
                        end
                    elseif z.time>=f.finish then table.remove(fires,j)
                    elseif z.time>=f.at then
                        for _,e in ipairs(z.enemies) do
                            if not e.dead and not e.air and (c.physics.at(r,e.dist)-f.pos).Magnitude<=4.5 then
                                e.burnUntil=z.time+5
                                e.burnTick=e.burnTick or z.time
                            end
                        end
                    end
                end
                local active=0
                for _,e in ipairs(z.enemies) do
                    if not e.dead then
                        if (e.burnUntil or 0)>z.time and z.time+1e-6>=(e.burnTick or 0) then
                            e.burnTick=z.time+0.25
                            hit(e,2,"Fire",false,wi)
                        end
                        if not e.dead and e.type=="Plague Doctor" then
                            if z.time+1e-6>=e.healAt then
                                e.hp=math.min(e.maxHp,e.hp+8750)
                                e.healAt+=30
                                local pos=c.physics.at(r,e.dist)
                                for _,t in ipairs(z.towers) do
                                    if (t.pos-pos).Magnitude<=10 then
                                        local untilTime=z.time+5
                                        t.nextShot+=math.max(0,untilTime-math.max(z.time,t.stunUntil or 0))
                                        t.stunUntil=math.max(t.stunUntil or 0,untilTime)
                                    end
                                end
                            end
                            if not e.smoke and e.hp<=7500 then e.smoke=true e.hp=math.min(e.maxHp,e.hp+1000) e.smokeAt=z.time end
                            if z.time+1e-6>=e.smokeAt then
                                e.smokeAt+=1
                                local pos=c.physics.at(r,e.dist)
                                for _,t in ipairs(z.towers) do
                                    if (t.pos-pos).Magnitude<=30 then t.smokeUntil=z.time+2 end
                                end
                            end
                            if z.time>=e.summonAt then
                                for _,kid in ipairs(e.summons==0 and summon1 or summon2) do add(kid,e.dist-(kid.offset or 0)) end
                                e.summons+=1
                                e.summonAt+=e.summons==1 and 15 or 35
                            end
                        end
                        active+=1
                    end
                end
                for _,t in ipairs(z.towers) do
                    pause()
                    local st=t.st
                    local g=t.grenadeSpec
                    if not g and not t.liveAbility and st.path2>=4 then g=grenadeSpec(st) t.grenadeSpec=g end
                    if g and not g.manual and not g.passive and not g.custom and z.time>=t.active and z.time>=(t.stunUntil or 0) and z.time+1e-6>=(t.grenadeAt or 0) then
                        t.grenadeAt=z.time+0.25
                        local target
                        local p=profile(t.pos,g.range,idx,slice)
                        local function eligible(e)
                            return not e.dead and not e.air and not e.invulnerable and not e.noDamage and not e.untargetable and not e.stasis
                        end
                        local function order(e)
                            if t.query==1 then return -e.dist elseif t.query==2 then return e.hp+e.shield elseif t.query==3 then return -e.hp-e.shield end
                            return e.dist
                        end
                        for _,e in ipairs(z.enemies) do
                            if eligible(e) and (not e.stealth or st.stealthDetection) then
                                local pos=c.physics.at(r,e.dist)
                                if (g.independent and (pos-t.pos).Magnitude<=g.range or not g.independent and p.hit[math.floor(e.dist+0.5)]) and (not target or order(e)>order(target)) then target=e end
                            end
                        end
                        if target then
                            local pos=c.physics.at(r,target.dist)
                            local flight=c.ability.flight(t.pos,pos)
                            local function predicted(e)
                                local speed=(e.stopped or e.stunned or e.stasis) and 0 or e.speed or 0
                                if (e.sludgeUntil or 0)>z.time then speed*=1.8 end
                                local d=e.dist+speed*flight*(e.reverse and -1 or 1)
                                if d>=r.length then return nil end
                                return c.physics.at(r,d)
                            end
                            local lead=predicted(target)
                            local radius=g.radius*0.9
                            local damage=g.damage*(g.estimated and 0.65 or 1)
                            local useful=0
                            if lead then
                                for _,e in ipairs(z.enemies) do
                                    if eligible(e) then
                                        local future=predicted(e)
                                        if future and (future-pos).Magnitude<=radius and (future-lead).Magnitude<=radius then
                                            local hp=e.hp+e.shield
                                            local resist=math.clamp((e.resist or {})[g.kind] or 0,0,1)
                                            local d=damage*(1-resist)*(1-math.clamp(e.allReduction or 0,0,1))
                                            if e.maxDamage and e.maxDamage>=0 then d=math.min(d,e.maxDamage) end
                                            useful+=math.min(hp,d)
                                        end
                                    end
                                end
                                if useful>0 then
                                    fires[#fires+1]={grenade=true,pos=pos,lead=lead,at=z.time+flight,radius=radius,damage=damage,kind=g.kind}
                                    t.grenadeAt=z.time+g.cooldown
                                    z.grenadeCount=(z.grenadeCount or 0)+1
                                end
                            end
                        end
                    end
                    if z.time+1e-6>=t.nextShot and z.time+1e-6>=t.active and z.time>=(t.stunUntil or 0) then
                        local p=t.profile
                        local best
                        for ei,e in ipairs(z.enemies) do
                            if slice and ei%64==0 then pause() end
                            if not e.dead and not e.air and not e.invulnerable and not e.noDamage and not e.untargetable and not e.stasis and (not e.stealth or st.stealthDetection) and p.hit[math.floor(e.dist+0.5)] then
                                local function priority(q)
                                    if t.query==1 then return -q.dist elseif t.query==2 then return q.hp+q.shield elseif t.query==3 then return -q.hp-q.shield end
                                    return q.dist
                                end
                                if not best or priority(e)>priority(best) then best=e end
                            end
                        end
                        if best then
                            if st.path2==5 and z.time+1e-6>=(t.fireAt or 0) then
                                local pos=c.physics.at(r,best.dist)
                                local travel=math.max(0.4,(pos-t.pos).Magnitude/45)
                                local at=z.time+travel
                                fires[#fires+1]={pos=c.physics.at(r,best.dist+best.speed*travel),at=at,finish=at+5}
                                t.fireAt=z.time+10
                            end
                            hit(best,st.damage,st.damageType,st.ignoreResistance,wi)
                            t.lastShot=z.time
                            t.left-=1
                            if t.left<=0 then
                                t.left=st.burstSize
                                t.nextShot=z.time+math.max(dt,st.reload/((t.smokeUntil or 0)>z.time and 0.8 or 1))
                            else
                                t.nextShot=z.time+math.max(dt,st.burstInterval or dt)
                            end
                        elseif t.left<st.burstSize and t.lastShot and z.time+1e-6>=t.lastShot+2*math.max(dt,st.burstInterval or dt) then
                            t.left=st.burstSize
                            t.nextShot=z.time+math.max(dt,st.reload/((t.smokeUntil or 0)>z.time and 0.8 or 1))
                        end
                    end
                end
                local n=0
                for _,e in ipairs(z.enemies) do
                    if not e.dead then
                        local speed,buffed=c.physics.sludgeSpeed(sludge,e,r,z.time,dt)
                        if buffed then sludgeHits+=1 end
                        if not e.stopped and not e.stunned and not e.stasis then e.dist=math.clamp(e.dist+speed*dt*(e.reverse and -1 or 1),0,r.length) end
                        if e.dist>=r.length then
                            e.dead=true
                            z.lastLeak={type=e.type,hp=e.hp,wave=wi,age=age}
                            z.loss+=e.hp
                            z.lives-=e.hp
                        else
                            n+=1
                            z.enemies[n]=e
                        end
                    end
                end
                for j=#z.enemies,n+1,-1 do z.enemies[j]=nil end
                if z.lives<=0 then break end
                if event>#w.events and n==0 and #pending==0 and age>=w.last then
                    if wi==maxWave then break end
                    -- The observed server shortens a cleared wave to about five game seconds.
                    clearedAt=clearedAt or age
                    if age>=clearedAt+5-dt*0.5 then break end
                else
                    clearedAt=nil
                end
                local opt=settings(policy,wi)
                local target
                if replay then target=replaySkips and replaySkips[wi]
                elseif currentLive then target=live.skipAt
                elseif wi<maxWave and opt.fast and not cfg.Waves[wi].SkipWaveDisabled then
                    local override=policy.skipAges and policy.skipAges[wi]
                    if override~=nil then target=override>=0 and override or nil
                    else target=math.max(20.25,(opt.earlySkip and 20.25 or (w.last or 0)+0.5))+(opt.skipDelay or 0) end
                end
                if wi<maxWave and target and age+1e-6>=target and age<limit-dt then
                    skipped=true
                    z.skips[wi]=age
                    if not (currentLive and live.cancelUnspawned or policy.cancelEarly) then
                        while event<=#w.events do
                            local v=w.events[event]
                            pending[#pending+1]={e=v.enemy,d=0,at=start+v.at}
                            event+=1
                        end
                    end
                    break
                end
                if k%480==0 then
                    if s.cancel and s.cancel() then return end
                    if not slice and (not live or k%960==0) then task.wait() end
                end
            end
            z.time+=dt
            local delta=z.loss-lossBefore
            if wi<=5 then z.earlyLoss+=delta end
            local remainingHP=0
            for _,e in ipairs(z.enemies) do remainingHP+=e.hp+(e.shield or 0) end
            local maxed=0
            for _,t in ipairs(z.towers) do if math.max(t.st.path1,t.st.path2)==5 then maxed+=1 end end
            z.history[#z.history+1]={wave=wi,grenadeCasts=(z.grenadeCount or 0)-grenadeBefore,skipped=skipped,maxed=maxed,loss=delta,lives=z.lives,cash=z.cash,towers=#z.towers,time=z.time-start,remaining=#z.enemies,remainingHP=remainingHP,income=z.income,spent=z.spent,bonuses=z.bonuses,hpDamage=hpDamage,shieldDamage=shieldDamage,paidDamage=paidDamage,sludgeHits=sludgeHits}
            if z.lives>0 and unknown==0 then checkpoint(wi) end
            if notify then notify(wi,z) end
            if z.lives<=0 or unknown>0 then break end
            if live and live.acceptBoundary and live.acceptBoundary(wi,checkpoints[wi],cursor-1) then break end
        end
        local complete=#z.history==maxWave and #z.enemies==0 and #pending==0 and z.lives>0 and unknown==0
        local ledgerError=z.cash-(initialCash+z.income+z.bonuses-z.spent)
        local bossHP=0
        for _,e in ipairs(z.enemies) do if e.type=="Plague Doctor" then bossHP+=e.hp end end
        return {grenadeCasts=z.grenadeCount or 0,blockedMove=blockedMove,ledgerError=ledgerError,income=z.income,spent=z.spent,bonuses=z.bonuses,remainingHP=z.history[#z.history] and z.history[#z.history].remainingHP or 0,from=1,to=#z.history,targetWave=maxWave,loss=z.loss,lives=z.lives,earlyLoss=z.earlyLoss,cash=z.cash,time=z.time-(live and live.age or 0),history=z.history,moves=z.moves,skips=z.skips,complete=complete,remaining=#z.enemies,unknown=unknown,policy=policy,stress=stress,replayed=cursor-1,reusedWaves=firstWave-1,lastLeak=z.lastLeak,bossHP=bossHP},checkpoints
    end
    local function objective(v,startHP)
        local lost=math.max(0,startHP-v.lives)
        return v.time+lost*0.4+80*(lost/math.max(1,startHP))^2
    end
    local function compareBoundary(got,ref,wi)
        if not got or not ref then return false,"missing_checkpoint" end
        local a,b=got.z,ref.z
        if a.lives+0.01<b.lives then return false,"hp" end
        if a.cash+0.01<b.cash then return false,"cash" end
        if #got.pending>0 or #got.sludge>0 or #got.fires>0 or #ref.pending>0 or #ref.sludge>0 or #ref.fires>0 then return false,"pending_effects" end
        for _,t in ipairs(b.towers) do
            local found
            for _,v in ipairs(a.towers) do
                if (v.pos-t.pos).Magnitude<0.1 and v.st.path1==t.st.path1 and v.st.path2==t.st.path2 and (v.query or 0)==(t.query or 0) then found=v break end
            end
            if not found then return false,"tower" end
            if (found.stunUntil or 0)>a.time or (found.smokeUntil or 0)>a.time then return false,"debuff" end
            if math.max(0,found.nextShot-a.time)>math.max(0,t.nextShot-b.time)+0.25 then return false,"cooldown" end
            if math.max(0,(found.grenadeAt or 0)-a.time)>math.max(0,(t.grenadeAt or 0)-b.time)+0.25 then return false,"grenade_cooldown" end
        end
        local rate=0
        for w=wi+1,maxWave do rate=math.max(rate,c.economy.income(w,1)) end
        local function outstanding(z)
            local sum=0
            for _,e in ipairs(z.enemies) do if not e.noCash then sum+=math.min(e.hp,e.cashLeft or e.hp) end end
            return sum
        end
        if a.cash+0.01<b.cash+math.max(0,outstanding(b)-outstanding(a))*rate then return false,"future_cash" end
        local used={}
        local enemies=table.clone(a.enemies)
        table.sort(enemies,function(x,y) return x.dist>y.dist end)
        for _,e in ipairs(enemies) do
            local match
            for i,v in ipairs(b.enemies) do
                if not used[i] and e.type==v.type and e.hp<=v.hp+0.01 and (e.shield or 0)<=(v.shield or 0)+0.01 and e.dist<=v.dist+0.01 and e.speed<=v.speed+0.01 and e.stealth==v.stealth and e.air==v.air and (e.sludgeUntil or 0)<=a.time and not e.boss then
                    if not match or v.dist<b.enemies[match].dist then match=i end
                end
            end
            if not match then return false,"enemy" end
            used[match]=true
        end
        return true,"matched"
    end
    function x.preparedSkip(s,rollout,cursor)
        if not prepared or prepared.moves~=rollout.moves or not s.waveAge or not s.timerRemaining then return nil,"no_prepared" end
        local wi=s.wave
        local at=s.waveAge+3.5*(s.speed or 1)
        local target=rollout.skips[wi]
        if wi>=maxWave-1 or at>=s.waveAge+s.timerRemaining-0.5 then return nil,"outside_window" end
        if at<c.forecast.wave(wi).last or (rollout.skips[wi+1] and rollout.skips[wi+1]<c.forecast.wave(wi+1).last) then return nil,"early_spawn_uncertainty" end
        if wi>1 and rollout.skips[wi-1] and rollout.skips[wi-1]<c.forecast.wave(wi-1).last then return nil,"prior_spawns" end
        local endWave=math.min(maxWave-1,wi+3)
        for w=wi+2,endWave do
            if rollout.skips[w] and rollout.skips[w]<c.forecast.wave(w).last then endWave=w-1 break end
        end
        local moves,required={},{}
        for i=cursor or 1,#rollout.moves do
            local v=rollout.moves[i]
            if v.wave<=wi then return nil,"pending_purchase" end
            if v.wave>endWave then break end
            moves[#moves+1]=v
        end
        local n=0
        for w=wi+1,endWave do
            while moves[n+1] and moves[n+1].wave<=w do n+=1 end
            required[w]=n
        end
        local skips=table.clone(rollout.skips)
        skips[wi]=at
        local simState=table.clone(s)
        local started=os.clock()
        simState.cancel=function() return os.clock()-started>math.min(2.5,math.max(0.5,s.timerRemaining/math.max(1,s.speed or 1)-3.5)) end
        local worst=math.huge
        local saved=math.huge
        local checkpointWave=wi+1
        for idx in pairs(routes) do
            local natural=simulate(simState,idx,rollout.policy,false,{},nil,nil,false,{}, {wave=wi,age=s.waveAge,delay=s.timerRemaining,freezePurchases=true,endWave=wi,history=rollout.history})
            if not natural then return nil,"short_budget" end
            if natural.unknown>0 or natural.loss>0.01 then return nil,"natural_branch_risk" end
            local gain=natural.time-(at-s.waveAge)
            if gain<=0.8 then return nil,"natural_clear_first" end
            saved=math.min(saved,gain)
            local matched,why
            local function accept(w,cp,replayed)
                if w<=wi or replayed~=required[w] then why="purchase" return false end
                local ref=prepared.routes[idx] and prepared.routes[idx][w]
                local ok,reason=compareBoundary(cp,ref,w)
                why=reason
                if ok then matched=w return true end
                return false
            end
            local v=simulate(simState,idx,rollout.policy,false,moves,nil,nil,true,skips,{wave=wi,age=s.waveAge,delay=s.timerRemaining,freezePurchases=true,endWave=endWave,history=rollout.history,acceptBoundary=accept})
            if not v then return nil,"short_budget" end
            if not v.skips[wi] then return nil,"natural_clear_first" end
            if v.unknown>0 or v.loss>0.01 or math.abs(v.ledgerError)>0.01 then return nil,"short_replay" end
            if not matched then return nil,"boundary_"..tostring(why or "missing") end
            checkpointWave=math.max(checkpointWave,matched)
            worst=math.min(worst,v.lives)
        end
        local threat=0
        for _,e in pairs(s.enemies or {}) do threat+=e.hp+(e.shield or 0) end
        return {allowed=true,prepared=true,reason="prepared_checkpoint_skip",tested=1,predictedLoss=0,checkpointWave=checkpointWave,checkpointHP=worst,threat=threat,lives=s.lives,delay=s.timerRemaining,saved=saved,savedReal=saved/math.max(0.01,s.speed or 1)}
    end
    function x.compareSkips(s,rollout,cursor)
        local started=os.clock()
        local quick,why=x.preparedSkip(s,rollout,cursor)
        if quick then return quick end
        if why=="natural_clear_first" then return {allowed=false,reason=why,preparedReason=why,tested=1} end
        if not s.waveAge or not s.timerRemaining or s.timerRemaining<=3.5*(s.speed or 1)+0.5 or s.wave>=maxWave then return {allowed=false,reason="no_window"} end
        local wi=s.wave
        local age=s.waveAge
        local delay=s.timerRemaining
        local policy=rollout.policy
        local limit=s.runtimeSlice and math.min(7,math.max(2,delay/math.max(1,s.speed or 1)-1)) or 3
        local simState=table.clone(s)
        simState.cancel=function() return os.clock()-started>limit end
        local candidates={}
        local function evaluate(skipAt,cancelUnspawned,freezePurchases,replay,replaySkips)
            local worst,finish,minimumCash,loss=math.huge,0,math.huge,0
            local chosen
            for idx in pairs(routes) do
                local v=simulate(simState,idx,policy,false,replay,nil,nil,false,replaySkips,{wave=wi,age=age,delay=delay,skipAt=skipAt,cancelUnspawned=cancelUnspawned,freezePurchases=freezePurchases,history=rollout.history})
                if not v then return nil end
                if not chosen then chosen=v end
                if not v.complete or replay and v.replayed~=#replay or math.abs(v.ledgerError)>0.01 or skipAt and not v.skips[wi] then
                    return {complete=false,lives=v.lives,time=v.time,loss=v.loss,at=skipAt,remaining=v.remaining}
                end
                worst=math.min(worst,v.lives)
                finish=math.max(finish,v.time)
                minimumCash=math.min(minimumCash,v.cash)
                loss=math.max(loss,v.loss)
            end
            return {complete=true,lives=worst,time=finish,loss=loss,cash=minimumCash,at=skipAt,score=objective({time=finish,lives=worst},s.lives),plan=chosen}
        end
        local first=age+3.5*(s.speed or 1)
        if first>=age+delay-0.1 then return {allowed=false,reason="no_window",preparedReason=why} end
        local planned=rollout.skips and rollout.skips[wi]
        local canReplay=first>=c.forecast.wave(wi).last+0.25
        if canReplay then
            for w=wi+1,maxWave-1 do
                if rollout.skips[w] and rollout.skips[w]<c.forecast.wave(w).last then canReplay=false break end
            end
        end
        if canReplay then
            local moves={}
            for i=cursor or 1,#rollout.moves do moves[#moves+1]=rollout.moves[i] end
            local skips=table.clone(rollout.skips)
            skips[wi]=first
            local fast=evaluate(first,false,true,moves,skips)
            if fast and fast.complete then
                skips[wi]=nil
                local natural=evaluate(nil,false,false,moves,skips)
                if natural and natural.complete then
                    local saved=natural.time-fast.time
                    if saved>0.8 and fast.lives>=natural.lives-0.01 and fast.score+0.8<natural.score then
                        local threat=0
                        for _,e in pairs(s.enemies or {}) do threat+=e.hp+(e.shield or 0) end
                        return {allowed=true,prepared=true,reason="verified_replay_skip",tested=2,predictedLoss=fast.loss,waitLoss=natural.loss,saved=saved,savedReal=saved/math.max(0.01,s.speed or 1),threat=threat,lives=s.lives,delay=delay,preparedReason=why}
                    end
                    return {allowed=false,reason="replay_wait_better",tested=2,preparedReason=why,predictedLoss=fast.loss,waitLoss=natural.loss,saved=saved}
                end
            end
            if os.clock()-started>=limit then return {allowed=false,reason="replay_budget",preparedReason=why,tested=fast and 1 or 0} end
        end
        local wait=evaluate(nil,false)
        if not wait then return {allowed=false,reason="branch_budget",preparedReason=why,tested=0} end
        local now=evaluate(first,false,true)
        if not now then return {allowed=false,reason="branch_budget",preparedReason=why,tested=1} end
        local w=c.forecast.wave(wi)
        if now.complete and first<w.last then
            local cancel=evaluate(first,true,true)
            if not cancel then return {allowed=false,reason="branch_budget",preparedReason=why,tested=2} end
            if not cancel.complete then now.complete=false now.cancelRisk=true
            else
                now.lives=math.min(now.lives,cancel.lives)
                now.loss=math.max(now.loss,cancel.loss)
                now.time=math.max(now.time,cancel.time)
                now.score=objective(now,s.lives)
            end
        end
        local best=wait.complete and wait or nil
        local function consider(v)
            if v and v.complete and (not best or v.score<best.score) then best=v end
        end
        consider(now)
        local tested=2
        for _,d in ipairs({2,5,10}) do
            local at=first+d
            if at<age+delay-1 then
                local v=evaluate(at,false)
                if not v then break end
                tested+=1
                if v.complete and at<w.last then
                    local cancel=evaluate(at,true)
                    if not cancel then break end
                    if not cancel.complete then v.complete=false
                    else v.lives=math.min(v.lives,cancel.lives) v.loss=math.max(v.loss,cancel.loss) v.time=math.max(v.time,cancel.time) v.score=objective(v,s.lives) end
                end
                consider(v)
                candidates[#candidates+1]={at=at,complete=v.complete,lives=v.lives,time=v.time,loss=v.loss}
            end
        end
        local saved=wait.complete and now.complete and wait.time-now.time or nil
        local allowed=now.complete and best==now and (not wait.complete or now.score+0.8<wait.score) and (not wait.complete or now.lives>=wait.lives-0.01)
        local plan=allowed and now.plan or nil
        local threat=0
        for _,e in pairs(s.enemies or {}) do threat+=e.hp+(e.shield or 0) end
        now.plan=nil wait.plan=nil
        return {allowed=allowed,reason=allowed and "full_match_skip" or best and best~=now and "better_wait_or_later" or "unsafe_skip",predictedLoss=now.loss,waitLoss=wait.loss,saved=saved,savedReal=saved and saved/math.max(0.01,s.speed or 1),delay=delay,threat=threat,lives=s.lives,preparedReason=why,tested=tested,now=now,wait=wait,alternatives=candidates,bestAt=best and best.at,plan=plan}
    end
    function x.search(s)
        local began=os.clock()
        local idx,short
        for k,r in pairs(routes) do if not short or r.length<short then idx,short=k,r.length end end
        if not idx then return end
        local best,failed
        local pool={}
        local signatures={}
        local policySeen={}
        local stageBest={}
        local attempts=0
        local duplicatePolicies=0
        local duplicateResults=0
        local improvedAt=0
        local bestRank=-math.huge
        local function policyKey(p)
            local fields={"core","upper","mix","crossEarly","depth","longRange","seed","risk","fast","earlySkip","skipDelay","placeBias","focus","allocator","capitalHorizon","forceUpper","spend","legacySite"}
            local key={tostring(p.cancelEarly),tostring(p.grenades),tostring(p.grenadeScale)}
            for w=0,maxWave do
                local v=settings(p,w)
                for _,k in ipairs(fields) do key[#key+1]=tostring(v[k]) end
                key[#key+1]=tostring(p.skipAges and p.skipAges[w])
            end
            return table.concat(key,";")
        end
        local round=0
        local firstWinAt,firstWinAttempt
        local repairAttempts=0
        local function stopSearch()
            if not best then return false end
            if best.routeLives>=cfg.StartingLives-0.01 and best.time<=720 then return repairAttempts>=12 or attempts-firstWinAttempt>=48 end
            return repairAttempts>=24 and (attempts-firstWinAttempt>=100 or os.clock()-firstWinAt>=40)
        end
        local function weakestLate(v)
            local worst,loss=math.max(1,v.to),0
            for _,w in ipairs(v.history) do
                if w.loss>loss then worst,loss=w.wave,w.loss end
            end
            return worst
        end
        local function weak(v)
            for _,w in ipairs(v.history) do
                if v.earlyLoss>earlyLimit and w.wave<=5 and w.loss>1 then return w.wave end
            end
            for _,w in ipairs(v.history) do
                if w.loss>25 then return w.wave end
            end
            return math.max(1,v.to)
        end
        local function score(v)
            local eligible=v.complete and v.lives>0
            return v.to*1000000+(eligible and 100000000 or 0)-(eligible and (v.time+(cfg.StartingLives-v.lives)*2.5+(v.earlyLoss or 0)*2) or math.min(v.loss, cfg.StartingLives+math.max(0,v.loss-cfg.StartingLives)*0.12)*120+(v.remainingHP or 0)*2+(v.earlyLoss or 0)*180)
        end
        local function retain(v,p,w,stressTest,checkpoints)
            local key={}
            for _,a in ipairs(v.moves) do key[#key+1]=string.format("%d:%.2f:%.2f:%.2f:%.2f:%d:%d",a.wave,a.age or 0,a.pos.x,a.pos.y,a.pos.z,a.path1,a.path2) end
            for wi=1,maxWave-1 do key[#key+1]=string.format("s%d:%.2f",wi,v.skips[wi] or -1) end
            key=table.concat(key,";")
            local rank=score(v)
            if stressTest then rank+=stressTest.to*5000+stressTest.lives*40-math.max(0,stressTest.earlyLoss-stressEarlyLimit)*100 end
            if signatures[key] and signatures[key]>=rank then duplicateResults+=1 return end
            signatures[key]=rank
            local item={v=v,p=p,w=w or weak(v),rank=rank,stress=stressTest,key=key,checkpoints=checkpoints}
            for i=#pool,1,-1 do if pool[i].key==key then table.remove(pool,i) end end
            if not stageBest[v.to] or item.rank>stageBest[v.to].rank then stageBest[v.to]=item end
            if rank>bestRank then bestRank=rank improvedAt=attempts end
            pool[#pool+1]=item
            table.sort(pool,function(a,b) return a.rank>b.rank end)
            while #pool>24 do table.remove(pool) end
        end
        local function report(i,n,w,z,phase)
            if s.progress then s.progress(i,n,w,z.lives,phase) end
        end
        local function evaluate(policy,i,n,phase,parent)
            local key=policyKey(policy)
            if policySeen[key] then duplicatePolicies+=1 return true end
            policySeen[key]=true
            attempts+=1
            if round>0 then repairAttempts+=1 end
            local v,checkpoints=simulate(s,idx,policy,false,nil,function(w,z) report(i,n,w,z,phase) end,parent,true)
            if not v then return false end
            if not failed or score(v)>score(failed) then failed=v end
            local problem=weak(v)
            local failedStress
            local reason=not v.complete and (v.unknown>0 and "unknown_data" or v.lives<=0 and "defeat" or "enemies_remaining") or math.abs(v.ledgerError)>0.01 and "cash_mismatch" or "victory"
            if s.progress then s.progress(i,n,v.to,v.lives,"result "..phase,{reason=reason,cash=v.cash,earlyLoss=v.earlyLoss,remaining=v.remaining,remainingHP=v.remainingHP,unknown=v.unknown,spent=v.spent,income=v.income,bonuses=v.bonuses,ledgerError=v.ledgerError,attempt=attempts,wave=v.to,reusedWaves=v.reusedWaves,bossHP=v.bossHP,lastLeak=v.lastLeak,towers=v.history[#v.history] and v.history[#v.history].towers or 0,maxed=v.history[#v.history] and v.history[#v.history].maxed or 0,time=v.time}) end
            if reason=="victory" then
                local ok=true
                local worst=v.lives
                local robustEarly=v.earlyLoss or 0
                local robustTime=v.time
                local robust
                local checkPolicy=table.clone(policy)
                -- Replay the same full ability model as the search; uncertainty
                -- is handled by explicit estimates, not by deleting abilities.
                checkPolicy.grenades=true
                local checks={}
                for k in pairs(routes) do
                    local test=simulate(s,k,checkPolicy,false,v.moves,function(w,z) report(i,n,w,z,"route check "..phase) end,nil,false,v.skips)
                    if not test then return false end
                    checks[#checks+1]={route=k,complete=test.complete,lives=test.lives,earlyLoss=test.earlyLoss,remaining=test.remaining,replayed=test.replayed}
                    worst=math.min(worst,test.lives)
                    robustEarly=math.max(robustEarly,test.earlyLoss or 0)
                    robustTime=math.max(robustTime,test.time)
                    if k==idx then robust=test end
                    local why=not test.complete and (test.unknown>0 and "unknown_data" or test.lives<=0 and "defeat" or "enemies_remaining") or math.abs(test.ledgerError)>0.01 and "cash_mismatch" or test.replayed~=#v.moves and "incomplete_replay" or "passed"
                    if s.progress then s.progress(i,n,test.to,test.lives,"route result "..phase,{reason=why,cash=test.cash,earlyLoss=test.earlyLoss,remaining=test.remaining,remainingHP=test.remainingHP,unknown=test.unknown,spent=test.spent,income=test.income,bonuses=test.bonuses,ledgerError=test.ledgerError,blockedMove=test.blockedMove,replayed=test.replayed}) end
                    if why=="passed" then
                        local early=false
                        for wi,at in pairs(v.skips) do if at+1e-6<c.forecast.wave(wi).last then early=true break end end
                        if early then
                            local alternative=table.clone(checkPolicy)
                            alternative.cancelEarly=true
                            local alt=simulate(s,k,alternative,false,v.moves,nil,nil,false,v.skips)
                            if not alt then return false end
                            worst=math.min(worst,alt.lives)
                            robustEarly=math.max(robustEarly,alt.earlyLoss or 0)
                            robustTime=math.max(robustTime,alt.time)
                            if not alt.complete or alt.replayed~=#v.moves or math.abs(alt.ledgerError)>0.01 then why="early_skip_uncertain" test=alt end
                        end
                    end
                    if why~="passed" then
                        ok=false
                        failedStress=test
                        problem=test.blockedMove and math.min(weak(test),test.blockedMove.wave) or weak(test)
                        if why=="early_loss" then
                            for _,h in ipairs(test.history) do if h.wave<=5 and h.loss>0 then problem=h.wave break end end
                        end
                        break
                    end
                end
                if ok then
                    local candidate=table.clone(robust or v)
                    candidate.moves=v.moves
                    candidate.skips=v.skips
                    candidate.policy=checkPolicy
                    candidate.ready=true
                    candidate.routeLives=worst
                    candidate.checks=checks
                    candidate.abilityReplay=true
                    candidate.time=robustTime
                    if not firstWinAt then firstWinAt=os.clock() firstWinAttempt=attempts end
                    local rank=robustTime+(cfg.StartingLives-worst)*2.5+robustEarly*2+#v.moves*0.001
                    candidate.selectionScore=rank
                    if not best or rank<best.selectionScore or rank==best.selectionScore and worst>best.routeLives then best=candidate end
                end
            end
            retain(v,policy,problem,failedStress,checkpoints)
            return true
        end
        for i,p in ipairs(policies) do
            if not evaluate(p,i,#policies,"search") then return end
            if stopSearch() then break end
        end
        while not stopSearch() do
            if s.cancel and s.cancel() then return end
            round+=1
            local parents=table.clone(pool)
            local diverse={}
            for w=1,maxWave do if stageBest[w] then diverse[#diverse+1]=stageBest[w] end end
            local stagnating=not best and attempts-improvedAt>=36
            assert(#parents>0,"no evaluated candidates")
            local count=12
            local tested=0
            for i=1,count do
                if s.cancel and s.cancel() then return end
                local parent=parents[1+((round+i-2)%math.min(#parents,i%4==0 and 24 or 6))]
                if i%4==0 and #diverse>0 then parent=diverse[1+((round+i)%#diverse)] end
                local source=parent.stress or parent.v
                local w=(best or i%3==0) and weakestLate(source) or i%3==1 and math.max(1,source.to) or parent.w
                if parent.stress and i%3~=0 then w=parent.w end
                local back=(i%4==0 and w or i%3==0 and math.min(w,4+round%5) or w>=12 and 1+(i-1)%10 or 1+(i-1)%4)
                if parent.stress then back=math.max(back,i%6) end
                local from=math.max(0,w-back)
                local to=w>=12 and maxWave or math.min(maxWave,w+1+(i%3))
                local p=table.clone(parent.p)
                p.repairs=table.clone(parent.p.repairs or {})
                local prev=settings(parent.p,from)
                local core=math.clamp((prev.core or 2)+((i%3)-1),1,w<=5 and 3 or math.min(12,math.max(3,w-3)))
                if w>=12 then core=math.max(core,math.min(12,4+round%9)) end
                local patch={from=from,to=to,core=core,upper=i%2==0 and not prev.upper or prev.upper,expand=3+i%3,depth=12+((round*17+i*13)%100),longRange=0.12+(i%5)*0.12,seed=round*count+i,flex=i%3~=0,extra=w>=9 and 2+i%8 or 0,expandCash=w>=9 and 500+(i%5)*1000 or 5500,live=w>=12}
                if i%2==0 then patch.upper=not prev.upper end
                patch.spend=i%2==0 or parent.stress~=nil
                if parent.stress then patch.flex=true end
                if w>=12 then
                    patch.late=true
                    patch.forceUpper=i%3~=0
                    patch.lateReserve=i%4==0 and 0 or i%4==1 and 1500 or i%4==2 and 3500 or 6500
                    patch.lateWeight=0.7+(i%5)*0.25
                    patch.longRange=0.25+(i%4)*0.2
                    patch.extra=math.min(30,8+round%15+i)
                    patch.expandCash=250+i%4*500
                end
                patch.core=math.clamp(core,1,w<=5 and 3 or 12)
                patch.mix=i%4==0
                patch.crossEarly=i%3==0
                patch.focus=0.8+(i%5)*0.35
                patch.risk=0.55+(i%6)*0.16
                patch.fast=i%4~=0
                patch.earlySkip=i%5==0
                patch.skipDelay=({0,2,5,10,20,35})[(i+round)%6+1]
                patch.placeBias=0.55+(i%6)*0.18
                patch.allocator=({3,1,2,3,2,0})[(i+round)%6+1]
                patch.legacySite=prev.legacySite
                patch.capitalHorizon=({18,30,45,65})[(round+i)%4+1]
                if i%3==0 then
                    p=table.clone(parent.p)
                    p.skipAges=table.clone(parent.p.skipAges or {})
                    local wi=best and 1+((round*5+i*3)%math.max(1,maxWave-1)) or math.max(1,math.min(maxWave-1,w-1-(round+i)%math.max(1,math.min(w,5))))
                    local wv=c.forecast.wave(wi)
                    local old=source.skips[wi] or math.max(15,wv.last+0.5)
                    local delta=best and ({-8,-4,-2,2,4,8})[(round+i)%6+1] or ({4,8,15,25})[(round+i)%4+1]
                    if best and not source.skips[wi] then
                        p.skipAges[wi]=math.max(20.25,wv.last+({0.5,3,7,12})[(round+i)%4+1])
                    else p.skipAges[wi]=i%6==0 and -1 or math.max(20.25,old+delta) end
                else
                    p.repairs[#p.repairs+1]=patch
                end
                if p.repairs and #p.repairs>18 then table.remove(p.repairs,1) end
                -- Periodic independent restarts break the repeated elite/checkpoint basin.
                if stagnating and i%3==1 then
                    local q=table.clone(policies[1+((round*17+i*7)%#policies)])
                    q.repairs=nil q.skipAges={}
                    q.seed=round*997+i*31
                    q.depth=12+(round*19+i*11)%140
                    q.longRange=0.15+((round+i)%9)*0.13
                    q.allocator=({3,1,3,2,0})[(round+i)%5+1]
                    q.grenades=true
                    q.legacySite=(round+i)%3==0
                    q.placeBias=0.45+((round*3+i)%11)*0.14
                    q.focus=0.65+((round+i*3)%9)*0.23
                    q.risk=0.45+((round+i)%7)*0.16
                    q.capitalHorizon=({18,30,45,65,90})[(round+i)%5+1]
                    q.fast=false q.earlySkip=false q.spend=true
                    q.repairs={{from=6,to=maxWave,core=q.allocator==3 and 1+(round+i)%4 or 4+(round+i)%9,upper=(round+i)%2==0,mix=i%2==0,crossEarly=i%3==0,depth=q.depth,longRange=q.longRange,seed=q.seed,risk=q.risk,fast=false,allocator=q.allocator,placeBias=q.placeBias,focus=q.focus,capitalHorizon=q.capitalHorizon,spend=true}}
                    p=q parent=nil from=0 to=maxWave
                elseif stagnating and i%3==2 then
                    -- Change actual combat/economic settings before the first damaging wave.
                    local first=weak(source)
                    from=math.max(0,first-3-(round%4))
                    to=maxWave
                    patch.from=from patch.to=to patch.fast=false patch.earlySkip=false
                    patch.core=first<=5 and 3 or 4+(round+i)%9
                    patch.spend=true patch.seed=round*101+i
                    p=table.clone(parent.p)
                    p.repairs=table.clone(parent.p.repairs or {})
                    p.repairs[#p.repairs+1]=patch
                    p.skipAges=table.clone(parent.p.skipAges or {})
                    for w=math.max(1,from),maxWave-1 do p.skipAges[w]=-1 end
                end
                tested+=1
                local phase=string.format("repair %d | weak wave %d | revise %d-%d%s",round,w,from,to,stagnating and " | diversify" or "")
                if not evaluate(p,i,count,phase,parent) then return end
                if stopSearch() then break end
                task.wait()
            end
            assert(tested>0,"repair batch empty")
            task.wait(0.1)
        end
        local plan=assert(best,"search ended without a validated plan")
        plan.ready=true
        prepared={moves=plan.moves,routes={}}
        for idx in pairs(routes) do
            local v,cps=simulate(s,idx,plan.policy,false,plan.moves,nil,nil,true,plan.skips)
            if not v or not v.complete or v.replayed~=#plan.moves then prepared=nil break end
            prepared.routes[idx]=cps
        end
        plan.model="adaptive_v26_committed_final_capital"
        plan.repairAttempts=repairAttempts
        plan.grenadeModel="shared_catalog_and_live"
        plan.abilityModels={GrenadeLevel1=c.ability.spec("GrenadeLevel1",abilityCatalog.GrenadeLevel1,base.range),GrenadeLevel2=c.ability.spec("GrenadeLevel2",abilityCatalog.GrenadeLevel2,base.range)}
        plan.duplicatePolicies=duplicatePolicies
        plan.duplicateResults=duplicateResults
        plan.computeTime=os.clock()-began
        plan.realTime=plan.time/1.5
        plan.attempts=attempts
        plan.repairRounds=round
        return nil,plan
    end
    return x
end
return m
