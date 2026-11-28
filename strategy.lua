local m={version="adaptive-v14"}

function m.new(c,routes,los,spots)
    local x={}
    local cfg=c.economy.config
    local maxWave=#cfg.Waves
    local stats={}
    local base=c.ranger.stats(0,0)
    local radius=base.radius or 1.5
    local spacing=radius*2+0.05
    for _,v in ipairs(c.ranger.all()) do stats[v.path1*10+v.path2]=v end
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
        local cap=(s.towerLimit and s.towerLimit>0) and s.towerLimit or 40
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
        if not live and keep and parent then
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
                    if a.length>0 then list[#list+1]={i=i,pos=p,a=a,b=profile(p,20,idx,slice)} end
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
                    local a,b=item.a,item.b
                    if a.length>0 then
                        local density=near==math.huge and 1 or 1+0.55/(1+math.max(0,near-spacing)/spacing)
                        local depth=opt.depth or (opt.siteMode==2 and 40 or opt.siteMode==3 and 65 or 17)
                        local early=1/(1+a.first/(wi<8 and depth or 55))
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
                                v=(baseReach+reach*0.35)*density
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
            t.st=st
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
            local need=math.clamp(opt.core or 2,1,3)
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
            local best,affordable
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
                    local goal=stats[upper and 52 or 25] or base
                    local immediate=merit(base,pos,profile(pos,base.range,idx,slice))
                    local later=merit(goal,pos,profile(pos,goal.range,idx,slice))
                    local rank=(immediate/base.cost^0.65+later/goal.cost^0.65*(opt.focus or 1))*(opt.placeBias or 0.9)
                    if threatened then rank*=1.3 elseif best and best.price>z.cash then rank*=0.65 end
                    if wi==0 and #z.towers>=need then rank=0 end
                    placeOption={pos=pos,upper=upper,rank=rank}
                end
            end
            local choice=best and best.price<=z.cash and best or threatened and affordable or nil
            if #z.towers==0 then
                if placeOption then t,cost=install(placeOption.pos,placeOption.upper) end
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
                    local t={pos=pos,st=st,profile=profile(pos,st.range,idx,slice),upper=up,nextShot=shot+stun,left=left,active=z.time,stunUntil=z.time+stun,lastShot=lastShot,query=v.query or 0,fireAt=z.time+(v.abilities and v.abilities.M203 and v.abilities.M203.cooldown or 0)}
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
            local skipped=false
            local limit=math.max(w.last or 0,cfg.Waves[wi].CustomWaveTime or 60)
            if currentLive then limit=math.max(live.age+live.delay,firstStep*dt+dt) end
            if wi==maxWave then limit=math.max(180,w.last+r.length/0.8+30,limit) end
            local steps=math.ceil(limit/dt)
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
                    if z.time>=f.finish then table.remove(fires,j)
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
                if wi==maxWave and event>#w.events and n==0 and #pending==0 and age>=w.last then break end
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
            z.history[#z.history+1]={wave=wi,skipped=skipped,maxed=maxed,loss=delta,lives=z.lives,cash=z.cash,towers=#z.towers,time=z.time-start,remaining=#z.enemies,remainingHP=remainingHP,income=z.income,spent=z.spent,bonuses=z.bonuses,hpDamage=hpDamage,shieldDamage=shieldDamage,paidDamage=paidDamage,sludgeHits=sludgeHits}
            if z.lives>0 and unknown==0 then checkpoint(wi) end
            if notify then notify(wi,z) end
            if z.lives<=0 or unknown>0 then break end
        end
        local complete=#z.history==maxWave and #z.enemies==0 and #pending==0 and z.lives>0 and unknown==0
        local ledgerError=z.cash-(initialCash+z.income+z.bonuses-z.spent)
        local bossHP=0
        for _,e in ipairs(z.enemies) do if e.type=="Plague Doctor" then bossHP+=e.hp end end
        return {blockedMove=blockedMove,ledgerError=ledgerError,income=z.income,spent=z.spent,bonuses=z.bonuses,remainingHP=z.history[#z.history] and z.history[#z.history].remainingHP or 0,from=1,to=#z.history,targetWave=maxWave,loss=z.loss,lives=z.lives,earlyLoss=z.earlyLoss,cash=z.cash,time=z.time-(live and live.age or 0),history=z.history,moves=z.moves,skips=z.skips,complete=complete,remaining=#z.enemies,unknown=unknown,policy=policy,stress=stress,replayed=cursor-1,reusedWaves=firstWave-1,lastLeak=z.lastLeak,bossHP=bossHP},checkpoints
    end
    local function objective(v,startHP)
        local lost=math.max(0,startHP-v.lives)
        return v.time+lost*0.4+80*(lost/math.max(1,startHP))^2
    end
    local function compareBoundary(got,ref)
        if not got or not ref then return false,"missing_checkpoint" end
        local a,b=got.z,ref.z
        if a.lives+0.01<b.lives then return false,"hp" end
        if a.cash+0.01<b.cash then return false,"cash" end
        if #got.pending>0 or #got.sludge>0 or #got.fires>0 then return false,"pending_effects" end
        for _,t in ipairs(b.towers) do
            local found
            for _,v in ipairs(a.towers) do
                if (v.pos-t.pos).Magnitude<0.1 and v.st.path1==t.st.path1 and v.st.path2==t.st.path2 and (v.query or 0)==(t.query or 0) then found=v break end
            end
            if not found then return false,"tower" end
            if (found.stunUntil or 0)>a.time or (found.smokeUntil or 0)>a.time then return false,"debuff" end
            if math.max(0,found.nextShot-a.time)>math.max(0,t.nextShot-b.time)+0.25 then return false,"cooldown" end
        end
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
        if not target or wi>=maxWave-1 or at+0.1<target or at>=s.waveAge+s.timerRemaining-0.1 then return nil,"outside_window" end
        if at<c.forecast.wave(wi).last or (rollout.skips[wi+1] and rollout.skips[wi+1]<c.forecast.wave(wi+1).last) then return nil,"early_spawn_uncertainty" end
        if wi>1 and rollout.skips[wi-1] and rollout.skips[wi-1]<c.forecast.wave(wi-1).last then return nil,"prior_spawns" end
        local moves={}
        for i=cursor or 1,#rollout.moves do
            local v=rollout.moves[i]
            if v.wave<=wi then return nil,"pending_purchase" end
            if v.wave>wi+1 then break end
            moves[#moves+1]=v
        end
        local skips=table.clone(rollout.skips)
        skips[wi]=at
        local simState=table.clone(s)
        local started=os.clock()
        simState.cancel=function() return os.clock()-started>math.min(2.5,math.max(0.5,s.timerRemaining/math.max(1,s.speed or 1)-3.5)) end
        local worst=math.huge
        for idx in pairs(routes) do
            local ref=prepared.routes[idx] and prepared.routes[idx][wi+1]
            local v,cps=simulate(simState,idx,rollout.policy,false,moves,nil,nil,true,skips,{wave=wi,age=s.waveAge,delay=s.timerRemaining,freezePurchases=true,endWave=wi+1,history=rollout.history})
            if not v then return nil,"short_budget" end
            if v.to~=wi+1 or v.replayed~=#moves or v.unknown>0 or v.loss>0.01 or math.abs(v.ledgerError)>0.01 then return nil,"short_replay" end
            local ok,why=compareBoundary(cps[wi+1],ref)
            if not ok then return nil,"boundary_"..why end
            worst=math.min(worst,v.lives)
        end
        local threat=0
        for _,e in pairs(s.enemies or {}) do threat+=e.hp+(e.shield or 0) end
        local saved=math.max(0,s.timerRemaining-3.5*(s.speed or 1))
        return {allowed=true,prepared=true,reason="prepared_checkpoint_skip",tested=1,predictedLoss=0,checkpointWave=wi+1,checkpointHP=worst,threat=threat,lives=s.lives,delay=s.timerRemaining,saved=saved,savedReal=saved/math.max(0.01,s.speed or 1)}
    end
    function x.compareSkips(s,rollout,cursor)
        local quick,why=x.preparedSkip(s,rollout,cursor)
        if quick then return quick end
        if not s.waveAge or not s.timerRemaining or s.timerRemaining<1.5 or s.wave>=maxWave then return {allowed=false,reason="no_window"} end
        local wi=s.wave
        local age=s.waveAge
        local delay=s.timerRemaining
        local policy=rollout.policy
        local started=os.clock()
        local limit=s.runtimeSlice and math.min(7,math.max(2,delay/math.max(1,s.speed or 1)-1)) or 3
        local simState=table.clone(s)
        simState.cancel=function() return os.clock()-started>limit end
        local candidates={}
        local function evaluate(skipAt,cancelUnspawned,freezePurchases)
            local worst,finish,minimumCash,loss=math.huge,0,math.huge,0
            local chosen
            for idx in pairs(routes) do
                local v=simulate(simState,idx,policy,false,nil,nil,nil,false,nil,{wave=wi,age=age,delay=delay,skipAt=skipAt,cancelUnspawned=cancelUnspawned,freezePurchases=freezePurchases,history=rollout.history})
                if not v then return nil end
                if not chosen then chosen=v end
                if not v.complete or math.abs(v.ledgerError)>0.01 then
                    return {complete=false,lives=v.lives,time=v.time,loss=v.loss,at=skipAt,remaining=v.remaining}
                end
                worst=math.min(worst,v.lives)
                finish=math.max(finish,v.time)
                minimumCash=math.min(minimumCash,v.cash)
                loss=math.max(loss,v.loss)
            end
            return {complete=true,lives=worst,time=finish,loss=loss,cash=minimumCash,at=skipAt,score=objective({time=finish,lives=worst},s.lives),plan=chosen}
        end
        local wait=evaluate(nil,false)
        if not wait then return {allowed=false,reason="branch_budget",preparedReason=why,tested=0} end
        local first=age+3.5*(s.speed or 1)
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
        local attempts=0
        local round=0
        local firstWinAt,firstWinAttempt
        local function stopSearch()
            return best and (attempts-firstWinAttempt>=64 or os.clock()-firstWinAt>=18)
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
            return v.to*100000+(eligible and 10000000 or 0)-(eligible and objective(v,cfg.StartingLives) or math.max(0,v.loss)*120+(v.remainingHP or 0)*0.5)
        end
        local function retain(v,p,w,stressTest,checkpoints)
            local key={}
            for _,a in ipairs(v.moves) do key[#key+1]=string.format("%d:%.2f:%.2f:%.2f:%d:%d",a.wave,a.pos.x,a.pos.y,a.pos.z,a.path1,a.path2) end
            for wi=1,maxWave-1 do key[#key+1]=string.format("s%d:%.2f",wi,v.skips[wi] or -1) end
            key=table.concat(key,";")
            local rank=score(v)
            if stressTest then rank+=stressTest.to*5000+stressTest.lives*40-math.max(0,stressTest.earlyLoss-stressEarlyLimit)*100 end
            if signatures[key] and signatures[key]>=rank then return end
            signatures[key]=rank
            local item={v=v,p=p,w=w or weak(v),rank=rank,stress=stressTest,key=key,checkpoints=checkpoints}
            for i=#pool,1,-1 do if pool[i].key==key then table.remove(pool,i) end end
            pool[#pool+1]=item
            table.sort(pool,function(a,b) return a.rank>b.rank end)
            while #pool>24 do table.remove(pool) end
        end
        local function report(i,n,w,z,phase)
            if s.progress then s.progress(i,n,w,z.lives,phase) end
        end
        local function evaluate(policy,i,n,phase,parent)
            attempts+=1
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
                local checks={}
                for k in pairs(routes) do
                    local test=simulate(s,k,policy,false,v.moves,function(w,z) report(i,n,w,z,"route check "..phase) end,nil,false,v.skips)
                    if not test then return false end
                    checks[#checks+1]={route=k,complete=test.complete,lives=test.lives,earlyLoss=test.earlyLoss,remaining=test.remaining,replayed=test.replayed}
                    worst=math.min(worst,test.lives)
                    local why=not test.complete and (test.unknown>0 and "unknown_data" or test.lives<=0 and "defeat" or "enemies_remaining") or math.abs(test.ledgerError)>0.01 and "cash_mismatch" or test.replayed~=#v.moves and "incomplete_replay" or "passed"
                    if s.progress then s.progress(i,n,test.to,test.lives,"route result "..phase,{reason=why,cash=test.cash,earlyLoss=test.earlyLoss,remaining=test.remaining,remainingHP=test.remainingHP,unknown=test.unknown,spent=test.spent,income=test.income,bonuses=test.bonuses,ledgerError=test.ledgerError,blockedMove=test.blockedMove,replayed=test.replayed}) end
                    if why=="passed" then
                        local early=false
                        for wi,at in pairs(v.skips) do if at+1e-6<c.forecast.wave(wi).last then early=true break end end
                        if early then
                            local alternative=table.clone(policy)
                            alternative.cancelEarly=true
                            local alt=simulate(s,k,alternative,false,v.moves,nil,nil,false,v.skips)
                            if not alt then return false end
                            worst=math.min(worst,alt.lives)
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
                    v.ready=true
                    v.routeLives=worst
                    v.checks=checks
                    if not firstWinAt then firstWinAt=os.clock() firstWinAttempt=attempts end
                    local rank=objective({time=v.time,lives=worst},cfg.StartingLives)+#v.moves*0.001
                    v.selectionScore=rank
                    if not best or rank<best.selectionScore or rank==best.selectionScore and worst>best.routeLives then best=v end
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
            assert(#parents>0,"no evaluated candidates")
            local count=12
            local tested=0
            for i=1,count do
                if s.cancel and s.cancel() then return end
                local parent=parents[1+((round+i-2)%math.min(#parents,i%4==0 and 24 or 6))]
                local source=parent.stress or parent.v
                local w=(best or i%3==0) and weakestLate(source) or i%3==1 and math.max(1,source.to) or parent.w
                if parent.stress and i%3~=0 then w=parent.w end
                local back=w>=12 and 1+(i-1)%10 or (i-1)%4
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
                patch.core=math.clamp(core,1,3)
                patch.mix=i%4==0
                patch.crossEarly=i%3==0
                patch.focus=0.8+(i%5)*0.35
                patch.risk=0.55+(i%6)*0.16
                patch.fast=i%4~=0
                patch.earlySkip=i%5==0
                patch.skipDelay=({0,2,5,10,20,35})[(i+round)%6+1]
                patch.placeBias=0.5+(i%6)*0.25
                if best and i%2==0 then
                    p=table.clone(parent.p)
                    p.skipAges=table.clone(parent.p.skipAges or {})
                    local wi=1+((round*5+i*3)%math.max(1,maxWave-1))
                    local wv=c.forecast.wave(wi)
                    local old=source.skips[wi] or math.max(15,wv.last+0.5)
                    local delta=({-8,-4,-2,2,4,8})[(round+i)%6+1]
                    p.skipAges[wi]=i%6==0 and -1 or math.max(20.25,old+delta)
                else
                    p.repairs[#p.repairs+1]=patch
                end
                if p.repairs and #p.repairs>18 then table.remove(p.repairs,1) end
                tested+=1
                local phase=string.format("repair %d | weak wave %d | revise %d-%d",round,w,from,to)
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
        plan.model="adaptive_v14_checkpoint_skips"
        plan.computeTime=os.clock()-began
        plan.realTime=plan.time/1.5
        plan.attempts=attempts
        plan.repairRounds=round
        return nil,plan
    end
    return x
end
return m
