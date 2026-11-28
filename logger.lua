local hs = game:GetService("HttpService")
local m = {}
local names = {"decisions", "errors", "progress", "shield", "economy", "grenade", "burn", "burst", "forecast", "skip", "debug"}

function m.new()
    local root = "LOGS"
    local session = tostring(os.time()) .. "_" .. string.sub(hs:GenerateGUID(false), 1, 8)
    local folders = {
        decisions = "plan", errors = "errors", progress = "winrate",
        shield = "damage", economy = "economy", grenade = "grenade",
        burn = "burn", burst = "burst", forecast = "forecast", skip = "skip", debug = "debug"
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
    local queues={}
    for _,name in ipairs(names) do queues[name]={first=1,last=0,data={}} end
    local flushAt=-math.huge
    local flushIndex=0
    local dropped=0
    local writeMs=0
    local started
    local outcome
    local lastBurst=-math.huge
    local towerSample={}

    function l.record(name,data)
        local q=assert(queues[name],"unknown log")
        if q.last-q.first>=4096 and (name=="burst" or name=="shield" or name=="burn") then
            dropped+=1
            return
        end
        local v=table.clone(data)
        v.clock=os.clock()
        q.last+=1 q.data[q.last]=v
    end
    local function flush(name,all)
        local q=queues[name]
        if q.first>q.last then return false end
        local began=os.clock()
        local lines={}
        local last=math.min(q.last,q.first+127)
        for i=q.first,last do
            local ok,v=pcall(hs.JSONEncode,hs,q.data[i])
            if ok then lines[#lines+1]=v else dropped+=1 end
            q.data[i]=nil
            q.first=i+1
            if not all and os.clock()-began>=0.001 then break end
        end
        if #lines>0 then
            local ok=pcall(appendfile,files[name],table.concat(lines,"\n").."\n")
            if not ok then dropped+=#lines end
        end
        if q.first>q.last then q.first=1 q.last=0 end
        writeMs=(os.clock()-began)*1000
        return true
    end
    function l.pump()
        if os.clock()-flushAt<0.10 then return end
        for i=1,#names do
            flushIndex=flushIndex%#names+1
            if flush(names[flushIndex],false) then flushAt=os.clock() return end
        end
    end
    function l.flush()
        for _,name in ipairs(names) do
            while flush(name,true) do task.wait() end
        end
    end
    function l.metrics()
        local n=0
        for _,q in pairs(queues) do n+=q.last-q.first+1 end
        return n,dropped,writeMs
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
                timeLeft = s.timerRemaining or s.timeLeft, speed = s.speed, cash = s.cash, lives = s.lives,
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
                    if not old.burn[name] or left > old.burn[name]+0.3 then
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
        if s.cash ~= prev.cash or s.damage ~= prev.damage or s.kills ~= prev.kills or #changes > 0 then
            l.record("economy", {wave = s.wave, players = s.playerCount, cashBefore = prev.cash, cashAfter = s.cash, damageDelta = s.damage - prev.damage, killsDelta = s.kills - prev.kills, changes = changes, observation = "sample_delta"})
        end

        local detailed=s.time-lastBurst>=1 or s.wave~=prev.wave
        if detailed then lastBurst=s.time end
        for id,t in pairs(s.towers) do
            local old=prev.towers[id]
            local sample=towerSample[id]
            if not sample or sample.path1~=t.path1 or sample.path2~=t.path2 or detailed and sample.damageDealt~=t.damageDealt then
                l.record("burst", {event = "tower_stats", wave = s.wave, tower = id, pos = t.pos, path1 = t.path1, path2 = t.path2, damageDealt = t.damageDealt, damageDelta = sample and t.damageDealt - sample.damageDealt, cashEarned = t.cashEarned})
                towerSample[id]=t
            end
            if old and t.type == "Ranger" then
                if detailed and (old.target ~= t.target or old.burstIndex ~= t.burstIndex) then
                    l.record("burst", {wave = s.wave, tower = id, targetBefore = old.target, targetAfter = t.target, indexBefore = old.burstIndex, indexAfter = t.burstIndex, resetBefore = old.burstReset, resetAfter = t.burstReset, reload = t.reload, speed = s.speed, path1 = t.path1, path2 = t.path2, damage = t.damage, burstSize = t.burstSize, observation = "client_index"})
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
