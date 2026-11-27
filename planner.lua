local m = {}

function m.new(ctx)
    local p = {}
    local cached
    local routes
    local los
    local mapName
    local lastCount
    local lastWave
    local waveStart
    local observedStart = false
    local last = -math.huge

    function p.plan(s)
        if not s.running or s.difficulty ~= "Easy" or s.playerCount ~= 1 or not s.wave then
            lastWave = nil
            observedStart = false
            return
        end
        local c = ctx
        if mapName ~= s.map then
            cached = nil
            routes = nil
            mapName = s.map
            lastWave = nil
            observedStart = false
        end
        if lastWave ~= s.wave then
            observedStart = lastWave ~= nil or s.wave == 0
            waveStart = s.time
            lastWave = s.wave
        end
        if s.time - last < 1.5 then return end
        last = s.time
        local team = c.team.GetLocalPlayerTeamIndex()
        if not routes then
            routes = c.physics.routes(c.path, team, s.spawnIndices)
            if not next(routes) then routes = nil return end
            los = c.physics.los(c.map)
        end
        if not cached or lastCount ~= s.towerCount then
            cached = c.placement.candidates(routes, c.physics, c.placementHandler, c.ranger, team, s, los)
            lastCount = s.towerCount
        end
        local base = c.combat.run(s, routes, c.physics, los, nil, 12)
        local empty = not next(s.enemies)
        local best
        local bestScore = 0
        local rs = c.ranger.stats(0, 0)
        local function coverage(pos, range)
            local total = 0
            for _, r in pairs(routes) do
                for d = 0, r.length, 3 do
                    local q = c.physics.at(r, d)
                    if (q - pos).Magnitude <= range and los(pos, q) then total += 3 end
                end
            end
            return total
        end
        local function evaluate(a)
            local key = {kind = a.kind, id = a.id, path = a.path, pos = a.pos and c.physics.pack(a.pos)}
            if c.executor and not c.executor.available(key) then return end
            local res = c.combat.run(s, routes, c.physics, los, a, 12)
            local gain = res.hpDamage - base.hpDamage + (base.leaks - res.leaks) * 3 + (res.shieldDamage - base.shieldDamage) * 0.25
            local score = gain / math.max(1, a.price)
            local potential = 0
            if a.kind == "place" then
                potential = a.coverage * a.stats.dps
            elseif a.kind == "upgrade" then
                local t = s.towers[a.id]
                local old = c.ranger.stats(t.path1, t.path2)
                local pos = c.physics.vec(t.pos)
                potential = coverage(pos, a.stats.range) * a.stats.dps - coverage(pos, old.range) * old.dps
                if a.stats.stealthDetection and not old.stealthDetection then potential += 20 end
                if a.stats.ignoreResistance and not old.ignoreResistance then potential += 15 end
                if a.stats.path2 == 4 or a.stats.path2 == 5 then potential += 30 end
            end
            if empty or gain >= -0.01 then
                score += math.max(0, potential) / math.max(1, a.price) * 0.2
            end
            if score > bestScore then
                bestScore = score
                best = {kind = a.kind, id = a.id, path = a.path, price = a.price, pos = a.pos and c.physics.pack(a.pos), score = score, forecast = res}
            end
        end
        local cap = s.towerLimit or 0
        if s.towerCount < cap and c.economy.afford(s, rs.cost) then
            for i = 1, math.min(8, #cached) do
                local item = cached[i]
                if c.placementHandler.Check(item.pos, c.ranger.config, team) then
                    evaluate({kind = "place", pos = item.pos, stats = rs, price = rs.cost, coverage = item.coverage})
                end
            end
        end
        local ups = {}
        for id, t in pairs(s.towers) do
            if t.owned and t.type == "Ranger" then
                local old = c.ranger.stats(t.path1, t.path2)
                for _, u in ipairs(c.ranger.upgrades(t)) do
                    if c.economy.afford(s, u.price) then
                        local gain = math.max(0, u.dps * u.range - old.dps * old.range)
                        if u.stealthDetection and not old.stealthDetection then gain += 50 end
                        if u.ignoreResistance and not old.ignoreResistance then gain += 30 end
                        if u.path2 >= 4 and t.path2 < u.path2 then gain += 50 end
                        table.insert(ups, {kind = "upgrade", id = id, path = u.path, stats = u, price = u.price, priority = gain / math.max(1, u.price)})
                    end
                end
            end
        end
        table.sort(ups, function(a, b) return a.priority > b.priority end)
        for i = 1, math.min(10, #ups) do evaluate(ups[i]) end
        if not best and empty and cap > 0 and s.towerCount >= cap and s.cash >= rs.cost and cached[1] then
            for id, t in pairs(s.towers) do
                if t.owned and t.type == "Ranger" and t.path1 == 0 and t.path2 == 0 then
                    local old = coverage(c.physics.vec(t.pos), t.range)
                    if old < cached[1].coverage * 0.3 then
                        local a = {kind = "sell", id = id, reason = "poor_coverage", replacement = c.physics.pack(cached[1].pos)}
                        if not c.executor or c.executor.available(a) then best = a break end
                    end
                end
            end
        end
        local skip = {allowed = false, reason = "vote_unavailable"}
        if c.executor and c.executor.canSkip(s) then
            local elapsed = observedStart and (s.time - waveStart) * math.min(1, s.speed or 1) or nil
            skip = c.goodskip.assess(s, c, routes, los, elapsed)
        end
        return {wave = s.wave, revision = s.revision, baseline = base, recommendation = best or {kind = "hold"}, abilities = c.ability.rank(s, c.physics), skip = skip, mode = "auto"}
    end

    return p
end

return m
