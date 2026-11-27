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
    local result = {hpDamage = 0, shieldDamage = 0, leaks = 0, kills = 0, remaining = 0}
    for _, e in pairs(snapshot.enemies) do
        local r = routes[e.pathIndex]
        if r then
            local c = table.clone(e)
            c.route = r
            c.dist = physics.project(r, physics.vec(e.pathPos))
            c.spawnAt = e.spawnAt or 0
            table.insert(enemies, c)
        end
    end
    for id, t in pairs(snapshot.towers) do
        if t.owned and t.type == "Ranger" and not t.attackDisabled and not (action and action.kind == "sell" and action.id == id) then
            local c = table.clone(t)
            c.pos = physics.vec(t.pos)
            if action and action.kind == "upgrade" and action.id == id then
                for k, v in pairs(action.stats) do c[k] = v end
            end
            c.wait = math.max(0, t.nextAttack or 0)
            c.left = math.clamp((c.burstSize or 1) - (t.burstIndex or 1) + 1, 1, c.burstSize or 1)
            table.insert(towers, c)
        end
    end
    if action and action.kind == "place" then
        local c = table.clone(action.stats)
        c.pos = action.pos
        c.wait = 0
        c.left = c.burstSize or 1
        table.insert(towers, c)
    end
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
                end
            end
        end
        for _, t in ipairs(towers) do
            if time > 0 then t.wait -= dt end
            if t.wait <= 0 then
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
                    local damage = adjusted(t, best)
                    local shield = math.min(best.shield or 0, damage)
                    best.shield = (best.shield or 0) - shield
                    result.shieldDamage += shield
                    local hp = math.min(best.hp, damage - shield)
                    best.hp -= hp
                    result.hpDamage += hp
                    if best.hp <= 0 then
                        best.done = true
                        result.kills += 1
                    end
                    t.left -= 1
                    if t.left == 0 then
                        t.left = t.burstSize or 1
                        t.wait += math.max(dt, t.reload)
                    else
                        t.wait += math.max(dt, t.burstInterval or dt)
                    end
                else
                    t.wait = 0
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
        if not e.done then result.remaining += e.hp end
    end
    return result
end

return m
