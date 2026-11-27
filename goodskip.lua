local m = {}

function m.lastSpawn(w)
    local last = 0
    for _, seq in ipairs(w and w.SpawnSequences or {}) do
        last = math.max(last, (seq.StartDelay or 0) + math.max(0, (seq.Count or 0) - 1) * (seq.Interval or 0))
    end
    return last
end

function m.preview(s, wave, routes, c)
    if not wave then return end
    local shortest
    local index
    for idx, route in pairs(routes) do
        if not shortest or route.length < shortest.length then
            shortest = route
            index = idx
        end
    end
    if not shortest then return end
    local copy = table.clone(s)
    copy.enemies = table.clone(s.enemies)
    local start = c.physics.pack(shortest.points[1])
    local horizon = 0
    local count = 0
    local complex = false
    for _, seq in ipairs(wave.SpawnSequences or {}) do
        local cfg = c.resources.GetEnemyConfig(seq.EnemyType)
        if not cfg or type(cfg.Health) ~= "number" or type(cfg.Speed) ~= "number" or cfg.Speed <= 0 then return end
        local override = cfg.DifficultyToStatOverrideMap and cfg.DifficultyToStatOverrideMap[s.difficulty]
        if override then complex = true end
        if cfg.AbilityNames or cfg.DeathAbilityNames or cfg.SecondLifeData or cfg.DeathSpawnData then complex = true end
        local hp = cfg.Health * (1 + (seq.AdditionalHealthMultiplier or 0))
        local shield = (cfg.Shield or 0) + cfg.Health * (seq.AdditionalShieldMultiplier or 0)
        local resist = {}
        for _, item in pairs(cfg.DamageReductionTable or {}) do
            resist[tostring(item.DamageType)] = item.DamageReduction
        end
        for i = 1, seq.Count or 0 do
            count += 1
            if count > 300 then return end
            local at = (seq.StartDelay or 0) + (i - 1) * (seq.Interval or 0)
            local id = "future_" .. count
            copy.enemies[id] = {
                id = id, type = seq.EnemyType, hp = hp, shield = shield,
                pos = start, pathPos = start, pathIndex = index, speed = cfg.Speed,
                spawnAt = at, stealth = seq.Stealth or cfg.Stealth,
                air = cfg.AirUnit, resist = resist, maxDamage = cfg.MaximumDamage,
                allReduction = cfg.AllDamageReduction
            }
            horizon = math.max(horizon, at + shortest.length / cfg.Speed + 1)
        end
    end
    if count == 0 then return end
    return copy, math.min(100, horizon), complex, horizon <= 100
end

function m.assess(s, c, routes, los, elapsed)
    local current = c.economy.config.Waves[s.wave]
    local nextWave = c.economy.config.Waves[s.wave + 1]
    if not nextWave then return {allowed = false, reason = "last_wave"} end
    if not current or not elapsed or elapsed < m.lastSpawn(current) + 2 then
        return {allowed = false, reason = "spawn_window"}
    end
    if #s.spawnIndices ~= 1 then return {allowed = false, reason = "multiple_paths"} end
    if (s.timeLeft or 0) <= 1 then return {allowed = false, reason = "no_time_saved"} end
    local preview, horizon, complex, complete = m.preview(s, nextWave, routes, c)
    if not preview or complex or not complete then return {allowed = false, reason = "uncertain_wave"} end
    local res = c.combat.run(preview, routes, c.physics, los, nil, horizon)
    local reserve = math.max(20, (s.maxLives or s.lives) * 0.12)
    local loss = res.leaks + res.remaining
    local threat = 0
    for _, e in pairs(s.enemies) do threat += e.hp + (e.shield or 0) end
    return {allowed = s.lives - loss * 1.5 > reserve, reason = "next_wave_forecast", predictedLoss = loss, reserve = reserve, horizon = horizon, threat = threat, lives = s.lives}
end

return m
