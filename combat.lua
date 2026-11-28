local m = {}
local ability,abilityCatalog
function m.configure(model,resources)
    ability=model
    abilityCatalog=model.catalog(resources)
end
local function grenade(t,live)
    if not ability then return nil end
    local name=t.abilities and (t.abilities.GrenadeLevel2 and "GrenadeLevel2" or t.abilities.GrenadeLevel1 and "GrenadeLevel1")
    if name and live then return ability.spec(name,t.abilities[name],t.range),t.abilities[name].cooldown end
    if live or (t.path2 or 0)<4 then return nil end
    name=t.path2==5 and "GrenadeLevel2" or "GrenadeLevel1"
    return ability.spec(name,abilityCatalog[name],t.range),0
end

local function adjusted(t, e)
    local resist = not t.ignoreResistance and ((e.resist or {})[tostring(t.damageType)] or 0) or 0
    if resist ~= 0 then resist = math.clamp(resist + (e.resistModifier or 0), 0, 1) end
    local damage = t.damage * (1 - resist) * (1 - math.clamp(e.allReduction or 0, 0, 1))
    if e.maxDamage and e.maxDamage >= 0 then damage = math.min(damage, e.maxDamage) end
    return math.max(0, damage)
end

function m.run(snapshot, routes, physics, los, action, horizon)
    local slice=snapshot.runtimeSlice
    local function pause() if slice then slice() end end
    local enemies = {}
    local towers = {}
    local sludge = {}
    local fires={}
    local result = {hpDamage = 0, cashDamage = 0, shieldDamage = 0, leaks = 0, kills = 0, remaining = 0, remainingShield = 0, leaked = {}, children = 0, killTime = 0, finish = horizon, firstDamage = nil, unknown = 0}
    for _, e in pairs(snapshot.enemies) do
        local r = routes[e.pathIndex]
        if r then
            local c = table.clone(e)
            c.route = r
            c.dist = physics.project(r, physics.vec(e.pathPos))
            c.spawnAt = e.spawnAt or 0
            local burn=e.burn and e.burn.Burn or 0
            c.burnUntil=math.max(0,burn)
            c.burnTick=0
            if e.type=="Plague Doctor" or e.boss and e.name=="Plague Doctor" then
                c.plague=true
                c.healAt=c.spawnAt+(e.bossHealIn or 12)
                c.maxHp=e.maxHp or 45000
            end
            table.insert(enemies, c)
        else
            result.unknown += e.hp + (e.shield or 0)
        end
    end
    for id, t in pairs(snapshot.towers) do
        if t.owned and t.type == "Ranger" and not t.attackDisabled and not (action and action.kind == "sell" and action.id == id) then
            local c = table.clone(t)
            c.pos = physics.vec(t.pos)
            if action and action.kind == "upgrade" and action.id == id then
                if action.at and action.at > 0 then
                    c.pendingStats = action.stats
                    c.activeAt = action.at
                else
                    for k, v in pairs(action.stats) do c[k] = v end
                end
            end
            c.grenade,c.grenadeAt=grenade(t,true)
            c.nextShot = math.max(0, t.nextAttack or 0)
            c.fireAt=t.abilities and t.abilities.M203 and t.abilities.M203.cooldown or 0
            c.stunUntil=0
            if t.stunned then
                for _,b in pairs(t.debuffs or {}) do
                    if b.type=="Stun" or b.type=="Freeze" then c.stunUntil=math.max(c.stunUntil,b.remaining or b.duration or 0) end
                end
                if c.stunUntil==0 then c.stunUntil=1 end
            end
            c.left = math.clamp((c.burstSize or 1) - (t.burstIndex or 1) + 1, 1, c.burstSize or 1)
            if (t.burstReset or 0) <= 0 then c.left = c.burstSize or 1 end
            if c.left<(c.burstSize or 1) then
                local interval=math.max(0.05,c.burstInterval or 0.05)
                c.lastShot=(t.burstReset or 0)-2*interval
                c.nextShot=math.max(0,c.lastShot+interval)
            end
            c.nextShot+=c.stunUntil
            table.insert(towers, c)
        end
    end
    if action and action.kind == "place" then
        local c = table.clone(action.stats)
        c.pos = action.pos
        c.activeAt = action.at or 0
        c.nextShot = c.activeAt
        c.left = c.burstSize or 1
        c.grenade,c.grenadeAt=grenade(c,false)
        table.insert(towers, c)
    end
    local function hit(e, damage, time)
        if e.done or damage <= 0 then return end
        if not result.firstDamage then result.firstDamage = time end
        local shield = math.min(e.shield or 0, damage)
        e.shield = (e.shield or 0) - shield
        result.shieldDamage += shield
        local hp = math.min(e.hp, damage - shield)
        e.hp -= hp
        result.hpDamage += hp
        if not e.noCash then result.cashDamage += hp end
        if e.hp <= 0 then
            e.done = true
            result.kills += 1
            physics.sludgeAdd(sludge,e,e.route,time)
            result.killTime += time - e.spawnAt
            for _, kid in ipairs(e.kids or {}) do
                local child = table.clone(kid)
                child.id = e.id .. "_child_" .. tostring(result.children + 1)
                child.route = e.route
                child.dist = e.dist
                child.pos = e.pos
                child.spawnAt = time + (kid.delay or 0)
                child.stealth = e.stealth
                table.insert(enemies, child)
                result.children += 1
            end
        end
    end

    local dt = 0.05
    local steps = math.floor(horizon / dt + 0.5)
    for i = 0, steps do
        local time = i * dt
        if slice then pause() elseif i>0 and i%200==0 then task.wait() end
        physics.sludgePrune(sludge,time)
        for _, e in ipairs(enemies) do
            if not e.done and time >= e.spawnAt then
                e.pos = physics.at(e.route, e.dist)
                if e.plague then
                    if time>=e.healAt then
                        e.hp=math.min(e.maxHp,e.hp+8750)
                        e.healAt+=30
                    end
                    if not e.smokeHealed and e.hp<=7500 then
                        e.smokeHealed=true
                        e.hp=math.min(e.maxHp,e.hp+1000)
                    end
                end
                if e.dist >= e.route.length and not e.reverse then
                    e.done = true
                    result.leaks += e.hp
                    result.leaked[e.id] = {hp=e.hp,at=time,type=e.type}
                end
            end
        end
        for j=#fires,1,-1 do
            local f=fires[j]
            if f.grenade then
                if time>=f.at then
                    for _,e in ipairs(enemies) do
                        if not e.done and time>=e.spawnAt and e.pos and not e.air and not e.invulnerable and not e.noDamage and not e.stasis and (e.pos-f.pos).Magnitude<=f.radius and (e.pos-f.lead).Magnitude<=f.radius then
                            hit(e,adjusted({damage=f.damage,damageType=f.kind},e),time)
                        end
                    end
                    table.remove(fires,j)
                end
            elseif time>=f.finish then table.remove(fires,j)
            elseif time>=f.at then
                for _,e in ipairs(enemies) do
                    if not e.done and time>=e.spawnAt and e.pos and not e.air and (e.pos-f.pos).Magnitude<=4.5 then
                        e.burnUntil=time+5
                        e.burnTick=e.burnTick or time
                    end
                end
            end
        end
        for _,e in ipairs(enemies) do
            if not e.done and time>=e.spawnAt and (e.burnUntil or 0)>time and time+1e-6>=(e.burnTick or 0) then
                e.burnTick=time+0.25
                hit(e,adjusted({damage=2,damageType="Fire"},e),time)
            end
        end
        local active = false
        for _, e in ipairs(enemies) do if not e.done then active = true break end end
        if not active then result.finish = time break end
        for _, t in ipairs(towers) do
            pause()
            if t.pendingStats and time >= t.activeAt then
                for k,v in pairs(t.pendingStats) do t[k]=v end
                t.pendingStats=nil
                local prior=t.grenade
                local g=grenade(t,false)
                if g and (not prior or prior.name~=g.name) then t.grenadeAt=time+0.3 end
                t.grenade=g
                t.left=t.burstSize or 1
                t.nextShot=math.max(time,math.min(t.nextShot,time+t.reload))
                t.lastShot=nil
            end
            local g=t.grenade
            if g and not g.manual and not g.passive and not g.custom and time>=(t.stunUntil or 0) and (not t.activeAt or time>=t.activeAt or t.pendingStats) and time+1e-6>=(t.grenadeAt or 0) then
                t.grenadeAt=time+0.25
                local target,rank
                local function eligible(e)
                    return not e.done and time>=e.spawnAt and e.pos and not e.air and not e.invulnerable and not e.noDamage and not e.untargetable and not e.stasis
                end
                for _,e in ipairs(enemies) do
                    if eligible(e) and (not e.stealth or t.stealthDetection) and (e.pos-t.pos).Magnitude<=g.range and (g.independent or los(t.pos,e.pos)) then
                        local p=e.dist/e.route.length
                        if t.query==1 then p=-p elseif t.query==2 then p=e.hp+(e.shield or 0) elseif t.query==3 then p=-e.hp-(e.shield or 0) end
                        if not rank or p>rank then rank=p target=e end
                    end
                end
                if target then
                    local flight=ability.flight(t.pos,target.pos)
                    local function predicted(e)
                        local speed=(e.stopped or e.stunned or e.stasis) and 0 or e.speed or 0
                        if (e.sludgeUntil or 0)>time then speed*=1.8 end
                        local d=e.dist+speed*flight*(e.reverse and -1 or 1)
                        if d>=e.route.length then return nil end
                        return physics.at(e.route,d)
                    end
                    local lead=predicted(target)
                    local radius=g.radius*0.9
                    local damage=g.damage*(g.estimated and 0.65 or 1)
                    if lead then
                        local useful=0
                        for _,e in ipairs(enemies) do
                            if eligible(e) then
                                local p=predicted(e)
                                if p and (p-target.pos).Magnitude<=radius and (p-lead).Magnitude<=radius then useful+=math.min(e.hp+(e.shield or 0),adjusted({damage=damage,damageType=g.kind},e)) end
                            end
                        end
                        if useful>0 then
                            fires[#fires+1]={grenade=true,pos=target.pos,lead=lead,at=time+flight,radius=radius,damage=damage,kind=g.kind}
                            t.grenadeAt=time+g.cooldown
                            result.grenadeCasts=(result.grenadeCasts or 0)+1
                        end
                    end
                end
            end
            if time+1e-6>=t.nextShot and time>=(t.stunUntil or 0) and (t.pendingStats or not t.activeAt or time >= t.activeAt) then
                local best
                local progress = -math.huge
                for ei,e in ipairs(enemies) do
                    if slice and ei%64==0 then pause() end
                    if not e.done and time >= e.spawnAt and not e.air and not e.untargetable and not e.invulnerable and not e.noDamage and not e.stasis and (not e.stealth or t.stealthDetection) and (e.pos - t.pos).Magnitude <= t.range then
                        local p = e.dist / e.route.length
                        if t.query==1 then p=-p elseif t.query==2 then p=e.hp+(e.shield or 0) elseif t.query==3 then p=-(e.hp+(e.shield or 0)) end
                        if p > progress and los(t.pos, e.pos) then
                            best = e
                            progress = p
                        end
                    end
                end
                if best then
                    local damage = adjusted(t, best)
                    if damage > 0 and not result.firstDamage then result.firstDamage = time end
                    if t.path2==5 and time+1e-6>=(t.fireAt or 0) then
                        local travel=math.max(0.4,(best.pos-t.pos).Magnitude/45)
                        local at=time+travel
                        fires[#fires+1]={pos=physics.at(best.route,best.dist+(best.speed or 0)*travel*(best.reverse and -1 or 1)),at=at,finish=at+5}
                        t.fireAt=time+10
                    end
                    hit(best, damage, time)
                    t.lastShot=time
                    t.left -= 1
                    if t.left == 0 then
                        t.left = t.burstSize or 1
                        t.nextShot=time+math.max(dt,t.reload)
                    else
                        t.nextShot=time+math.max(dt,t.burstInterval or dt)
                    end
                elseif t.left<(t.burstSize or 1) and t.lastShot and time+1e-6>=t.lastShot+2*math.max(dt,t.burstInterval or dt) then
                    t.left=t.burstSize or 1
                    t.nextShot=time+math.max(dt,t.reload)
                end
            end
        end
        for _, e in ipairs(enemies) do
            if not e.done and time >= e.spawnAt and not e.stopped and not e.stunned and not e.stasis then
                local speed,buffed=physics.sludgeSpeed(sludge,e,e.route,time,dt)
                if buffed then result.sludgeHits=(result.sludgeHits or 0)+1 end
                e.dist = math.clamp(e.dist + speed * dt * (e.reverse and -1 or 1), 0, e.route.length)
            end
        end
    end
    for _, e in ipairs(enemies) do
        if not e.done then
            result.remaining += e.hp
            result.remainingShield += e.shield or 0
        end
    end
    return result
end

return m
