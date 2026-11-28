local m = {}

function m.new(c)
    local f = {}
    local cfgs = {}
    local children={}
    local waves = {}
    local all = c.economy.config.Waves

    local function config(name)
        if cfgs[name] == nil then
            local ok, cfg = pcall(c.resources.GetEnemyConfig, name)
            cfgs[name] = ok and cfg or false
        end
        return cfgs[name] or nil
    end

    local function entry(seq)
        local cfg = config(seq.EnemyType)
        if not cfg or type(cfg.Health) ~= "number" or type(cfg.Speed) ~= "number" then return end
        local resist = {}
        for _, item in pairs(cfg.DamageReductionTable or {}) do resist[tostring(item.DamageType)] = item.DamageReduction end
        local hp = cfg.Health * (1 + (seq.AdditionalHealthMultiplier or 0))
        local shield = (cfg.Shield or 0) + cfg.Health * (seq.AdditionalShieldMultiplier or 0)
        local kids = {}
        local extra = 0
        for _, d in ipairs(cfg.DeathSpawnData or {}) do
            if d.EnemyType then
                local child = config(d.EnemyType)
                if child then
                    for i = 1, d.Count or 1 do
                        local cr = {}
                        for _, item in pairs(child.DamageReductionTable or {}) do cr[tostring(item.DamageType)] = item.DamageReduction end
                        table.insert(kids, {type = d.EnemyType, hp = child.Health, shield = child.Shield or 0, speed = child.Speed, radius = child.Radius, stealth = child.Stealth, air = child.AirUnit, resist = cr, noCash = child.NoCash, delay = d.Delay or 0})
                        extra += child.Health + (child.Shield or 0)
                    end
                end
            end
        end
        return {type = seq.EnemyType, hp = hp, shield = shield, speed = cfg.Speed, radius = cfg.Radius, stealth = seq.Stealth or cfg.Stealth, air = cfg.AirUnit, resist = resist, maxDamage = cfg.MaximumDamage, allReduction = cfg.AllDamageReduction, noCash = cfg.NoCash, kids = kids, extra = extra, boss = cfg.IsBoss, complex = cfg.AbilityNames ~= nil or cfg.DeathAbilityNames ~= nil or cfg.SecondLifeData ~= nil}
    end

    for wi, w in ipairs(all) do
        local data = {wave = wi, groups = {}, events = {}, count = 0, hp = 0, shield = 0, stealthHp = 0, armorHp = 0, fastHp = 0, noCashHp = 0, cashHp = 0, bonus = w.CashBonus or 0, last = 0, unknown = 0, complex = false}
        for _, seq in ipairs(w.SpawnSequences or {}) do
            local e = entry(seq)
            local n = seq.Count or 0
            data.count += n
            if not e then data.unknown += n continue end
            local load = (e.hp + e.shield + e.extra) * n
            data.hp += e.hp * n
            data.shield += e.shield * n
            if e.stealth then data.stealthHp += load end
            local bullet = e.resist[tostring(c.ranger.stats(0, 0).damageType)] or 0
            if bullet >= 0.15 then data.armorHp += load end
            if e.speed >= 4 then data.fastHp += load end
            if e.noCash then data.noCashHp += e.hp * n else data.cashHp += e.hp * n end
            if e.complex or #e.kids > 0 then data.complex = true end
            local g = table.clone(e)
            g.count = n
            g.first = seq.StartDelay or 0
            g.last = g.first + math.max(0, n - 1) * (seq.Interval or 0)
            data.last = math.max(data.last, g.last)
            table.insert(data.groups, g)
            for i = 1, n do
                table.insert(data.events, {at = g.first + (i - 1) * (seq.Interval or 0), enemy = e})
            end
        end
        table.sort(data.events, function(a,b) return a.at < b.at end)
        table.sort(data.groups, function(a,b) return a.first < b.first end)
        waves[wi] = data
    end

    function f.wave(n)
        return waves[n]
    end

    function f.children(name)
        if children[name] then return children[name] end
        local e = entry({EnemyType = name})
        local kids=e and e.kids or {}
        children[name]=kids
        return kids
    end

    function f.catalog()
        local out = {}
        for i, w in ipairs(waves) do
            out[i] = {wave = i, count = w.count, hp = w.hp, shield = w.shield, stealthHp = w.stealthHp, armorHp = w.armorHp, fastHp = w.fastHp, noCashHp = w.noCashHp, bonus = w.bonus, estimatedIncome = c.economy.income(i, w.cashHp), unknown = w.unknown, complex = w.complex}
        end
        return out
    end

    function f.scenario(s, routes, wi, elapsed, horizon, routeIndex, includeLive)
        local w = waves[wi]
        local r = routes[routeIndex]
        if not w or not r then return s end
        local copy = table.clone(s)
        copy.enemies = includeLive and table.clone(s.enemies) or {}
        local start = c.physics.pack(r.points[1])
        for i, ev in ipairs(w.events) do
            local t = ev.at - elapsed
            if t >= 0 and t <= horizon then
                local e = table.clone(ev.enemy)
                e.id = "forecast_" .. wi .. "_" .. i
                e.spawnAt = t
                e.pathIndex = routeIndex
                e.pathPos = start
                e.pos = start
                copy.enemies[e.id] = e
            end
        end
        return copy
    end

    function f.pressure(wi)
        local w = waves[wi]
        if not w then return 0 end
        local total = 0
        for _, g in ipairs(w.groups) do
            total += (g.hp + g.shield + g.extra) * g.count
        end
        return total
    end

    function f.value(stats, pos, routes, exposure, wi)
        local value = 0
        local norm = 0
        for offset = 0, 9 do
            local w = waves[wi + offset]
            if w then
                local weight = 1 / (1 + offset * 0.65)
                local total = math.max(1, f.pressure(wi + offset))
                local count = math.max(1, w.count)
                for _, g in ipairs(w.groups) do
                    local demand = g.hp + g.shield + g.extra
                    local resist = stats.ignoreResistance and 0 or (g.resist[tostring(stats.damageType)] or 0)
                    local dmg = stats.dps * (1 - resist)
                    local covered = exposure(pos, stats.range)
                    local capacity = dmg * covered / math.max(0.1, g.speed)
                    if g.stealth and not stats.stealthDetection then capacity = 0 end
                    local spread = math.min(1, (w.last + covered / math.max(0.1,g.speed) + 1) / math.max(1, g.count * (covered / math.max(0.1,g.speed))))
                    capacity *= spread
                    if stats.path2 and stats.path2 >= 4 and not g.air and (not g.stealth or stats.stealthDetection) then
                        local splash = stats.path2 == 5 and 100 / 5 or 75 / 8
                        capacity += splash * covered / math.max(0.1,g.speed) * math.min(2, count / math.max(1,w.last)) * 0.35
                    end
                    if not g.air then value += weight * g.count * math.min(demand, capacity) / total end
                end
                norm += weight
            end
        end
        return value / math.max(1, norm)
    end

    function f.future(wi)
        local out = {}
        local cash = 0
        for i = wi, #waves do
            local w = waves[i]
            cash += c.economy.income(i, w.cashHp) + w.bonus
            out[#out + 1] = {wave = i, hp = w.hp, shield = w.shield, stealthHp = w.stealthHp, armorHp = w.armorHp, cashCeiling = cash, unknown = w.unknown, complex = w.complex}
        end
        return out
    end

    return f
end

return m
