local m={}

local function eligible(e)
    return e and e.hp>0 and not e.air and not e.invulnerable and not e.noDamage and not e.untargetable and not e.stasis
end

local function damageOf(t,e,raw,kind,ignore)
    local resist=ignore and 0 or ((e.resist or {})[tostring(kind)] or 0)
    if resist~=0 then resist=math.clamp(resist+(e.resistModifier or 0),0,1) end
    local d=raw*(1-resist)*(1-math.clamp(e.allReduction or 0,0,1))
    if e.maxDamage and e.maxDamage>=0 then d=math.min(d,e.maxDamage) end
    return math.max(0,d)
end

-- Discrete shots from current target assignments, not just nominal DPS.
local function ordinary(t,e,h)
    local d=damageOf(t,e,t.damage or 0,t.damageType,t.ignoreResistance)
    local size=math.max(1,t.burstSize or 1)
    local left=math.clamp(size-(t.burstIndex or 1)+1,1,size)
    if (t.burstReset or 0)<=0 then left=size end
    local at=math.max(0,t.nextAttack or 0)
    local interval=math.max(0.05,t.burstInterval or 0.05)
    if left<size then at=math.max(0,(t.burstReset or 0)-interval) end
    local n=0
    while at<=h and n<96 do
        n+=1 left-=1
        if left==0 then left=size at+=math.max(0.05,t.reload or 1)
        else at+=interval end
    end
    return n*d
end

