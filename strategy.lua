local m = {}

function m.new(c, routes, los, spots)
    local x = {}
    local profiles = {}
    local stats = {}
    local strengths = {}
    local base = c.ranger.stats(0,0)
    local maxWave = #c.economy.config.Waves
    for _, st in ipairs(c.ranger.all()) do stats[st.path1 * 10 + st.path2] = st end

    local function profile(pos, range)
        local key = string.format("%.2f:%.2f:%.2f:%.2f",pos.X,pos.Y,pos.Z,range)
        if profiles[key] then return profiles[key] end
        local out = {}
        for idx,r in pairs(routes) do
            local first, last, length = math.huge, 0, 0
            for d = 0,r.length,2 do
                local p = c.physics.at(r,d)
                if (p-pos).Magnitude <= range and los(pos,p) then
                    first = math.min(first,d)
                    last = math.min(r.length,d+2)
                    length += math.min(2,r.length-d)
                end
            end
            out[idx] = {first=first,last=last,length=length}
        end
        profiles[key] = out
        return out
    end

    local function dps(st,g)
        if g.air or g.stealth and not st.stealthDetection then return 0 end
        local reduction = st.ignoreResistance and 0 or (g.resist[tostring(st.damageType)] or 0)
        local d = st.dps * (1-math.clamp(reduction,0,1))
        if g.maxDamage and g.maxDamage >= 0 and st.damage > 0 then d *= math.min(1,g.maxDamage/st.damage) end
        d *= 1-math.clamp(g.allReduction or 0,0,1)
        if st.path2 >= 4 then
            local splash = st.path2 == 5 and 20 or 75/8
            d += splash * (1-math.clamp(g.resist.Explosive or 0,0,1)) * math.min(1.5, (g.count or 1)/math.max(1,(g.last or 0)-(g.first or 0)+1)) * 0.55
        end
        return d * 0.85
    end

    local function strength(st,pos,wi)
        local key=string.format("%.2f:%.2f:%.2f:%d:%d:%d",pos.X,pos.Y,pos.Z,st.path1,st.path2,wi)
        if strengths[key] then return strengths[key] end
        local sum, norm = 0,0
        for offset=0,maxWave-wi do
            local w=c.forecast.wave(wi+offset)
            if w then
                local weight=1/(1+offset*0.7)
                for _,g in ipairs(w.groups) do
                    local demand=(g.hp+g.shield+g.extra)*g.count
                    local value=0
                    local n=0
                    for _,p in pairs(profile(pos,st.range)) do
                        if p.length>0 then
                            local uptime=math.min(p.length/math.max(0.1,g.speed)*g.count,math.max(1,g.last-g.first+p.length/math.max(0.1,g.speed)))
                            value+=math.min(demand,dps(st,g)*uptime)/(1+p.first/math.max(1,g.speed)/8)
                        end
                        n+=1
                    end
                    sum+=weight*value/math.max(1,n)/math.max(1,w.hp+w.shield)
                end
                norm+=weight
            end
        end
        strengths[key]=sum/math.max(1,norm)
        return strengths[key]
    end

    local function calc(towers, wi)
        local w=c.forecast.wave(wi)
        if not w then return {loss=0,time=0,earned=0,remaining=0} end
        local worst, totalTime, income=0,0,math.huge
        for idx,r in pairs(routes) do
            local busy={}
            local loss, finish, earned=0,w.last,0
            for _,g in ipairs(w.groups) do
                local hp=g.hp*g.count
                local shield=g.shield*g.count
                local extra=g.extra*g.count
                local demand=hp+shield+extra
                if g.type=="Plague Doctor" then demand+=9750 end
                local order={}
                for i,t in ipairs(towers) do
                    local p=profile(t.pos,t.st.range)[idx]
                    local d=dps(t.st,g)
                    if p and p.length>0 and d>0 then
                        table.insert(order,{i=i,p=p,d=d})
                    end
                end
                table.sort(order,function(a,b) return a.p.first<b.p.first end)
                local left=demand
                for _,a in ipairs(order) do
                    if left<=0 then break end
                    local sp=math.max(0.1,g.speed)
                    local start=math.max(g.first+a.p.first/sp,busy[a.i] or 0)
                    local stop=g.last+a.p.last/sp
                    local available=math.min(math.max(0,stop-start),a.p.length/sp*g.count)
                    local dealt=math.min(left,available*a.d)
                    left-=dealt
                    if dealt>0 then
                        busy[a.i]=start+dealt/a.d
                        finish=math.max(finish,busy[a.i],g.last+a.p.first/sp)
                    end
                end
                if left>0 then
                    loss+=math.min(hp,left)
                    finish=math.max(finish,g.last+r.length/math.max(0.1,g.speed))
                end
                if not g.noCash then earned+=math.clamp(demand-left-shield,0,hp) end
            end
            worst=math.max(worst,loss)
            totalTime=math.max(totalTime,finish)
            income=math.min(income,earned)
        end
        return {loss=worst,time=totalTime,earned=c.economy.income(wi,income==math.huge and 0 or income),unknown=w.unknown}
    end

    local function copy(s)
        local z=table.clone(s)
        z.towers={}
        for i,t in ipairs(s.towers) do z.towers[i]=table.clone(t) end
        z.history=table.clone(s.history)
        z.moves=table.clone(s.moves)
        return z
    end

    local targets={{0,1},{1,0},{1,1},{2,1},{1,2},{2,2},{3,2},{2,3},{4,2},{2,4},{5,2},{2,5}}
    local function step(old,st,mode)
        if st.path1>old.path1 and st.path2>old.path2 then
            if mode==2 then return 1 end
            return 2
        end
        return st.path1>old.path1 and 1 or 2
    end

    local function options(z,wi,mode)
        local best
        local function check(t,idx,st,pos,spot)
            local old=t and t.st
            local price=st.cost-(old and old.cost or 0)
            if price<=0 then return end
            local gain=strength(st,pos,wi)-(old and strength(old,pos,wi) or 0)
            if gain<=0 then return end
            local path=old and step(old,st,mode)
            local nextSt=old and stats[(old.path1+(path==1 and 1 or 0))*10+old.path2+(path==2 and 1 or 0)] or base
            if not nextSt then return end
            local nextPrice=nextSt.cost-(old and old.cost or 0)
            local rank=gain/math.max(1,price)^0.85
            if old then rank*=mode==1 and 1.65 or 1.2 else rank*=mode==3 and 1.25 or 0.85 end
            if st.path1>=3 and (not old or old.path1<3) then
                for k=wi,math.min(maxWave,wi+2) do
                    local w=c.forecast.wave(k)
                    if w and w.stealthHp>0 then rank*=1.8 break end
                end
            end
            if st.path2>=3 and (not old or old.path2<3) then rank*=mode==2 and 1.05 or 1.25 end
            if price>z.cash then rank*=math.max(0.25,math.min(1,z.cash/price+0.35)) end
            if not best or rank>best.rank then best={idx=idx,st=st,pos=pos,spot=spot,price=price,nextPrice=nextPrice,path=path,rank=rank,gain=gain} end
        end
        for i,t in ipairs(z.towers) do
            for _,v in ipairs(targets) do
                local st=stats[v[1]*10+v[2]]
                if st and st.path1>=t.st.path1 and st.path2>=t.st.path2 and st.cost>t.st.cost then check(t,i,st,t.pos) end
            end
        end
        if #z.towers<z.cap then
            local n=0
            for j,item in ipairs(spots) do
                local free=true
                for _,t in ipairs(z.towers) do
                    if (t.pos-item.pos).Magnitude<3.1 then free=false break end
                end
                if free then
                    check(nil,nil,base,item.pos,j)
                    check(nil,nil,stats[11],item.pos,j)
                    check(nil,nil,stats[23],item.pos,j)
                    check(nil,nil,stats[32],item.pos,j)
                    n+=1
                    if n>=4 then break end
                end
            end
        end
        return best
    end

    local function build(z,wi,mode,initial)
        for i=1,5 do
            local a=options(z,wi,mode)
            if not a then break end
            local before=calc(z.towers,wi)
            if a.price>z.cash then
                local t=a.idx and z.towers[a.idx]
                local partial
                if t then
                    partial=stats[(t.st.path1+(a.path==1 and 1 or 0))*10+t.st.path2+(a.path==2 and 1 or 0)]
                elseif z.cash>=base.cost then
                    partial=base
                end
                if partial and a.nextPrice<=z.cash then
                    a.st=partial
                    a.price=a.nextPrice
                else
                if initial and not z.first then
                    local t=a.idx and z.towers[a.idx]
                    if t and t.id and a.nextPrice<=z.cash then
                        z.first={kind="upgrade",id=t.id,path=a.path,price=a.nextPrice,goal={id=t.id,path=a.path,path1=a.st.path1,path2=a.st.path2,price=a.price}}
                    else
                        z.first={kind="hold",reason="reserve_package",goal={id=t and t.id,path=a.path,path1=a.st.path1,path2=a.st.path2,price=a.price,nextPrice=a.nextPrice}}
                    end
                end
                break
                end
            end
            local old=a.idx and z.towers[a.idx]
            local oldSt=old and old.st
            if old then old.st=a.st else table.insert(z.towers,{st=a.st,pos=a.pos}) end
            local after=calc(z.towers,wi)
            local nextBefore,nextAfter
            if wi<maxWave then
                nextAfter=calc(z.towers,wi+1)
                if old then old.st=oldSt else table.remove(z.towers) end
                nextBefore=calc(z.towers,wi+1)
                if old then old.st=a.st else table.insert(z.towers,{st=a.st,pos=a.pos}) end
            end
            local useful=after.loss<before.loss-0.1 or after.time<before.time-0.15 or nextBefore and (nextAfter.loss<nextBefore.loss-0.1 or nextAfter.time<nextBefore.time-0.15)
            if not useful and #z.towers>1 then
                if old then old.st=oldSt else table.remove(z.towers) end
                break
            end
            z.cash-=a.price
            z.moves[#z.moves+1]={wave=wi,pos=c.physics.pack(a.pos),path1=a.st.path1,path2=a.st.path2,price=a.price}
            if initial and not z.first then
                local goal={path1=a.st.path1,path2=a.st.path2,price=a.price,nextPrice=a.nextPrice,id=old and old.id}
                z.first=old and {kind="upgrade",id=old.id,path=a.path,price=a.nextPrice,goal=goal} or {kind="place",pos=c.physics.pack(a.pos),price=base.cost,goal=goal}
            end
        end
    end

    function x.search(s)
        local wi=math.max(1,s.wave)
        local endWave=maxWave
        local initial={towers={},cash=s.cash,lives=s.lives,cap=s.towerLimit or 40,time=0,loss=0,history={},moves={}}
        for id,t in pairs(s.towers) do
            if t.owned and t.type=="Ranger" then
                local st=stats[t.path1*10+t.path2]
                if st then table.insert(initial.towers,{id=id,st=st,pos=c.physics.vec(t.pos)}) end
            end
        end
        local beam={initial}
        local began=os.clock()
        local reached=wi
        for n=wi,endWave do
            local nextBeam={}
            for _,parent in ipairs(beam) do
                for mode=0,3 do
                    if s.cancel and s.cancel() then return nil end
                    if mode==0 then task.wait() end
                    local z=copy(parent)
                    if n>wi or n==wi and s.wave==0 then z.cash+=c.economy.bonus(n) end
                    if mode>0 then build(z,n,mode,n==wi) end
                    if n==wi and not z.first then z.first={kind="hold",reason="reserve"} end
                    local r=calc(z.towers,n)
                    local scale=n==wi and s.wave>0 and s.waveAge and math.clamp(1-s.waveAge/math.max(1,r.time),0.15,1) or 1
                    z.cash+=r.earned*scale
                    if mode>0 and r.earned*scale>=250 and n==wi then
                        build(z,n,mode,false)
                    end
                    z.time+=r.time*scale
                    z.loss+=r.loss*scale
                    z.history[#z.history+1]={wave=n,loss=r.loss,time=r.time,cash=z.cash,towers=#z.towers,mode=mode}
                    z.score=z.time+z.loss*2+math.max(0,z.loss-z.lives*0.7)*50-z.cash*0.00015
                    table.insert(nextBeam,z)
                end
            end
            table.sort(nextBeam,function(a,b) return a.score<b.score end)
            beam={}
            for i=1,math.min(3,#nextBeam) do beam[i]=nextBeam[i] end
            reached=n
            task.wait()
            if s.cancel and s.cancel() then return nil end
        end
        local best=beam[1]
        for _,z in ipairs(beam) do
            if z.loss<z.lives and (best.loss>=best.lives or z.time<best.time) then best=z end
        end
        return best.first,{from=wi,to=reached,targetWave=endWave,time=best.time,loss=best.loss,cash=best.cash,history=best.history,moves=best.moves,score=best.score,model="aggregate",beam=3,realTime=best.time/math.max(0.01,s.speed or 1),computeTime=os.clock()-began}
    end

    function x.assess(s,wi)
        local towers={}
        for _,t in pairs(s.towers) do
            local st=stats[t.path1*10+t.path2]
            if t.owned and t.type=="Ranger" and st then table.insert(towers,{st=st,pos=c.physics.vec(t.pos)}) end
        end
        return calc(towers,wi)
    end

    return x
end

return m
