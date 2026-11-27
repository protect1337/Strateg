local hs = game:GetService("HttpService")
local m = {}
local names = {"decisions", "errors", "progress", "shield", "economy", "grenade", "burn", "burst", "forecast"}

function m.new()
    local root = "LOGS"
    local session = tostring(os.time()) .. "_" .. string.sub(hs:GenerateGUID(false), 1, 8)
    local folders = {
        decisions = "plan", errors = "errors", progress = "winrate",
        shield = "damage", economy = "economy", grenade = "grenade",
        burn = "burn", burst = "burst", forecast = "forecast"
    }
    local files = {}
    if not isfolder(root) then makefolder(root) end
    for _, name in ipairs(names) do
        local dir = root .. "/" .. folders[name]
        if not isfolder(dir) then makefolder(dir) end
        files[name] = dir .. "/" .. session .. "_" .. name .. ".txt"
        writefile(files[name], "")
    end

    local l = {}
    local lastProgress = -math.huge
    local started
    local outcome

    function l.record(name, data)
        data.clock = os.clock()
        appendfile(assert(files[name], "unknown log"), hs:JSONEncode(data) .. string.char(10))
    end

    function l.observe(prev, s)
        if s.running and (not prev or not prev.running) then
            started = s.time
            outcome = nil
        end
        if s.outcome and not outcome then
            outcome = s.outcome
            l.record("progress", {event = "result", outcome = outcome, map = s.map, wave = s.wave, lives = s.lives, durationObserved = started and s.time - started})
        end
        if not prev or prev.map ~= s.map or prev.wave ~= s.wave or prev.phase ~= s.phase or s.time - lastProgress >= 1 then
            lastProgress = s.time
            local count = 0
            for _ in pairs(s.enemies) do count += 1 end
            l.record("progress", {
                revision = s.revision, map = s.map, wave = s.wave, phase = s.phase,
                timeLeft = s.timeLeft, cash = s.cash, lives = s.lives,
                enemies = count, towers = s.towerCount, damage = s.damage, kills = s.kills
            })
        end
        if not prev or prev.map ~= s.map then return end

        local changes = {}
        for id, e in pairs(s.enemies) do
            local old = prev.enemies[id]
            if old then
                if old.hp ~= e.hp or old.shield ~= e.shield then
                    table.insert(changes, {id = id, type = e.type, hpBefore = old.hp, hpAfter = e.hp, shieldBefore = old.shield, shieldAfter = e.shield})
                end
                if old.shield ~= e.shield then
                    l.record("shield", {wave = s.wave, id = id, type = e.type, hpBefore = old.hp, hpAfter = e.hp, shieldBefore = old.shield, shieldAfter = e.shield, cashDelta = s.cash - prev.cash})
                end
                for name, left in pairs(e.burn) do
                    if not old.burn[name] or left > old.burn[name] then
                        l.record("burn", {wave = s.wave, id = id, effect = name, before = old.burn[name], after = left, hp = e.hp, observation = "visual_timer"})
                    end
                end
            end
        end

        for id, old in pairs(prev.enemies) do
            if not s.enemies[id] then
                table.insert(changes, {id = id, type = old.type, hpBefore = old.hp, shieldBefore = old.shield, observation = "removed"})
            end
        end

        if #changes > 0 then
            l.record("shield", {wave = s.wave, event = "hp_delta", changes = changes, damageDelta = s.damage - prev.damage, observation = "sample_delta"})
        end
        if s.cash ~= prev.cash or #changes > 0 then
            l.record("economy", {wave = s.wave, players = s.playerCount, cashBefore = prev.cash, cashAfter = s.cash, damageDelta = s.damage - prev.damage, killsDelta = s.kills - prev.kills, changes = changes, observation = "sample_delta"})
        end

        for id, t in pairs(s.towers) do
            local old = prev.towers[id]
            if old and t.type == "Ranger" then
                if old.target ~= t.target or old.burstIndex ~= t.burstIndex then
                    l.record("burst", {wave = s.wave, tower = id, targetBefore = old.target, targetAfter = t.target, indexBefore = old.burstIndex, indexAfter = t.burstIndex, resetBefore = old.burstReset, resetAfter = t.burstReset, reload = t.reload, observation = "client_index"})
                end
                for name, a in pairs(t.abilities) do
                    local prior = old.abilities[name]
                    if prior and type(a.cooldown) == "number" and type(prior.cooldown) == "number" and a.cooldown > prior.cooldown then
                        if name == "GrenadeLevel1" or name == "GrenadeLevel2" then
                            l.record("grenade", {wave = s.wave, tower = id, ability = name, target = t.target, cooldown = a.cooldown, observation = "cooldown_increase"})
                        elseif name == "M203" then
                            l.record("burn", {wave = s.wave, tower = id, ability = name, target = t.target, cooldown = a.cooldown, observation = "cooldown_increase"})
                        end
                    end
                end
            end
        end
    end

    return l
end

return m
