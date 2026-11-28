local m={version="adaptive-v28"}

function m.new(c,routes,los,spots)
    local x={}
    local cfg=c.economy.config
    local maxWave=#cfg.Waves
    local stats={}
    local base=c.ranger.stats(0,0)
    local radius=base.radius or 1.5
    local spacing=radius*2+0.005
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
    local function profile(pos,range,idx,slice,independent)
        local k=string.format("%.3f:%.3f:%.3f:%.2f:%s:%s",pos.X,pos.Y,pos.Z,range,tostring(idx),tostring(independent==true))
        if profiles[k] then return profiles[k] end
        local hit={}
        local length,first=0,math.huge
        for d,p in pairs(routePoints[idx]) do
            if slice and d%32==0 then slice() end
            if (p-pos).Magnitude<=range-0.2 and (independent or los(pos,p)) then
                hit[d]=true
                length+=1
                first=math.min(first,d)
            end
        end
        local windows={}
        local sectors={}
        local routeLength=routes[idx].length
        local open
        for d=0,math.ceil(routeLength) do
            if hit[d] and d<routeLength then
                if not open then open=d end
                local bin=math.min(8,1+math.floor(d/math.max(1,routeLength)*8))
                sectors[bin]=(sectors[bin] or 0)+math.min(1,routeLength-d)
            elseif open then
                windows[#windows+1]={a=open,b=math.min(d,routeLength)}
                open=nil
            end
        end
        local v={hit=hit,length=length,first=first,windows=windows,sectors=sectors,pos=pos,range=range}
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
    -- Expected occupied seconds, with a shared fire-time budget across groups.
    -- Each window is a visible interval of the route, not a circle area.
    local function fireBudget(p,wi,detect,slice)
        p.fireBudget=p.fireBudget or {}
        local key=tostring(wi)..":"..tostring(detect==true)
        if p.fireBudget[key] then return p.fireBudget[key] end
        local w=c.forecast.wave(wi)
        local result={}
        if not w then return result end
        local buckets={}
        local width=4
        local function square(x) return math.max(0,x)^2*0.5 end
        for gi,g in ipairs(w.groups or {}) do
            result[gi]={seconds=0,enemySeconds=0,earlySeconds=0}
            if not g.air and (not g.stealth or detect) then
                local speed=math.max(0.1,g.speed or 1)
                local n=math.max(1,g.count or 1)
                local first,last=g.first or 0,g.last or 0
                for _,v in ipairs(p.windows) do
                    local a,b=v.a/speed,v.b/speed
                    local start,finish=first+a,last+b
                    local function integral(t)
                        if last-first<0.0001 then return n*math.clamp(t-start,0,b-a) end
                        return n/(last-first)*(square(t-first-a)-square(t-last-a)-square(t-first-b)+square(t-last-b))
                    end
                    for k=math.floor(start/width),math.ceil(finish/width)-1 do
                        local mass=math.max(0,integral((k+1)*width)-integral(k*width))
                        if mass>0.00001 then
                            local bucket=buckets[k] or {total=0,groups={}}
                            buckets[k]=bucket
                            bucket.total+=mass
                            bucket.groups[gi]=(bucket.groups[gi] or 0)+mass
                        end
                    end
                end
            end
            if slice then slice() end
        end
        for k,bucket in pairs(buckets) do
            local share=math.min(1,width/bucket.total)
            for gi,mass in pairs(bucket.groups) do
                local v=result[gi]
                v.seconds+=mass*share
                v.enemySeconds+=mass
                v.earlySeconds+=mass*share/(1+k*width/30)
            end
        end
        p.fireBudget[key]=result
        return result
    end
    local goals=c.ranger.all()
    table.sort(goals,function(a,b)
        if a.cost~=b.cost then return a.cost<b.cost end
        return a.path1*10+a.path2<b.path1*10+b.path2
    end)
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
    -- No level, upgrade branch, or tower-count target is a policy parameter.
    for i=1,36 do
        policies[i]={allocator=5,grenades=true,capitalHorizon=({18,30,50,75})[(i-1)%4+1],lookAhead=({2,3,5})[(i-1)%3+1],priceExponent=({0.65,0.85,1})[(i-1)%3+1],timeWeight=({0.15,0.4,0.75})[(math.floor((i-1)/3))%3+1],portfolioWait=({1,1.3,1.7})[(math.floor((i-1)/4))%3+1],risk=({0.85,1,1.2})[(i-1)%3+1],siteBreadth=({4,6,8})[(i-1)%3+1],fast=i%3~=1,earlySkip=false,skipDelay=({0,3,8,15})[(i-1)%4+1]}
    end
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
        local function sites()
            local list=siteProfiles[idx]
            if not list then
                list={}
                for i,item in ipairs(spots) do
                    if i%16==0 then pause() end
                    local p=item.pos
                    local a=profile(p,base.range,idx,slice)
                    local b=profile(p,maxRange,idx,slice)
                    if b.length>0 then list[#list+1]={i=i,pos=p,a=a,b=b} end
                end
                siteProfiles[idx]=list
            end
            for j=indexed+1,#z.towers do
                local pos=z.towers[j].pos
                for i,item in ipairs(list) do nearest[i]=math.min(nearest[i] or math.huge,(pos-item.pos).Magnitude) end
            end
            indexed=#z.towers
            return list
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
            local elapsed=math.max(dt,z.time-(z.cashSampleAt or z.time-dt))
            local earned=math.max(0,z.income-(z.cashSampleIncome or z.income))
            local alpha=1-math.exp(-elapsed/6)
            z.cashRate=(z.cashRate or 0)*(1-alpha)+earned/elapsed*alpha
            z.cashSampleAt=z.time
            z.cashSampleIncome=z.income
            if wi>0 and z.time<(z.portfolioAt or 0) then return end
            z.portfolioAt=z.time+0.9
            local horizon=opt.capitalHorizon or 30
            local final=wi==maxWave
            local function adjusted(raw,e,kind,ignore)
                local resist=ignore and 0 or math.clamp((e.resist or {})[tostring(kind)] or 0,0,1)
                local v=raw*(1-resist)*(1-math.clamp(e.allReduction or 0,0,1))
                if e.maxDamage and e.maxDamage>=0 then v=math.min(v,e.maxDamage) end
                return v
            end
            local function impact(st,p,e,delay)
                if e.air or e.stealth and not st.stealthDetection then return 0 end
                local speed=math.max(0.1,e.speed or 1)
                if (e.sludgeUntil or 0)>z.time then speed*=1.8 end
                local d=e.dist or 0
                local n=math.max(1,st.burstSize or 1)
                local interval=math.max(dt,st.burstInterval or dt)
                local reload=math.max(dt,st.reload)
                local cycle=reload+(n-1)*interval
                local nextShot=delay
                local shots=0
                for _,v in ipairs(p.windows) do
                    local a=math.max(delay,(v.a-d)/speed,nextShot)
                    local b=(v.b-d)/speed
                    if a<b then
                        local span=b-a
                        local full=math.floor(span/cycle)
                        local rem=span-full*cycle
                        local partial=math.min(n,math.max(0,math.ceil(rem/interval-1e-6)))
                        shots+=full*n+partial
                        if partial>0 then nextShot=a+full*cycle+(partial-1)*interval+(partial==n and reload or interval)
                        else nextShot=a+full*cycle end
                    end
                end
                local damage=shots*adjusted(st.damage,e,st.damageType,st.ignoreResistance)
                local g=grenadeSpec(st)
                if g and not g.manual and not g.passive and not g.custom then
                    local gp=profile(p.pos,g.range,idx,slice,g.independent==true)
                    local ready=delay
                    local casts=0
                    for _,v in ipairs(gp.windows) do
                        local a=math.max(delay,ready,(v.a-d)/speed)
                        local b=(v.b-d)/speed-0.5
                        if a<b then
                            local count=math.ceil((b-a)/g.cooldown)
                            casts+=count ready=a+count*g.cooldown
                        end
                    end
                    damage+=casts*adjusted(g.damage*(g.estimated and 0.65 or 1),e,g.kind,false)
                end
                return damage
            end
            local urgent={}
            local population=0
            for _,e in ipairs(z.enemies) do if not e.dead and not e.air then population+=1 end end
            danger=0
            for _,e in ipairs(z.enemies) do
                if not e.dead and not e.air then
                    local demand=e.hp+(e.shield or 0)+(e.extra or 0)
                    local eta=math.max(0.1,(r.length-e.dist)/math.max(0.1,e.speed or 1))
                    local capacity=0
                    for _,v in ipairs(z.towers) do capacity+=impact(v.st,v.profile,e,0) end
                    -- Existing fire time is shared: estimate actual simultaneous
                    -- occupants, not enemy iteration order.
                    local share=1+math.max(0,population-1)*0.10
                    local covered=capacity/share
                    local weight=1+2*math.max(0,1-eta/30)
                    local deficit=math.max(0,demand-covered)
                    danger=math.max(danger,deficit/math.max(1,demand)*weight)
                    urgent[#urgent+1]={e=e,demand=demand,covered=covered,share=share,weight=weight,eta=eta,deficit=deficit}
                end
            end
            table.sort(urgent,function(a,b)
                local av=a.deficit*a.weight+0.02*a.demand
                local bv=b.deficit*b.weight+0.02*b.demand
                if av~=bv then return av>bv end
                return a.eta<b.eta
            end)
            while #urgent>12 do table.remove(urgent) end
            local future={}
            local firstWave=math.max(1,wi)
            local nextAge=wi==0 and (cfg.SetUpTime or 15) or math.max(0,(cfg.Waves[wi].CustomWaveTime or 60)-age)
            local waveStart=wi==0 and nextAge or -age
            for offset=0,(opt.lookAhead or 3)-1 do
                local index=firstWave+offset
                local w=c.forecast.wave(index)
                if not w then break end
                for gi,g in ipairs(w.groups or {}) do
                    if not g.air then
                        local n=g.count or 1
                        local fraction=1
                        if wi>0 and index==wi then
                            if age>=(g.last or 0) then fraction=0
                            elseif age>(g.first or 0) then fraction=math.clamp(((g.last or 0)-age)/math.max(0.01,(g.last or 0)-(g.first or 0)),0,1) end
                        end
                        if fraction>0 then
                            local hp=g.hp+(g.shield or 0)+(g.extra or 0)
                            future[#future+1]={e=g,gi=gi,wi=index,n=n,fraction=fraction,demand=hp*n*fraction,weight=1/(1+offset),start=waveStart}
                        end
                    end
                end
                waveStart+=(cfg.Waves[index].CustomWaveTime or 60)
            end
            local function futurePower(st,p,g)
                p.power=p.power or {}
                local key=g.wi..":"..g.gi..":"..st.path1..":"..st.path2
                local v=p.power[key]
                if not v then
                    local b=fireBudget(p,g.wi,st.stealthDetection,slice)[g.gi]
                    local rate=adjusted(st.damage,g.e,st.damageType,st.ignoreResistance)*math.max(1,st.burstSize or 1)/math.max(dt,st.reload+(math.max(1,st.burstSize or 1)-1)*math.max(dt,st.burstInterval or dt))
                    local capacity=b.seconds*rate
                    local early=b.earlySeconds*rate
                    local ability=grenadeSpec(st)
                    if ability and not ability.manual and not ability.passive and not ability.custom then
                        local gp=profile(p.pos,ability.range,idx,slice,ability.independent==true)
                        local a=fireBudget(gp,g.wi,st.stealthDetection,slice)[g.gi]
                        local splash=math.clamp(a.enemySeconds/math.max(1,a.seconds),1,3)
                        local rate=adjusted(ability.damage*(ability.estimated and 0.65 or 1),g.e,ability.kind,false)/ability.cooldown*splash
                        capacity+=a.seconds*rate early+=a.earlySeconds*rate
                    end
                    v={damage=capacity,early=early}
                    p.power[key]=v
                end
                return v.damage*g.fraction,v.early*g.fraction
            end
            local portfolio={}
            for i,g in ipairs(future) do
                local sum,early=0,0
                for _,v in ipairs(z.towers) do
                    local a,b=futurePower(v.st,v.profile,g)
                    sum+=a early+=b
                end
                portfolio[i]=sum
            end
            if z.coverageWave~=wi then
                local detail={}
                for i,g in ipairs(future) do
                    local seconds=math.max(1,(g.e.last or 0)-(g.e.first or 0)+r.length/math.max(0.1,g.e.speed or 1))
                    detail[#detail+1]={wave=g.wi,type=g.e.type,demand=g.demand,estimatedCapacity=portfolio[i],requiredAverageDPS=g.demand/seconds,estimatedAverageDPS=portfolio[i]/seconds,deficit=math.max(0,g.demand-portfolio[i])}
                end
                z.coverageWave=wi
                z.coverageBudget={routeLength=r.length,towers=#z.towers,cash=z.cash,groups=detail}
            end
            local sectorPower={}
            for _,v in ipairs(z.towers) do
                for i,length in pairs(v.profile.sectors) do sectorPower[i]=(sectorPower[i] or 0)+length*v.st.dps end
            end
            local income=math.max(1,z.cashRate or 0)
            local nextBonus=wi<maxWave and c.economy.bonus(wi+1) or 0
            local function funding(price)
                local missing=math.max(0,price-z.cash)
                local wait=missing/income
                if nextBonus>0 and wait>nextAge then wait=nextAge+math.max(0,missing-income*nextAge-nextBonus)/income end
                return wait
            end
            local function gain(old,oldP,st,p,delay)
                local current,futureValue,norm,early=0,0,0,0
                for _,q in ipairs(urgent) do
                    local oldD=old and impact(old,oldP,q.e,delay)/q.share or 0
                    local newD=impact(st,p,q.e,delay)/q.share
                    local residual=math.max(0,q.demand-math.max(0,q.covered-oldD))
                    current+=(math.min(residual,newD)-math.min(residual,oldD))*q.weight
                    if final then early+=math.max(0,newD-oldD)*0.02/math.max(1,q.eta) end
                end
                for i,g in ipairs(future) do
                    local oldD,oldEarly=0,0
                    if old then oldD,oldEarly=futurePower(old,oldP,g) end
                    local newD,newEarly=futurePower(st,p,g)
                    local available=math.clamp(1-math.max(0,delay-g.start-(g.e.first or 0))/math.max(1,(g.e.last or 0)-(g.e.first or 0)+r.length/math.max(0.1,g.e.speed or 1)),0,1)
                    local residual=math.max(0,g.demand-math.max(0,portfolio[i]-oldD))
                    futureValue+=g.weight*(math.min(residual,newD)-math.min(residual,oldD))*available/math.max(1,g.n*g.fraction)
                    early+=g.weight*(math.min(g.demand,newEarly)-math.min(g.demand,oldEarly))*available/math.max(1,g.n*g.fraction)
                    norm+=g.weight
                end
                return current/math.max(1,#urgent)+futureValue/math.max(1,norm)+early/math.max(1,norm)*(opt.timeWeight or 0.4)
            end
            local chosen,waiting
            local function consider(v,pos,step,goal,slotPrice)
                local old=v and v.st
                local price=step.cost-(old and old.cost or 0)
                local cost=goal.cost-(old and old.cost or 0)
                if price<=0 or cost<price then return end
                local wait=funding(cost)
                if wait>horizon or final and cost>z.cash then return end
                local delay=wait+0.45*(goal.path1+goal.path2-(old and old.path1+old.path2 or 0)+(v and 0 or 1))
                local discount=math.max(0,1-delay/horizon)
                local benefit=gain(old,v and v.profile,goal,profile(pos,goal.range,idx,slice),delay)
                local rank
                if final then rank=benefit*discount/(1+cost/math.max(1,z.cash)*0.15)
                else rank=benefit*discount/math.max(1,cost+(slotPrice or 0))^(opt.priceExponent or 0.85) end
                if rank<=0 then return end
                local item={v=v,pos=pos,step=step,goal=goal,rank=rank,wait=wait}
                if cost<=z.cash and price<=z.cash then
                    if not chosen or rank>chosen.rank then chosen=item end
                elseif not waiting or rank>waiting.rank then waiting=item end
            end
            for _,v in ipairs(z.towers) do
                pause()
                local a,b=v.st.path1,v.st.path2
                local one,two=stats[(a+1)*10+b],stats[a*10+b+1]
                for _,goal in ipairs(goals) do
                    if goal.cost>v.st.cost and goal.path1>=a and goal.path2>=b then
                        local step1=goal.path1>a and one or nil
                        local step2=goal.path2>b and two or nil
                        local step=step1 or step2
                        if step1 and step2 then
                            local rank1=gain(v.st,v.profile,step1,profile(v.pos,step1.range,idx,slice),0.45)/math.max(1,step1.cost-v.st.cost)
                            local rank2=gain(v.st,v.profile,step2,profile(v.pos,step2.range,idx,slice),0.45)/math.max(1,step2.cost-v.st.cost)
                            if rank2>rank1 then step=step2 end
                        end
                        if step then consider(v,v.pos,step,goal) end
                    end
                end
            end
            if #z.towers<cap and z.cash>=base.cost then
                local ranked={}
                for i,item in ipairs(sites()) do
                    if i%32==0 then pause() end
                    if (nearest[i] or math.huge)>=spacing-0.01 then
                        local a,b,live=0,0,0
                        for j,length in pairs(item.a.sectors) do a+=length/(1+(sectorPower[j] or 0)/math.max(1,base.dps*r.length/8)) end
                        for j,length in pairs(item.b.sectors) do b+=length/(1+(sectorPower[j] or 0)/math.max(1,base.dps*r.length/8)) end
                        for _,q in ipairs(urgent) do
                            local d=math.floor(q.e.dist+0.5)
                            live+=q.weight*(tail(item.a,d,1,last)+0.4*tail(item.b,d,1,last))
                        end
                        ranked[#ranked+1]={pos=item.pos,a=a,b=b,early=a/(1+item.a.first/30),live=live/math.max(1,#urgent),index=i}
                    end
                end
                local slotPrice=final and 0 or z.cash/math.max(1,math.min(cap-#z.towers,#ranked))*0.2
                local shortlist={}
                local breadth=opt.siteBreadth or 6
                local function pick(field)
                    table.sort(ranked,function(a,b) if a[field]~=b[field] then return a[field]>b[field] end return a.index<b.index end)
                    local count=0
                    for _,item in ipairs(ranked) do
                        local distinct=true
                        for _,pos in ipairs(shortlist) do if (pos-item.pos).Magnitude<spacing*1.5 then distinct=false break end end
                        if distinct and item[field]>0 then shortlist[#shortlist+1]=item.pos count+=1 end
                        if count>=math.max(1,math.floor(breadth/3)) then break end
                    end
                end
                pick("early") pick("a") pick("b") pick("live")
                for _,pos in ipairs(shortlist) do
                    pause()
                    for _,goal in ipairs(goals) do consider(nil,pos,base,goal,slotPrice) end
                end
            end
            local choice=chosen
            local threatened=danger>(opt.risk or 1)
            if waiting and chosen and not final and not threatened and waiting.rank>chosen.rank*(opt.portfolioWait or 1.3) and waiting.wait<horizon*0.45 then choice=nil end
            local t,cost
            if choice then
                if choice.v then t,cost=upgrade(choice.v,choice.step)
                else t,cost=install(choice.pos,choice.goal.path1>=choice.goal.path2) end
            end
            if t then
                z.portfolioAt=z.time+0.45
                z.moves[#z.moves+1]={wave=wi,age=age,pos=c.physics.pack(t.pos),path1=t.st.path1,path2=t.st.path2,price=cost,upper=t.upper,finalChain=final}
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
                    local up=v.path1>v.path2
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
            z.history[#z.history+1]={wave=wi,coverageBudget=z.coverageWave==wi and z.coverageBudget or nil,grenadeCasts=(z.grenadeCount or 0)-grenadeBefore,skipped=skipped,maxed=maxed,loss=delta,lives=z.lives,cash=z.cash,towers=#z.towers,time=z.time-start,remaining=#z.enemies,remainingHP=remainingHP,income=z.income,spent=z.spent,bonuses=z.bonuses,hpDamage=hpDamage,shieldDamage=shieldDamage,paidDamage=paidDamage,sludgeHits=sludgeHits}
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
            local fields={"allocator","capitalHorizon","lookAhead","priceExponent","timeWeight","portfolioWait","risk","siteBreadth","fast","earlySkip","skipDelay"}
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
                local patch=table.clone(settings(parent.p,from))
                patch.from=from patch.to=to
                patch.capitalHorizon=({15,22,35,55,80,110})[(i+round)%6+1]
                patch.lookAhead=({2,3,4,5})[(i+round)%4+1]
                patch.priceExponent=0.55+((round+i)%6)*0.10
                patch.timeWeight=0.10+((round*3+i)%8)*0.13
                patch.portfolioWait=0.85+((round+i)%6)*0.20
                patch.risk=0.65+((round+i)%5)*0.16
                patch.siteBreadth=({3,6,9})[(i+round)%3+1]
                patch.fast=i%4~=0 patch.earlySkip=false
                patch.skipDelay=({0,2,5,10,20,35})[(i+round)%6+1]
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
                    q.capitalHorizon=15+(round*13+i*11)%90
                    q.lookAhead=2+(round+i)%4
                    q.priceExponent=0.55+((round*7+i)%9)*0.07
                    q.timeWeight=0.10+((round*3+i)%12)*0.10
                    q.portfolioWait=0.8+((round+i)%9)*0.15
                    q.risk=0.65+((round+i)%7)*0.14
                    q.siteBreadth=({3,6,9,12})[(round+i)%4+1]
                    q.fast=false q.earlySkip=false
                    p=q parent=nil from=0 to=maxWave
                elseif stagnating and i%3==2 then
                    -- Change actual combat/economic settings before the first damaging wave.
                    local first=weak(source)
                    from=math.max(0,first-3-(round%4))
                    to=maxWave
                    patch.from=from patch.to=to patch.fast=false patch.earlySkip=false
                    patch.siteBreadth=9
                    patch.risk=0.65
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
        plan.model="adaptive_v28_route_fire_time_budget"
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
