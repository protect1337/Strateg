local m={version="adaptive-v9"}

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
    local function profile(pos,range,idx)
        local k=string.format("%.3f:%.3f:%.3f:%.2f:%s",pos.X,pos.Y,pos.Z,range,tostring(idx))
        if profiles[k] then return profiles[k] end
        local hit={}
        local length,first=0,math.huge
        for d,p in pairs(routePoints[idx]) do
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
    local function path(st,upper)
        local a,b=st.path1,st.path2
        if b<1 then return stats[a*10+b+1] end
        if a<2 then return stats[(a+1)*10+b] end
        if b<2 then return stats[a*10+b+1] end
        if upper then
            if a<5 then return stats[(a+1)*10+b] end
        else
            if b<5 then return stats[a*10+b+1] end
        end
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
    local policies={
        {core=2,upper=true,expand=4},{core=2,upper=false,expand=4},
        {core=3,upper=true,expand=4},{core=3,upper=false,expand=4},
        {core=1,upper=true,expand=5},{core=2,upper=true,expand=5},
        {core=3,upper=true,expand=3},{core=2,upper=false,expand=5},
        {core=1,upper=false,expand=4,siteMode=2},{core=2,upper=false,expand=4,siteMode=2},
        {core=2,upper=true,expand=5,siteMode=2},{core=3,upper=false,expand=5,siteMode=3}
    }
    for i=1,6 do
        local p=table.clone(policies[i+6])
        p.flex=true
        p.spend=i%2==0
        p.repairs={{from=8+i%4,to=maxWave,core=3+i%3,upper=i%2==0,expand=4+i%2,depth=30+i*8,longRange=0.35+i*0.07,seed=i*37,flex=true,spend=true,extra=8+i,expandCash=500+i*250,live=true,late=true,lateReserve=0,lateWeight=1+i*0.12}}
        policies[#policies+1]=p
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
        for k,v in pairs(a) do if k~="repairs" and b[k]~=v then return false end end
        for k,v in pairs(b) do if k~="repairs" and a[k]~=v then return false end end
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
        return b
    end
    local function simulate(s,idx,policy,stress,replay,notify,parent,keep)
        local r=routes[idx]
        local z={cash=cfg.StartingCash,lives=cfg.StartingLives,towers={},enemies={},moves={},history={},time=0,loss=0,earlyLoss=0,spent=0,income=0,bonuses=0}
        local cap=(s.towerLimit and s.towerLimit>0) and s.towerLimit or 40
        local cursor=1
        local blockedMove
        local serial=0
        local nextBuy=0
        local unknown=0
        local sludge={}
        local pending={}
        local hpDamage,shieldDamage,paidDamage,sludgeHits=0,0,0,0
        local checkpoints={}
        local firstWave=1
        local last=math.ceil(r.length)
        if keep and parent then
            for wi=0,maxWave-1 do
                local cp=parent.checkpoints[wi]
                if not cp or not sameSettings(settings(policy,wi),settings(parent.p,wi)) then break end
                checkpoints[wi]=cp
                firstWave=wi+1
            end
            local cp=checkpoints[firstWave-1]
            if cp then
                z=copyState(cp.z)
                sludge=copyList(cp.sludge)
                pending=copyList(cp.pending)
                serial,nextBuy,unknown=cp.serial,cp.nextBuy,cp.unknown
                hpDamage,shieldDamage,paidDamage,sludgeHits=cp.hpDamage,cp.shieldDamage,cp.paidDamage,cp.sludgeHits
            end
        end
        local function checkpoint(wi)
            if not keep then return end
            checkpoints[wi]={z=copyState(z),sludge=copyList(sludge),pending=copyList(pending),serial=serial,nextBuy=nextBuy,unknown=unknown,hpDamage=hpDamage,shieldDamage=shieldDamage,paidDamage=paidDamage,sludgeHits=sludgeHits}
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
            a.maxHp=a.hp
            z.enemies[#z.enemies+1]=a
        end
        local function free(pos)
            for _,t in ipairs(z.towers) do if (t.pos-pos).Magnitude<spacing-0.01 then return false end end
            return true
        end
        local nearest={}
        local indexed=0
        local function site(wi)
            local best,score
            local opt=settings(policy,wi)
            local list=siteProfiles[idx]
            if not list then
                list={}
                for i,item in ipairs(spots) do
                    local p=item.pos
                    local a=profile(p,base.range,idx)
                    if a.length>0 then list[#list+1]={i=i,pos=p,a=a,b=profile(p,16,idx)} end
                end
                siteProfiles[idx]=list
            end
            for j=indexed+1,#z.towers do
                local pos=z.towers[j].pos
                for i,item in ipairs(list) do nearest[i]=math.min(nearest[i] or math.huge,(pos-item.pos).Magnitude) end
            end
            indexed=#z.towers
            local liveStarts={}
            local useLive=wi==maxWave or wi>=12 and opt.live
            if useLive then
                for _,e in ipairs(z.enemies) do
                    if not e.dead then
                        local d=math.floor(e.dist+0.5)
                        liveStarts[d]=(liveStarts[d] or 0)+(e.type=="Plague Doctor" and 3 or 1)
                    end
                end
            end
            for i,item in ipairs(list) do
                local p=item.pos
                local near=nearest[i] or math.huge
                if near>=spacing-0.01 then
                    local a,b=item.a,item.b
                    if a.length>0 then
                        local density=near==math.huge and 1 or 1+0.55/(1+math.max(0,near-spacing)/spacing)
                        local depth=opt.depth or (opt.siteMode==2 and 40 or opt.siteMode==3 and 65 or 17)
                        local early=1/(1+a.first/(wi<8 and depth or 55))
                        local v=(a.length+b.length*(opt.longRange or 0.18))*early*density
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
                            if wi==maxWave and live>0 then
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
            local t={pos=pos,st=base,profile=profile(pos,base.range,idx),upper=upper,nextShot=z.time+0.45,left=base.burstSize,active=z.time+0.45}
            z.towers[#z.towers+1]=t
            return t,base.cost
        end
        local function upgrade(t,st)
            local cost=st.cost-t.st.cost
            if cost<=0 or cost>z.cash then return false end
            if st.path1<t.st.path1 or st.path2<t.st.path2 then return false end
            z.cash-=cost
            z.spent+=cost
            t.st=st
            t.profile=profile(t.pos,st.range,idx)
            t.left=st.burstSize
            t.active=z.time+0.3
            t.nextShot=math.max(t.active,math.min(t.nextShot,z.time+st.reload))
            t.lastShot=nil
            return t,cost
        end
        local function purchase(wi,age)
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
            local t,cost
            local opt=settings(policy,wi)
            local need=opt.core
            local final=wi==maxWave and age>=c.forecast.wave(wi).last
            local function upperChoice(default) return opt.forceUpper or default end
            if wi<=2 and need>3 then need=3 end
            local stealth=false
            for _,v in ipairs(z.towers) do if v.st.stealthDetection then stealth=true break end end
            local pick
            if (opt.late and wi>=12) or final then
                local winner,rank
                local function consider(t,st,pos)
                    local old=t and t.st
                    local cost=st.cost-(old and old.cost or 0)
                    if cost<=0 or cost>z.cash then return end
                    local coverage=profile(pos,st.range,idx)
                    local usable=coverage.length
                    if #z.enemies>0 and wi>=maxWave then
                        usable=0
                        for _,e in ipairs(z.enemies) do
                            if not e.dead and not e.air and (not e.stealth or st.stealthDetection) then
                                local n=tail(coverage,math.floor(e.dist+0.5),3,last)
                                usable+=n*(e.type=="Plague Doctor" and 3 or 1)
                            end
                        end
                    end
                    if usable<=0 then return end
                    local power=st.dps
                    local prev=old and old.dps or 0
                    local gain=math.max(0,power-prev)
                    if st.stealthDetection and not (old and old.stealthDetection) then gain+=power*0.25 end
                    local v=gain*usable/math.max(1,cost)^0.65
                    if final then
                        local benefit=0
                        for _,e in ipairs(z.enemies) do
                            if not e.dead and not e.air then
                                local d=math.floor(e.dist+0.5)
                                local function damage(q,p)
                                    if not q or e.stealth and not q.stealthDetection then return 0 end
                                    local resist=q.ignoreResistance and 0 or math.clamp(e.resist[tostring(q.damageType)] or 0,0,1)
                                    return q.dps*(1-resist)*tail(p,d,3,last)/math.max(0.1,e.speed)
                                end
                                benefit+=math.max(0,damage(st,coverage)-damage(old,t and t.profile))*(1+math.min(3,e.hp/math.max(1,z.lives)))
                            end
                        end
                        v=benefit/math.max(1,cost)^0.65
                    end
                    if t then v*=opt.lateWeight or 1 else v*=0.75 end
                    if v>0 and (not rank or v>rank) then winner={t=t,st=st,pos=pos} rank=v end
                end
                for _,v in ipairs(z.towers) do
                    local nextSt=path(v.st,v.upper)
                    if nextSt then consider(v,nextSt,v.pos) end
                end
                if #z.towers<cap and z.cash>=base.cost then
                    local pos=site(wi)
                    if pos then consider(nil,base,pos) end
                end
                if winner then
                    if winner.t then t,cost=upgrade(winner.t,winner.st)
                    elseif z.cash>=(opt.lateReserve or 0)+base.cost or not next(z.towers) or wi==maxWave then
                        t,cost=install(winner.pos,upperChoice(#z.towers%3~=2))
                    end
                end
            end
            if final and not t then return end
            if not t and #z.towers<need then
                if #z.towers==0 or z.towers[1].st.path1+z.towers[1].st.path2>=2 then
                    if z.cash>=base.cost then
                        local upper=opt.upper
                        if #z.towers%2==1 then upper=not upper end
                        t,cost=install(site(wi),upperChoice(upper))
                    end
                end
            end
            if not t then
                if wi>=6 and not stealth then
                    for _,v in ipairs(z.towers) do if v.upper and v.st.path1<3 then pick=v break end end
                    if not pick and #z.towers<cap and z.cash>=base.cost then t,cost=install(site(wi),true) end
                end
                if not t and not pick then
                    for _,v in ipairs(z.towers) do
                        if path(v.st,v.upper) and math.max(v.st.path1,v.st.path2)<opt.expand then
                            if not pick or v.st.cost>pick.st.cost then pick=v end
                        end
                    end
                    if not pick then
                        for _,v in ipairs(z.towers) do
                            if path(v.st,v.upper) and (not pick or v.st.cost>pick.st.cost) then pick=v end
                        end
                        if wi>=9 and #z.towers<cap and z.cash>=(opt.expandCash or 5500) and #z.towers<math.max(need,wi-5+(opt.extra or 0)) then
                            t,cost=install(site(wi),upperChoice(#z.towers%2==0))
                        end
                    end
                end
                if not t and pick then
                    local st=path(pick.st,pick.upper)
                    if st then t,cost=upgrade(pick,st) end
                    if not t and opt.flex and wi>=3 then
                        local choice,nextSt,rank
                        for _,v in ipairs(z.towers) do
                            local a=path(v.st,v.upper)
                            if a and a.cost-v.st.cost<=z.cash then
                                local gain=(a.dps-v.st.dps)/math.max(1,a.cost-v.st.cost)
                                if a.stealthDetection and not v.st.stealthDetection then gain+=0.02 end
                                if a.ignoreResistance and not v.st.ignoreResistance then gain+=0.02 end
                                if not rank or gain>rank then choice,nextSt,rank=v,a,gain end
                            end
                        end
                        if choice then t,cost=upgrade(choice,nextSt)
                        elseif wi>=6 and #z.towers<math.min(cap,need+(opt.extra or 0)) and z.cash>=base.cost then
                            t,cost=install(site(wi),upperChoice(#z.towers%2==0))
                        end
                    end
                elseif not t and not pick and z.cash>=base.cost and #z.towers<cap then
                    t,cost=install(site(wi),upperChoice(#z.towers%2==0))
                end
            end
            if not t and (opt.flex or wi>=6 and z.cash>=3500) and z.cash>=165 and wi>=1 then
                local urgent=false
                for _,e in ipairs(z.enemies) do
                    if not e.dead and e.dist>=r.length*0.55 then urgent=true break end
                end
                local choice,nextSt,rank
                for _,v in ipairs(z.towers) do
                    local a=path(v.st,v.upper)
                    if a and a.cost-v.st.cost<=z.cash then
                        local p=profile(v.pos,a.range,idx)
                        local reach=p.length
                        if urgent then
                            reach=0
                            for _,e in ipairs(z.enemies) do
                                if not e.dead and (not e.stealth or a.stealthDetection) then
                                    reach+=tail(p,math.floor(e.dist+0.5),4,last)
                                end
                            end
                        end
                        local gain=(a.dps-v.st.dps)*reach/math.max(1,a.cost-v.st.cost)^0.65
                        if a.stealthDetection and not v.st.stealthDetection then gain+=reach*0.05 end
                        if gain>0 and (not rank or gain>rank) then choice,nextSt,rank=v,a,gain end
                    end
                end
                if choice and (urgent or z.cash>=2500 or opt.spend) then t,cost=upgrade(choice,nextSt) end
                if not t and urgent and z.cash>=base.cost and #z.towers<math.min(cap,wi<=5 and 3 or math.max(need,wi-3)) then
                    t,cost=install(site(wi),upperChoice(not stealth or #z.towers%2==0))
                end
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
        if not checkpoints[0] then
            for i=1,12 do purchase(0,0) end
            z.time=cfg.SetUpTime or 15
            checkpoint(0)
        end
        for wi=firstWave,maxWave do
            if s.cancel and s.cancel() then return end
            local w=c.forecast.wave(wi)
            unknown+=w.unknown or 0
            local bonus=c.economy.bonus(wi)
            z.cash+=bonus
            z.bonuses+=bonus
            local start=z.time
            local event=1
            local lossBefore=z.loss
            local limit=math.max(w.last or 0,cfg.Waves[wi].CustomWaveTime or 60)
            if wi==maxWave then limit=math.max(180,w.last+r.length/0.8+30) end
            local steps=math.ceil(limit/dt)
            for k=0,steps-1 do
                local age=k*dt
                z.time=start+age
                c.physics.sludgePrune(sludge,z.time)
                for j=#pending,1,-1 do
                    local v=pending[j]
                    if v.at<=z.time+1e-6 then add(v.e,v.d) table.remove(pending,j) end
                end
                while event<=#w.events and w.events[event].at<=age do add(w.events[event].enemy,0) event+=1 end
                if z.time+1e-6>=nextBuy then
                    purchase(wi,age)
                    nextBuy=z.time+0.45
                end
                local active=0
                for _,e in ipairs(z.enemies) do
                    if not e.dead then
                        if e.type=="Plague Doctor" then
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
                    local st=t.st
                    if z.time+1e-6>=t.nextShot and z.time+1e-6>=t.active and z.time>=(t.stunUntil or 0) then
                        local p=t.profile
                        local best
                        for _,e in ipairs(z.enemies) do
                            if not e.dead and not e.air and (not e.stealth or st.stealthDetection) and p.hit[math.floor(e.dist+0.5)] and (not best or e.dist>best.dist) then best=e end
                        end
                        if best then
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
                        e.dist+=speed*dt
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
                if event>#w.events and n==0 and #pending==0 and age>=w.last then break end
                if k%480==0 then
                    if s.cancel and s.cancel() then return end
                    task.wait()
                end
            end
            z.time+=dt
            local delta=z.loss-lossBefore
            if wi<=5 then z.earlyLoss+=delta end
            local remainingHP=0
            for _,e in ipairs(z.enemies) do remainingHP+=e.hp+(e.shield or 0) end
            z.history[#z.history+1]={wave=wi,loss=delta,lives=z.lives,cash=z.cash,towers=#z.towers,time=z.time-start,remaining=#z.enemies,remainingHP=remainingHP,income=z.income,spent=z.spent,bonuses=z.bonuses,hpDamage=hpDamage,shieldDamage=shieldDamage,paidDamage=paidDamage,sludgeHits=sludgeHits}
            if z.lives>0 and unknown==0 then checkpoint(wi) end
            if notify then notify(wi,z) end
            if z.lives<=0 or unknown>0 then break end
        end
        local complete=#z.history==maxWave and #z.enemies==0 and #pending==0 and z.lives>0 and unknown==0
        local ledgerError=z.cash-(cfg.StartingCash+z.income+z.bonuses-z.spent)
        local bossHP=0
        for _,e in ipairs(z.enemies) do if e.type=="Plague Doctor" then bossHP+=e.hp end end
        return {blockedMove=blockedMove,ledgerError=ledgerError,income=z.income,spent=z.spent,bonuses=z.bonuses,remainingHP=z.history[#z.history] and z.history[#z.history].remainingHP or 0,from=1,to=#z.history,targetWave=maxWave,loss=z.loss,lives=z.lives,earlyLoss=z.earlyLoss,cash=z.cash,time=z.time,history=z.history,moves=z.moves,complete=complete,remaining=#z.enemies,unknown=unknown,policy=policy,stress=stress,replayed=cursor-1,reusedWaves=firstWave-1,lastLeak=z.lastLeak,bossHP=bossHP},checkpoints
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
            return v.to*10000+(eligible and 1000000 or 0)-math.max(0,v.loss)*5-v.earlyLoss*10-(v.remainingHP or 0)*0.15
        end
        local function retain(v,p,w,stressTest,checkpoints)
            local key={}
            for _,a in ipairs(v.moves) do key[#key+1]=string.format("%d:%.2f:%.2f:%.2f:%d:%d",a.wave,a.pos.x,a.pos.y,a.pos.z,a.path1,a.path2) end
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
            if s.progress then s.progress(i,n,v.to,v.lives,"result "..phase,{reason=reason,cash=v.cash,earlyLoss=v.earlyLoss,remaining=v.remaining,remainingHP=v.remainingHP,unknown=v.unknown,spent=v.spent,income=v.income,bonuses=v.bonuses,ledgerError=v.ledgerError,attempt=attempts,wave=v.to,reusedWaves=v.reusedWaves,bossHP=v.bossHP,lastLeak=v.lastLeak}) end
            if reason=="victory" then
                local ok=true
                local worst=v.lives
                local checks={}
                for k in pairs(routes) do
                    local test=k==idx and v or simulate(s,k,policy,false,v.moves,function(w,z) report(i,n,w,z,"route check "..phase) end)
                    if not test then return false end
                    checks[#checks+1]={route=k,complete=test.complete,lives=test.lives,earlyLoss=test.earlyLoss,remaining=test.remaining,replayed=test.replayed}
                    worst=math.min(worst,test.lives)
                    local why=not test.complete and (test.unknown>0 and "unknown_data" or test.lives<=0 and "defeat" or "enemies_remaining") or math.abs(test.ledgerError)>0.01 and "cash_mismatch" or "passed"
                    if s.progress then s.progress(i,n,test.to,test.lives,"route result "..phase,{reason=why,cash=test.cash,earlyLoss=test.earlyLoss,remaining=test.remaining,remainingHP=test.remainingHP,unknown=test.unknown,spent=test.spent,income=test.income,bonuses=test.bonuses,ledgerError=test.ledgerError,blockedMove=test.blockedMove,replayed=test.replayed}) end
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
                    if not best or v.time<best.time then best=v end
                end
            end
            retain(v,policy,problem,failedStress,checkpoints)
            return true
        end
        for i,p in ipairs(policies) do
            if not evaluate(p,i,#policies,"search") then return end
            if best then break end
        end
        while not best do
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
                local w=i%3==0 and weakestLate(source) or i%3==1 and math.max(1,source.to) or parent.w
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
                p.repairs[#p.repairs+1]=patch
                if #p.repairs>18 then table.remove(p.repairs,1) end
                tested+=1
                local phase=string.format("repair %d | weak wave %d | revise %d-%d",round,w,from,to)
                if not evaluate(p,i,count,phase,parent) then return end
                if best then break end
                task.wait()
            end
            assert(tested>0,"repair batch empty")
            task.wait(0.1)
        end
        local plan=assert(best,"search ended without a validated plan")
        plan.ready=true
        plan.model="adaptive_v9_checkpoint_coverage_boss"
        plan.computeTime=os.clock()-began
        plan.realTime=plan.time/1.5
        plan.attempts=attempts
        plan.repairRounds=round
        return nil,plan
    end
    return x
end
return m
