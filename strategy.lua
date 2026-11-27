local m={}

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
    local dt=0.15
    local function settings(policy,wi)
        local a=policy
        for _,patch in ipairs(policy.repairs or {}) do
            if wi>=patch.from and wi<=patch.to then a=patch end
        end
        return a
    end
    local function simulate(s,idx,policy,stress,replay,notify)
        local r=routes[idx]
        local z={cash=cfg.StartingCash,lives=cfg.StartingLives,towers={},enemies={},moves={},history={},time=0,loss=0,earlyLoss=0}
        local cap=(s.towerLimit and s.towerLimit>0) and s.towerLimit or 40
        local cursor=1
        local serial=0
        local nextBuy=0
        local unknown=0
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
            a.healAt=z.time+12
            a.summonAt=z.time+7
            a.summons=0
            a.smoke=false
            a.maxHp=a.hp
            z.enemies[#z.enemies+1]=a
        end
        local function free(pos)
            for _,t in ipairs(z.towers) do if (t.pos-pos).Magnitude<spacing-0.01 then return false end end
            return true
        end
        local function site(wi)
            local best,score
            local opt=settings(policy,wi)
            for i,item in ipairs(spots) do
                local p=item.pos
                if free(p) then
                    local a=profile(p,base.range,idx)
                    local b=profile(p,16,idx)
                    if a.length>0 then
                        local near=math.huge
                        for _,t in ipairs(z.towers) do near=math.min(near,(p-t.pos).Magnitude) end
                        local density=near==math.huge and 1 or 1+0.55/(1+math.max(0,near-spacing)/spacing)
                        local depth=opt.depth or (opt.siteMode==2 and 40 or opt.siteMode==3 and 65 or 17)
                        local early=1/(1+a.first/(wi<8 and depth or 55))
                        local v=(a.length+b.length*(opt.longRange or 0.18))*early*density
                        if opt.seed then v*=1+0.12*math.sin(i*12.9898+opt.seed*78.233) end
                        if wi>=12 and opt.live then
                            local reach=0
                            for _,e in ipairs(z.enemies) do
                                if not e.dead then
                                    local start=math.floor(e.dist+0.5)
                                    for d=start,math.min(math.ceil(r.length),start+40),4 do
                                        if b.hit[d] then reach+=1 end
                                    end
                                end
                            end
                            v*=1+math.min(3,reach*0.07)
                        end
                        if not score or v>score then best,score=p,v end
                    end
                end
            end
            return best
        end
        local function install(pos,upper)
            if not pos or not free(pos) or z.cash<base.cost or #z.towers>=cap then return false end
            z.cash-=base.cost
            local t={pos=pos,st=base,upper=upper,wait=0,left=base.burstSize,grenade=0,active=z.time+0.45}
            z.towers[#z.towers+1]=t
            return t,base.cost
        end
        local function upgrade(t,st)
            local cost=st.cost-t.st.cost
            if cost<=0 or cost>z.cash then return false end
            if st.path1<t.st.path1 or st.path2<t.st.path2 then return false end
            z.cash-=cost
            t.st=st
            t.left=st.burstSize
            t.active=z.time+0.3
            return t,cost
        end
        local function purchase(wi,age)
            if z.cash<165 then return end
            if replay then
                local a=replay[cursor]
                if not a or a.wave>wi then return end
                local p=c.physics.vec(a.pos)
                local t
                for _,v in ipairs(z.towers) do if (v.pos-p).Magnitude<0.1 then t=v break end end
                local st=stats[a.path1*10+a.path2]
                if not st then return end
                local success
                if t then success=upgrade(t,st) elseif st.cost==base.cost then success=install(p,a.upper) end
                if success then cursor+=1 end
                return
            end
            local t,cost
            local opt=settings(policy,wi)
            local need=opt.core
            if wi<=2 and need>3 then need=3 end
            local stealth=false
            for _,v in ipairs(z.towers) do if v.st.stealthDetection then stealth=true break end end
            local pick
            if #z.towers<need then
                if #z.towers==0 or z.towers[1].st.path1+z.towers[1].st.path2>=2 then
                    if z.cash>=base.cost then
                        local upper=opt.upper
                        if #z.towers%2==1 then upper=not upper end
                        t,cost=install(site(wi),upper)
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
                            t,cost=install(site(wi),#z.towers%2==0)
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
                            t,cost=install(site(wi),#z.towers%2==0)
                        end
                    end
                elseif not t and not pick and z.cash>=base.cost and #z.towers<cap then
                    t,cost=install(site(wi),#z.towers%2==0)
                end
            end
            if t then
                z.moves[#z.moves+1]={wave=wi,age=age,pos=c.physics.pack(t.pos),path1=t.st.path1,path2=t.st.path2,price=cost,upper=t.upper}
            end
        end
        local function hit(e,damage,kind,ignore,wi)
            if e.dead or damage<=0 then return end
            local resist=ignore and 0 or math.clamp(e.resist[tostring(kind)] or 0,0,1)
            local v=damage*(1-resist)*(1-math.clamp(e.allReduction or 0,0,1))*(stress and 0.85 or 0.96)
            if e.maxDamage and e.maxDamage>=0 then v=math.min(v,e.maxDamage) end
            local sh=math.min(e.shield,v)
            e.shield-=sh
            local hp=math.min(e.hp,v-sh)
            e.hp-=hp
            if not e.noCash then
                local paid=math.min(e.cashLeft or 0,hp)
                e.cashLeft=math.max(0,(e.cashLeft or 0)-paid)
                z.cash+=c.economy.income(wi,paid)*(stress and 0.95 or 1)
            end
            if e.hp<=0.0001 then
                e.dead=true
                for _,kid in ipairs(e.kids or {}) do add(kid,e.dist) end
            end
        end
        for i=1,12 do purchase(0,0) end
        for wi=1,maxWave do
            if s.cancel and s.cancel() then return end
            local w=c.forecast.wave(wi)
            unknown+=w.unknown or 0
            if wi==1 then z.cash+=stress and 0 or 25 else z.cash+=c.economy.bonus(wi) end
            local start=z.time
            local event=1
            local lossBefore=z.loss
            local limit=cfg.Waves[wi].CustomWaveTime or 60
            if wi==maxWave then limit=math.max(180,w.last+r.length/0.8+30) end
            local steps=math.ceil(limit/dt)
            for k=0,steps do
                local age=k*dt
                z.time=start+age
                while event<=#w.events and w.events[event].at<=age do add(w.events[event].enemy,0) event+=1 end
                if z.time>=nextBuy then
                    purchase(wi,age)
                    nextBuy=z.time+0.45
                end
                local active=0
                for _,e in ipairs(z.enemies) do
                    if not e.dead then
                        if e.type=="Plague Doctor" then
                            if z.time>=e.healAt then e.hp=math.min(e.maxHp,e.hp+8750) e.healAt+=30 end
                            if not e.smoke and e.hp<=7500 then e.smoke=true e.hp=math.min(e.maxHp,e.hp+1000) end
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
                    t.wait=math.max(-dt,t.wait-dt)
                    if t.wait<=0 and z.time>=t.active then
                        local p=profile(t.pos,st.range,idx)
                        local best
                        for _,e in ipairs(z.enemies) do
                            if not e.dead and not e.air and (not e.stealth or st.stealthDetection) and p.hit[math.floor(e.dist+0.5)] and (not best or e.dist>best.dist) then best=e end
                        end
                        if best then
                            local debuff=best.type=="Plague Doctor" and (stress and 0.65 or 0.8) or 1
                            hit(best,st.damage*debuff,st.damageType,st.ignoreResistance,wi)
                            if st.path2>=4 and z.time>=t.grenade then
                                local rad=st.path2==5 and 4 or 3
                                for _,e in ipairs(z.enemies) do
                                    if not e.dead and not e.air and math.abs(e.dist-best.dist)<=rad and (not e.stealth or st.stealthDetection) then
                                        hit(e,(st.path2==5 and 100 or 75)*0.55,"Explosive",false,wi)
                                    end
                                end
                                t.grenade=z.time+(st.path2==5 and 5 or 8)
                            end
                            t.left-=1
                            if t.left<=0 then t.left=st.burstSize t.wait+=math.max(dt,st.reload) else t.wait+=math.max(dt,st.burstInterval or dt) end
                        else
                            t.wait=0
                            t.left=st.burstSize
                        end
                    end
                end
                local n=0
                for _,e in ipairs(z.enemies) do
                    if not e.dead then
                        e.dist+=e.speed*dt
                        if e.dist>=r.length then
                            e.dead=true
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
                if event>#w.events and n==0 and age>=w.last then break end
                if k%160==0 then
                    if s.cancel and s.cancel() then return end
                    task.wait()
                end
            end
            local delta=z.loss-lossBefore
            if wi<=5 then z.earlyLoss+=delta end
            z.history[#z.history+1]={wave=wi,loss=delta,lives=z.lives,cash=z.cash,towers=#z.towers,time=z.time-start,remaining=#z.enemies}
            if notify then notify(wi,z) end
            if z.lives<=0 or unknown>0 then break end
        end
        local complete=#z.history==maxWave and #z.enemies==0 and z.lives>0 and unknown==0
        return {from=1,to=#z.history,targetWave=maxWave,loss=z.loss,lives=z.lives,earlyLoss=z.earlyLoss,cash=z.cash,time=z.time,history=z.history,moves=z.moves,complete=complete,remaining=#z.enemies,unknown=unknown,policy=policy,stress=stress,replayed=cursor-1}
    end
    function x.search(s)
        local began=os.clock()
        local idx,short
        for k,r in pairs(routes) do if not short or r.length<short then idx,short=k,r.length end end
        if not idx then return end
        local best,failed
        local pool={}
        local attempts=0
        local round=0
        local function weak(v)
            for _,w in ipairs(v.history) do
                if w.wave<=5 and w.loss>1 then return w.wave end
            end
            for _,w in ipairs(v.history) do
                if w.loss>25 then return w.wave end
            end
            return math.max(1,v.to)
        end
        local function score(v)
            return v.to*10000-math.max(0,v.loss)*2-math.max(0,v.earlyLoss-5)*800-(v.complete and 0 or 1000)
        end
        local function retain(v,p,w)
            local item={v=v,p=p,w=w or weak(v),rank=score(v)}
            pool[#pool+1]=item
            table.sort(pool,function(a,b) return a.rank>b.rank end)
            while #pool>16 do table.remove(pool) end
        end
        local function report(i,n,w,z,phase)
            if s.progress then s.progress(i,n,w,z.lives,phase) end
        end
        local function evaluate(policy,i,n,phase)
            attempts+=1
            local v=simulate(s,idx,policy,false,nil,function(w,z) report(i,n,w,z,phase) end)
            if not v then return false end
            if not failed or score(v)>score(failed) then failed=v end
            local problem=weak(v)
            if v.complete and v.lives>=150 and v.earlyLoss<=5 then
                local ok=true
                local worst=v.lives
                local checks={}
                for k in pairs(routes) do
                    local test=simulate(s,k,policy,true,v.moves,function(w,z) report(i,n,w,z,"stress "..phase) end)
                    if not test then return false end
                    checks[#checks+1]={route=k,complete=test.complete,lives=test.lives,earlyLoss=test.earlyLoss,remaining=test.remaining,replayed=test.replayed}
                    worst=math.min(worst,test.lives)
                    if not test.complete or test.lives<100 or test.earlyLoss>5 then
                        ok=false
                        problem=weak(test)
                        break
                    end
                end
                if ok then
                    v.ready=true
                    v.stressLives=worst
                    v.checks=checks
                    if not best or v.time<best.time then best=v end
                end
            end
            retain(v,policy,problem)
            return true
        end
        for i,p in ipairs(policies) do
            if not evaluate(p,i,#policies,"search") then return end
        end
        while not best do
            if s.cancel and s.cancel() then return end
            round+=1
            if failed and failed.unknown>0 and failed.to<=1 then break end
            local parents=table.clone(pool)
            if #parents==0 then break end
            local count=12
            local tested=0
            for i=1,count do
                if s.cancel and s.cancel() then return end
                local parent=parents[1+((round+i-2)%math.min(#parents,6))]
                local w=i%3==0 and math.max(1,parent.v.to) or parent.w
                local back=(i-1)%4
                local from=math.max(0,w-back)
                local to=math.min(maxWave,w+1+(i%3))
                local p=table.clone(parent.p)
                p.repairs=table.clone(parent.p.repairs or {})
                local prev=settings(parent.p,from)
                local core=math.clamp((prev.core or 2)+((i%3)-1),1,w<=5 and 3 or math.min(12,math.max(3,w-3)))
                if w>=12 then core=math.max(core,math.min(12,4+round%9)) end
                local patch={from=from,to=to,core=core,upper=i%2==0 and not prev.upper or prev.upper,expand=3+i%3,depth=12+((round*17+i*13)%100),longRange=0.12+(i%5)*0.12,seed=round*count+i,flex=i%3~=0,extra=w>=9 and 2+i%8 or 0,expandCash=w>=9 and 500+(i%5)*1000 or 5500,live=w>=12}
                if i%2==0 then patch.upper=not prev.upper end
                p.repairs[#p.repairs+1]=patch
                if #p.repairs>18 then table.remove(p.repairs,1) end
                tested+=1
                local phase=string.format("repair %d | weak wave %d | revise %d-%d",round,w,from,to)
                if not evaluate(p,i,count,phase) then return end
                task.wait()
            end
            if tested==0 then break end
            task.wait(0.1)
        end
        local plan=best or failed
        if not plan then return end
        plan.ready=best~=nil
        plan.model="adaptive_timed_shots_and_cash"
        plan.computeTime=os.clock()-began
        plan.realTime=plan.time/1.5
        plan.attempts=attempts
        plan.repairRounds=round
        return nil,plan
    end
    return x
end
return m
