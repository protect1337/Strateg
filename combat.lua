local m = {}

local function adjusted(t, e)
    local resist = not t.ignoreResistance and (e.resist[tostring(t.damageType)] or 0) or 0
    if resist ~= 0 then resist = math.clamp(resist + (e.resistModifier or 0), 0, 1) end
    local damage = t.damage * (1 - resist) * (1 - math.clamp(e.allReduction or 0, 0, 1))
    if e.maxDamage and e.maxDamage >= 0 then damage = math.min(damage, e.maxDamage) end
    return math.max(0, damage)
end

function m.run(snapshot, routes, physics, los, action, horizon)
    local enemies = {}
    local towers = {}
    local result = {hpDamage = 0, cashDamage = 0, shieldDamage = 0, leaks = 0, kills = 0, remaining = 0, remainingShield = 0, leaked = {}, children = 0, killTime = 0, finish = horizon, firstDamage = nil, unknown = 0}
    for _, e in pairs(snapshot.enemies) do
        local r = routes[e.pathIndex]
        if r then
            local c = table.clone(e)
            c.route = r
            c.dist = physics.project(r, physics.vec(e.pathPos))
            c.spawnAt = e.spawnAt or 0
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
            c.wait = math.max(0, t.nextAttack or 0)
            c.left = math.clamp((c.burstSize or 1) - (t.burstIndex or 1) + 1, 1, c.burstSize or 1)
            if (t.burstReset or 0) <= 0 then c.left = c.burstSize or 1 end
            c.idle = 0
            c.grenadeAt = 0
            local ab = t.abilities and (t.abilities.GrenadeLevel2 or t.abilities.GrenadeLevel1)
            if ab then c.grenadeAt = ab.cooldown or 0 end
            table.insert(towers, c)
        end
    end
    if action and action.kind == "place" then
        local c = table.clone(action.stats)
        c.pos = action.pos
        c.activeAt = action.at or 0
        c.wait = 0
        c.left = c.burstSize or 1
        c.idle = 0
        c.grenadeAt = 0
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

    local shots = {}
    local dt = 0.1
    local steps = math.floor(horizon / dt + 0.5)
    for i = 0, steps do
        local time = i * dt
        if i > 0 and i % 100 == 0 then task.wait() end
        for _, e in ipairs(enemies) do
            if not e.done and time >= e.spawnAt then
                e.pos = physics.at(e.route, e.dist)
                if e.dist >= e.route.length and not e.reverse then
                    e.done = true
                    result.leaks += e.hp
                    result.leaked[e.id] = {hp=e.hp,at=time,type=e.type}
                end
            end
        end
        for j = #shots, 1, -1 do
            local shot = shots[j]
            if time >= shot.at then
                table.remove(shots,j)
                for _,e in ipairs(enemies) do
                    if not e.done and time >= e.spawnAt and not e.air and not e.invulnerable and not e.noDamage and not e.untargetable and not e.stasis and (not e.stealth or shot.stealth) and (e.pos-shot.pos).Magnitude <= shot.radius then
                        local damage = adjusted({damage=shot.damage,damageType="Explosive",ignoreResistance=false},e)
                        hit(e,damage,time)
                    end
                end
            end
        end
        local active = false
        for _, e in ipairs(enemies) do if not e.done then active = true break end end
        if not active then result.finish = time break end
        for _, t in ipairs(towers) do
            if t.pendingStats and time >= t.activeAt then
                for k,v in pairs(t.pendingStats) do t[k]=v end
                t.pendingStats=nil
                t.left=t.burstSize or 1
                t.wait=math.min(t.wait,0)
            end
            if time > 0 then t.wait -= dt end
            if t.wait <= 0 and (t.pendingStats or not t.activeAt or time >= t.activeAt) then
                local best
                local progress = -math.huge
                for _, e in ipairs(enemies) do
                    if not e.done and time >= e.spawnAt and not e.air and not e.untargetable and not e.invulnerable and not e.noDamage and not e.stasis and (not e.stealth or t.stealthDetection) and (e.pos - t.pos).Magnitude <= t.range then
                        local p = e.dist / e.route.length
                        if p > progress and los(t.pos, e.pos) then
                            best = e
                            progress = p
                        end
                    end
                end
                if best then
                    t.idle = 0
                    local damage = adjusted(t, best)
                    if damage > 0 and not result.firstDamage then result.firstDamage = time end
                    if t.path2 and t.path2 >= 4 and time >= (t.grenadeAt or 0) then
                        local flight=0.15+math.max(0.15,(best.pos-t.pos).Magnitude/15)
                        local radius=t.path2==5 and 4 or 3
                        local future=physics.at(best.route,best.dist+(best.speed or 0)*flight*(best.reverse and -1 or 1))
                        local center=best.pos:Lerp(future,0.5)
                        if (future-center).Magnitude<=radius then
                            table.insert(shots,{at=time+flight,pos=center,radius=radius,damage=(t.path2==5 and 100 or 75)*0.7,stealth=t.stealthDetection})
                            t.grenadeAt=time+(t.path2==5 and 5 or 8)
                        end
                    end
                    hit(best, damage, time)
                    t.left -= 1
                    if t.left == 0 then
                        t.left = t.burstSize or 1
                        t.wait += math.max(dt, t.reload)
                    else
                        t.wait += math.max(dt, t.burstInterval or dt)
                    end
                else
                    t.wait = 0
                    t.idle += dt
                    if t.idle >= 2 * math.max(dt, t.burstInterval or dt) then t.left = t.burstSize or 1 end
                end
            end
        end
        for _, e in ipairs(enemies) do
            if not e.done and time >= e.spawnAt and not e.stopped and not e.stunned and not e.stasis then
                e.dist = math.clamp(e.dist + (e.speed or 0) * dt * (e.reverse and -1 or 1), 0, e.route.length)
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
