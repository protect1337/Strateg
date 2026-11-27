local m = {}

function m.new(c)
    local p = {}
    local cached, routes, los, mapName, lastCount, pathKey
    local last = -math.huge
    local lastWave
    local future
    local exposureCache = {}
    local lastSkip = -math.huge
    local statsAll = c.ranger.all()

    function p.plan(s)
        if not s.running or s.difficulty ~= "Easy" or s.playerCount ~= 1 or not s.wave then return end
        if s.time - last < 1.5 then return end
        last = s.time
        local team = c.team.GetLocalPlayerTeamIndex()
        local ids = table.clone(s.spawnIndices or {})
        table.sort(ids)
        local k = table.concat(ids, ",")
        if mapName ~= s.map or pathKey ~= k then
            cached, routes, los = nil, nil, nil
            exposureCache = {}
            mapName, pathKey = s.map, k
        end
        if not routes then
            routes = c.physics.routes(c.path, team, ids)
            if not next(routes) then routes = nil return end
            los = c.physics.los(c.map)
        end
        if not cached or lastCount ~= s.towerCount then
            cached = c.placement.candidates(routes, c.physics, c.placementHandler, c.ranger, team, s, los)
            lastCount = s.towerCount
        end
        if lastWave ~= s.wave then
            lastWave = s.wave
            future = c.forecast.future(math.max(1, s.wave))
        end
        local wi = math.max(1, s.wave)
        local shortest, index
        for idx, r in pairs(routes) do
            if not shortest or r.length < shortest.length then shortest, index = r, idx end
        end
        local function exposure(pos, range)
            local key = string.format("%.2f:%.2f:%.2f:%.2f", pos.X, pos.Y, pos.Z, range)
            if exposureCache[key] ~= nil then return exposureCache[key] end
            local min = math.huge
            local sum, n = 0, 0
            for _, r in pairs(routes) do
                local covered = 0
                for d = 0, r.length, 2 do
                    local q = c.physics.at(r, d)
                    if (q - pos).Magnitude <= range and los(pos, q) then covered += math.min(2, r.length - d) end
                end
                min = math.min(min, covered)
                sum += covered
                n += 1
            end
            exposureCache[key] = n == 0 and 0 or (sum / n * 0.8 + min * 0.2)
            return exposureCache[key]
        end
        local values = {}
        local function val(st, pos)
            local key = string.format("%.2f:%.2f:%.2f:%d:%d", pos.X, pos.Y, pos.Z, st.path1, st.path2)
            if values[key] == nil then values[key] = c.forecast.value(st, pos, routes, exposure, wi) end
            return values[key]
        end
        local horizon = 22
        local scenario = s
        if s.waveAge ~= nil then
            scenario = c.forecast.scenario(s, routes, wi, s.waveAge, horizon, index, true)
        elseif s.wave == 0 then
            scenario = c.forecast.scenario(s, routes, 1, -(s.timeLeft or 0) - 0.3, horizon, index, true)
        end
        local prepared = table.clone(scenario)
        prepared.enemies = {}
        for id, e in pairs(scenario.enemies) do
            local item = table.clone(e)
            if not item.kids then item.kids = c.forecast.children(e.type) end
            prepared.enemies[id] = item
        end
        scenario = prepared
        local base = c.combat.run(scenario, routes, c.physics, los, nil, horizon)
        local rs = c.ranger.stats(0, 0)
        local candidates = {}
        local goals = {}
        local totalValue = 0
        local stealthValue = 0
        local cap = s.towerLimit or 0
        local function put(a)
            local key = {kind = a.kind, id = a.id, path = a.path, pos = a.pos and c.physics.pack(a.pos)}
            if not c.executor.available(key) then return end
            table.insert(candidates, a)
        end
        for id, t in pairs(s.towers) do
            if t.owned and t.type == "Ranger" then
                local pos = c.physics.vec(t.pos)
                local old = c.ranger.stats(t.path1, t.path2)
                local v = val(old, pos)
                totalValue += v
                if old.stealthDetection then stealthValue += v end
                local ups = c.ranger.upgrades(t)
                for _, u in ipairs(ups) do
                    local bestPackage = 0
                    local goal
                    for _, target in ipairs(statsAll) do
                        if target.path1 >= u.path1 and target.path2 >= u.path2 and target.cost > old.cost then
                            local gain = math.max(0, val(target, pos) - v)
                            local price = target.cost - old.cost
                            local rate = gain / math.max(1, price)
                            if rate > bestPackage then
                                bestPackage = rate
                                goal = {id = id, path = u.path, path1 = target.path1, path2 = target.path2, price = price, nextPrice = u.price, value = gain}
                            end
                        end
                    end
                    if goal then
                        goal.priority = bestPackage
                        table.insert(goals, goal)
                    end
                    if c.economy.afford(s, u.price) then
                        local gain = math.max(0, val(u, pos) - v)
                        put({kind = "upgrade", id = id, path = u.path, stats = u, price = u.price, priority = gain / math.max(1,u.price) + bestPackage * 0.7, strategic = gain, goal = goal})
                    end
                end
            end
        end
        table.sort(goals, function(a,b) return a.priority > b.priority end)
        if s.towerCount < cap and c.economy.afford(s, rs.cost) then
            local places = {}
            for _, item in ipairs(cached) do
                local v = val(rs, item.pos)
                local coverage = exposure(item.pos, rs.range)
                if coverage > 0 then
                    table.insert(places, {kind = "place", pos = item.pos, stats = rs, price = rs.cost, strategic = v, priority = v / rs.cost, coverage = coverage})
                end
            end
            table.sort(places, function(a,b) return a.priority > b.priority end)
            for i = 1, math.min(6,#places) do
                local a = places[i]
                if c.placementHandler.Check(a.pos, c.ranger.config, team) then put(a) end
            end
        end
        table.sort(candidates, function(a,b) return a.priority > b.priority end)
        local best, score
        score = 0
        local pressure = math.max(1, c.forecast.pressure(wi))
        local emergency = base.leaks > math.max(0, s.lives * 0.15)
        local goal = goals[1]
        local save = goal and goal.nextPrice > s.cash and not emergency and totalValue > 0.55
        for i = 1, math.min(8,#candidates) do
            local a = candidates[i]
            local res = c.combat.run(scenario, routes, c.physics, los, a, horizon)
            local income = c.economy.income(wi, res.cashDamage) - c.economy.income(wi, base.cashDamage)
            local gain = res.hpDamage - base.hpDamage + (res.shieldDamage - base.shieldDamage) * 0.5 + (base.leaks - res.leaks) * 5 + (base.remaining - res.remaining) * 0.2 + income * 0.4
            local merit = gain / pressure / math.max(1,a.price) + a.priority * (emergency and 0.2 or 1.2)
            if save and gain <= 0 and a.price > s.cash * 0.2 then merit = 0 end
            if res.leaks >= s.lives and base.leaks < s.lives then merit = 0 end
            if merit > score then
                score = merit
                best = {kind = a.kind, id = a.id, path = a.path, price = a.price, pos = a.pos and c.physics.pack(a.pos), score = merit, forecast = res, goal = a.goal}
            end
        end
        if not best and not next(s.enemies) and cap > 0 and s.towerCount >= cap and s.cash >= rs.cost and cached[1] then
            local newValue = val(rs,cached[1].pos)
            for id,t in pairs(s.towers) do
                if t.owned and t.type == "Ranger" and t.path1 == 0 and t.path2 == 0 and val(rs,c.physics.vec(t.pos)) < newValue * 0.3 then
                    local a = {kind = "sell", id = id, reason = "poor_future_coverage"}
                    if c.executor.available(a) then best = a break end
                end
            end
        end
        local skip = {allowed = false, reason = "vote_unavailable"}
        if c.executor.canSkip(s) and s.time - lastSkip > 4 then
            lastSkip = s.time
            skip = c.goodskip.assess(s, c, routes, los, s.waveAge)
        end
        return {wave = s.wave, revision = s.revision, baseline = base, recommendation = best or {kind = "hold", reason = save and "save_for_upgrade" or "no_positive_action"}, skip = skip, mode = "auto", future = future, goal = goal, capacity = totalValue, stealthCapacity = stealthValue, observedWaveAge = s.waveAge}
    end

    return p
end

return m
