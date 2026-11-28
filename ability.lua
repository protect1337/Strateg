local m={}

local function at(e,seconds,physics)
    local p=physics.vec(e.pos or e.pathPos)
    if not e.predicted then return p end
    local a=physics.vec(e.predicted[1])
    local b=physics.vec(e.predicted[2])
    if seconds<=0.75 then return p:Lerp(a,math.clamp(seconds/0.75,0,1)) end
    return a:Lerp(b,math.clamp((seconds-0.75)/0.75,0,1))
end

local function eligible(e)
    return e and e.hp>0 and not e.air and not e.invulnerable and not e.noDamage and not e.untargetable and not e.stasis
end

function m.rank(s,physics,slice,limit,offset)
    local out,ids={},{}
    local metrics={seen=0,ready=0,manual=0,passive=0,disabled=0,noTarget=0,lowValue=0,names={}}
    for id,t in pairs(s.towers) do
        if t.owned and t.type=="Ranger" and next(t.abilities or {}) then ids[#ids+1]=id end
    end
    table.sort(ids)
    if #ids==0 then return out,0,metrics end
    local n=math.min(limit or #ids,#ids)
    local cursor=(offset or 0)%#ids
    for _=1,n do
        cursor=cursor%#ids+1
        local id=ids[cursor]
        local t=s.towers[id]
        if slice then slice() end
        for name,a in pairs(t.abilities) do
            local lower=string.lower(tostring(name))
            local grenade=string.find(lower,"grenade",1,true)~=nil
            local launcher=string.find(lower,"m203",1,true)~=nil
            metrics.names[tostring(name)]=true
            if not grenade and not launcher then continue end
            metrics.seen+=1
            if a.passive or a.custom then metrics.passive+=1 continue end
            if a.manual then metrics.manual+=1 continue end
            if a.disabled or t.stunned or t.attackDisabled then metrics.disabled+=1 continue end
            if (a.cooldown or math.huge)>0 then continue end
            metrics.ready+=1
            local range=type(a.aimRange)=="number" and a.aimRange or t.range
            local radius=type(a.radius)=="number" and a.radius>0 and a.radius or (string.find(lower,"2",1,true) and 4 or 3)
            local damage=type(a.damage)=="number" and a.damage>0 and a.damage or (string.find(lower,"2",1,true) and 100 or 75)
            local origin=physics.vec(t.pos)
            local function canTarget(e)
                return eligible(e) and (not e.stealth or t.stealthDetection) and (physics.vec(e.pos or e.pathPos)-origin).Magnitude<=range
            end
            local e=t.target and s.enemies[t.target]
            if not canTarget(e) then
                e=nil
                for _,v in pairs(s.enemies) do
                    if canTarget(v) and (not e or v.hp+(v.shield or 0)>e.hp+(e.shield or 0)) then e=v end
                end
            end
            if not e then metrics.noTarget+=1 continue end
            local target=physics.vec(e.pos or e.pathPos)
            local delay=0.15+math.max(0.15,(target-origin).Magnitude/15,2*math.sqrt(math.abs(target.Y-origin.Y)/120))
            local lead=at(e,delay,physics)
            local fixed,moving=0,0
            for _,other in pairs(s.enemies) do
                if slice then slice() end
                if eligible(other) then
                    local resist=math.clamp(((other.resist or {}).Explosive or 0)+(other.resistModifier or 0),0,1)
                    local d=math.min(other.hp+(other.shield or 0),damage*(1-resist))
                    local p=at(other,delay,physics)
                    if (p-target).Magnitude<=radius then fixed+=d end
                    if (p-lead).Magnitude<=radius then moving+=d end
                end
            end
            local value=math.min(fixed,moving)*0.65+math.max(fixed,moving)*0.35
            if value>0 then
                out[#out+1]={kind="ability",id=id,name=name,score=value,target=e.id,flight=delay,fixedValue=fixed,trackedValue=moving,reason="independent_grenade"}
            else
                metrics.lowValue+=1
            end
        end
    end
    table.sort(out,function(a,b) return a.score>b.score end)
    return out,cursor,metrics
end

return m