function m.rank(s,physics,los,routes,limit,offset,reserved,focus)
    local out,ids={},{}
    local metrics={seen=0,ready=0,manual=0,passive=0,disabled=0,noTarget=0,lowValue=0,names={},budget=false,noCurrent=0,outOfRange=0,blockedLOS=0,stealthTarget=0}
    local began=os.clock()
    local enemies,assignments={},{}
    for id,e in pairs(s.enemies) do
        if eligible(e) then
            local r=routes[e.pathIndex]
            local pos=physics.vec(e.pos or e.pathPos)
            local path=physics.vec(e.pathPos or e.pos)
            local dist=r and physics.project(r,path)
            enemies[id]={e=e,p=pos,r=r,d=dist,progress=dist and dist/r.length or e.pathProgress or 0,offset=pos-path}
        end
    end
    for id,t in pairs(s.towers) do
        if t.owned and t.type=="Ranger" then
            if next(t.abilities or {}) then ids[#ids+1]=id end
            if not t.stunned and not t.attackDisabled and t.target and enemies[t.target] then
                local list=assignments[t.target] or {}
                list[#list+1]=t
                assignments[t.target]=list
            end
        end
    end
    table.sort(ids)
    if #ids==0 then return out,0,metrics end
    local function position(v,h)
        local e=v.e
        if e.stunned or e.stopped then return v.p end
        if h<=1.5 and e.predicted then
            local a,b=physics.vec(e.predicted[1]),physics.vec(e.predicted[2])
            if h<=0.75 then return v.p:Lerp(a,math.clamp(h/0.75,0,1)) end
            return a:Lerp(b,math.clamp((h-0.75)/0.75,0,1))
        end
        if not v.r then return nil end
        local d=v.d+(e.speed or 0)*h*(e.reverse and -1 or 1)
        if d>=v.r.length then return nil end
        return physics.at(v.r,d)+v.offset
    end
    local function remaining(v,h)
        local e=v.e
        local p=position(v,h)
        if not p then return 0 end
        local hp=e.hp+(e.shield or 0)
        for _,t in ipairs(assignments[e.id] or {}) do
            local origin=physics.vec(t.pos)
            if (p-origin).Magnitude<=t.range and los(origin,v.p) then hp-=ordinary(t,e,h) end
        end
        for _,r in ipairs(reserved or {}) do
            if r.untilTime>s.time and r.impact<=s.time+h/math.max(1,s.speed or 1) then hp-=r.hits[e.id] or 0 end
        end
        return math.max(0,hp)
    end
    local n=math.min(limit or 4,#ids)
    local cursor=(offset or 0)%#ids
    local visited={}
    for step=1,n do
        if step>1 and os.clock()-began>0.0015 then metrics.budget=true break end
        local id
        if step==1 and focus and s.towers[focus] then id=focus
        else
            cursor=cursor%#ids+1
            id=ids[cursor]
        end
        if visited[id] then continue end
        visited[id]=true
        local t=s.towers[id]
        local origin=physics.vec(t.pos)
        local current=t.target and enemies[t.target]
        for name,a in pairs(t.abilities or {}) do
            metrics.names[tostring(name)]=true
            local lv= name=="GrenadeLevel1" and 1 or name=="GrenadeLevel2" and 2 or nil
            if not lv then continue end
            metrics.seen+=1
            if a.passive or a.custom then metrics.passive+=1 continue end
            if a.manual then metrics.manual+=1 continue end
            if a.disabled or t.stunned or t.attackDisabled then metrics.disabled+=1 continue end
            if (a.cooldown or math.huge)>0 then continue end
            metrics.ready+=1
            local radius=lv==1 and 3 or 4
            local damage=lv==1 and 75 or 100
            if type(a.radius)=="number" and a.radius>0 then radius=a.radius end
            if type(a.damage)=="number" and a.damage>0 then damage=a.damage end
            local function canTarget(v)
                return v and (not v.e.stealth or t.stealthDetection) and (v.p-origin).Magnitude<=t.range and los(origin,v.p)
            end
            local currentValid=canTarget(current)
            if not currentValid then
                metrics.noTarget+=1
                if not current then metrics.noCurrent+=1
                elseif current.e.stealth and not t.stealthDetection then metrics.stealthTarget+=1
                elseif (current.p-origin).Magnitude>t.range then metrics.outOfRange+=1
                else metrics.blockedLOS+=1 end
            end
            local choices,scores={},{}
            for _,v in pairs(enemies) do
                if canTarget(v) then
                    local hp=v.e.hp+(v.e.shield or 0)
                    local order={v.progress,-v.progress,hp,-hp}
                    for i,k in ipairs(order) do
                        if not scores[i] or k>scores[i] then scores[i]=k choices[i]=v end
                    end
                end
            end
            local function evaluate(v,wait)
                local initial=position(v,wait)
                if not initial or (initial-origin).Magnitude>t.range or not los(origin,initial) then return nil end
                local flight=0.15+math.max(0.15,(initial-origin).Magnitude/15,2*math.sqrt(math.abs(initial.Y-origin.Y)/120))
                local h=wait+flight
                local lead=position(v,h)
                if not lead then return nil end
                local fixed,tracked,robust,hits,count,finishGain=0,0,0,{},0,0
                for eid,q in pairs(enemies) do
                    local p=position(q,h)
                    if p then
                        local fixedHit=(p-initial).Magnitude<=radius*0.9
                        local trackedHit=(p-lead).Magnitude<=radius*0.9
                        if fixedHit or trackedHit then
                            local hp=remaining(q,h)
                            local d=math.min(hp,damageOf(t,q.e,damage,"Explosive",false))
                            if fixedHit then fixed+=d end
                            if trackedHit then tracked+=d end
                            if fixedHit and trackedHit and d>0 then
                                robust+=d count+=1 hits[eid]=d
                                local power=0
                                for _,gun in ipairs(assignments[eid] or {}) do
                                    power+=damageOf(gun,q.e,gun.damage or 0,gun.damageType,gun.ignoreResistance)*(gun.burstSize or 1)/math.max(0.1,(gun.reload or 1)+math.max(0,(gun.burstSize or 1)-1)*(gun.burstInterval or 0))
                                end
                                finishGain+=math.min(4,d/math.max(1,power))
                            end
                        end
                    end
                end
                -- Only count damage surviving both impact models and normal shots.
                if robust<=0 then return nil end
                return {kind="ability",id=id,name=name,target=v.e.id,score=robust+4*finishGain,flight=flight,fixedValue=fixed,trackedValue=tracked,incrementalDamage=robust,hitCount=count,finishGain=finishGain,hits=hits,reason="marginal_grenade"}
            end
            local best=currentValid and evaluate(current,0) or nil
            local checked={}
            if currentValid then checked[current.e.id]=true end
            if not focus then
                for i,v in pairs(choices) do
                    if not checked[v.e.id] and i-1~=t.query then
                        checked[v.e.id]=true
                        local q=evaluate(v,0.35*math.max(1,s.speed or 1))
                        if q then
                            local cost=currentValid and ordinary(t,current.e,0.35*math.max(1,s.speed or 1)) or 0
                            q.score=math.max(0,q.score-cost)
                            if q.score>math.max(8,best and best.score*1.25 or 0) then
                                q.kind="target" q.query=i-1 q.priorQuery=t.query q.reason="grenade_retarget" q.abilityName=name
                                best=q
                            end
                        end
                    end
                end
            end
            if best then
                local later=currentValid and evaluate(current,0.75) or nil
                -- Waiting for a group is worthwhile only when it clearly beats firing now.
                if later and best.kind=="ability" and later.score>best.score*1.35+10 then metrics.lowValue+=1
                else out[#out+1]=best end
            else metrics.lowValue+=1 end
        end
    end
    table.sort(out,function(a,b) return a.score>b.score end)
    return out,cursor,metrics
end

return m
