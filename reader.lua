local ps = game:GetService("Players")
local rep = game:GetService("ReplicatedStorage")
local lp = ps.LocalPlayer
local m = {}

local function vec(v)
    return {x = v.X, y = v.Y, z = v.Z}
end

local function nums(t)
    local out = {}
    for k, v in pairs(t or {}) do
        if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
            out[tostring(k)] = v
        end
    end
    return out
end

function m.new()
    local client = lp:WaitForChild("PlayerScripts"):WaitForChild("Client")
    local gc = client:WaitForChild("GameClass")
    local gameClass = require(gc)
    local ec = require(gc:WaitForChild("EnemyClass"))
    local tc = require(gc:WaitForChild("TowerClass"))
    local pc = require(client:WaitForChild("PlayerClass"))
    local common = rep:WaitForChild("TDX_Shared"):WaitForChild("Common")
    local enums = require(common:WaitForChild("Enums"))
    local util = require(common.TowerUtilities)
    local path = require(common:WaitForChild("PathHandler"))
    local team = require(common:WaitForChild("TeamUtilities"))

    local r = {}
    local wave
    local age
    local lastTime
    local timer
    local timerAt
    local gameClock=0
    local clockAt=os.clock()
    local buffTimes={}
    local bossUses={}
    local net=require(common.NetworkingHandler)
    net.GetEvent("EnemyUsedAbility"):AttachCallback(function(data)
        local e=ec.GetEnemy(data[1])
        local a=data[2]
        if e and a and (e.Type=="Plague Doctor" or e.DisplayName=="Plague Doctor") then
            local id=tostring(e.UniqueId)
            bossUses[id]=bossUses[id] or {}
            bossUses[id][a[1]]=gameClock
        end
    end)
    local bind = require(common.BindableHandler)
    bind.GetEvent("WaveChanged"):AttachCallback(function(n, rewind, started)
        if started and not rewind then
            wave = n
            age = 0
            lastTime = os.clock()
        elseif rewind or wave ~= n then
            wave = nil
            age = nil
        end
    end)

    bind.GetEvent("TimeLeftChanged"):AttachCallback(function(n)
        timer = n
        timerAt = os.clock()
    end)

    function r.read()
        local g = gameClass.GetCurrentGame()
        local player = pc.GetLocalPlayerWrapper()
        if not g then return end
        local votingNow = g:GetState() == enums.GameStates.DifficultyVoting
        if (not player or not player.Stats) and not votingNow then return end

        local stats = player and player.Stats
        local teamId = team.GetLocalPlayerTeamIndex() or 1
        local lives = g.TeamDataTable and g.TeamDataTable[teamId]
        local voting = g:GetState() == enums.GameStates.DifficultyVoting
        if not lives and not voting then return end
        lives = lives or {Lives = 500, TotalLives = 500}

        local now=os.clock()
        local speed=g:GetFinalSpeedMultiplier() or 1
        gameClock+=math.max(0,now-clockAt)*speed
        clockAt=now
        local s = {
            time = os.clock(),
            map = g.MapName,
            difficulty = g.Difficulty,
            phase = g:GetState(),
            running = g:GetState() == enums.GameStates.Running,
            voting = voting,
            wave = g.WaveNumber,
            timeLeft = g.TimeLeft,
            speed = g:GetFinalSpeedMultiplier(),
            cash = stats and stats:GetCash() or 0,
            damage = stats and stats.Damage or 0,
            kills = stats and stats.Kills or 0,
            towerCount = stats and stats.TowerCount or 0,
            towerLimit = lp:GetAttribute("MaximumTowerCountPerPlayer"),
            lives = lives.Lives,
            maxLives = lives.TotalLives,
            playerCount = #ps:GetPlayers(),
            enemies = {},
            towers = {}
        }

        if type(timer) ~= "number" and type(s.timeLeft) == "number" then
            timer=s.timeLeft
            timerAt=s.time
        end
        if (s.running or s.voting) and type(timer) == "number" then
            local rate=s.voting and 1 or (s.speed or 1)
            s.timerRemaining=math.max(0,timer-(s.time-timerAt)*rate)
        else
            s.timerRemaining=s.timeLeft
        end
        if s.running and wave == s.wave and age ~= nil then
            local now = s.time
            age += math.max(0, now - (lastTime or now)) * (s.speed or 1)
            lastTime = now
            s.waveAge = age
        elseif not s.running then
            wave = nil
            age = nil
        end

        for _, e in pairs(ec.GetEnemies()) do
            if e.IsAlive and not e.IsFakeEnemy then
                local h = e.HealthHandler
                local mv = e.MovementHandler
                local id = tostring(e.UniqueId)
                local predicted
                if not e.Stunned and not e.Stopped and not mv.ReverseDirection then
                    local ok, a, b = pcall(function() return e:GetPredictedPosition(0.75), e:GetPredictedPosition(1.5) end)
                    if ok and typeof(a) == "Vector3" and typeof(b) == "Vector3" then predicted = {vec(a), vec(b)} end
                end
                s.enemies[id] = {
                    id = id,
                    type = e.Type,
                    name = e.DisplayName,
                    hp = h:GetHealth(),
                    maxHp = h:GetMaxHealth(),
                    shield = h:GetShield(),
                    maxShield = h:GetMaxShield(),
                    pos = vec(e:GetPosition()),
                    pathPos = vec(e:GetPathPosition()),
                    predicted = predicted,
                    pathIndex = mv.PathIndex,
                    pathProgress = mv.PathPercentage,
                    speed = mv:GetCurrentSpeed(),
                    stopped = e.Stopped,
                    reverse = mv.ReverseDirection,
                    stealth = e.Stealth,
                    air = e.IsAirUnit,
                    stunned = e.Stunned,
                    invulnerable = e.Invulnerable,
                    noDamage = e.TakeNoDamage,
                    noCash = e.NoCash,
                    untargetable = e.Untargetable,
                    stasis = e.InStasis,
                    resist = nums(e.DamageReductionMap),
                    resistModifier = e.DamageResistanceModifier,
                    allReduction = e.AllDamageReduction,
                    maxDamage = e.MaximumDamage,
                    burn = nums(e.BurnHandler.VFXNameToBurnTimeLeftMap),
                    boss=e.Type=="Plague Doctor" or e.DisplayName=="Plague Doctor",
                    bossHealIn=bossUses[id] and bossUses[id].PlagueDoctorStun and math.max(0,30-(gameClock-bossUses[id].PlagueDoctorStun)) or nil,
                    smokeHealed=bossUses[id] and bossUses[id].PlagueDoctorSmokeHeal~=nil or false
                }
            end
        end

        for _, t in pairs(tc.GetTowers()) do
            if t.IsAlive then
                local l = t.LevelHandler
                local h = t.HealthHandler
                local ls = l:GetLevelStats()
                local id = tostring(t.UniqueId)
                local ab = {}
                local debuffs={}
                local buffs=t.BuffHandler:GetStatMultipliers()
                local active={}
                local previous=buffTimes[id] or {}
                for hash,b in pairs(t.BuffHandler.ActiveBuffs or {}) do
                    if b.IsDebuff then
                        active[hash]=previous[hash] or gameClock
                        debuffs[b.Name]={duration=b.Config.Time,remaining=math.max(0,(b.Config.Time or 0)-(gameClock-active[hash])),amount=b.Amount,type=b.Type}
                    end
                end
                buffTimes[id]=active
                for name, a in pairs(t.AbilityHandler.Abilities) do
                    local cfg=a.Config
                    local projectile=cfg.ProjectileHitData
                    ab[name] = {
                        cooldown = a:GetCooldownRemaining(),
                        total = a:GetTotalCooldown(),
                        passive = cfg.Passive,
                        custom = cfg.CustomTriggered,
                        manual = cfg.IsManualAimAtGround or cfg.IsManualAimAtPath or cfg.ManualAimInfiniteRange,
                        aimRange = cfg.CustomQueryData and cfg.CustomQueryData.Range,
                        radius = projectile and projectile.SplashRadius or cfg.EffectRadius,
                        damage = projectile and projectile.Damage or cfg.Damage,
                        disabled = a:GetDisabled()
                    }
                end

                s.towers[id] = {
                    id = id,
                    type = t.Type,
                    owned = t.OwnedByLocalPlayer,
                    pos = vec(t:GetPosition()),
                    hp = h:GetHealth(),
                    maxHp = h:GetMaxHealth(),
                    path1 = l:GetLevelOnPath(1),
                    path2 = l:GetLevelOnPath(2),
                    range = t:GetCurrentRange(),
                    radius = t.Radius,
                    reload = t:GetCurrentReloadTime(),
                    damage = ls.Damage * (1 + (buffs.DamageMultiplier or 0)),
                    query=t.QueryTypeIndex,
                    debuffs=debuffs,
                    stunned=buffs.Stunned,
                    rangeMultiplier=buffs.RangeMultiplier,
                    fireMultiplier=buffs.FirerateMultiplier,
                    buffDamageMultiplier=buffs.DamageMultiplier,
                    attackDisabled = t.AttackDisabled,
                    damageMultiplier = t.DamageMultiplier,
                    damageType = ls.DamageType,
                    ignoreResistance = ls.IgnoreResistance,
                    stealthDetection = ls.StealthDetection,
                    burstSize = ls.IsBurst and ls.BurstSize or 1,
                    burstInterval = ls.BurstInterval,
                    burstIndex = t.AttackBurstIndex,
                    burstReset = t.TimeUntilResetAttackBurstIndex,
                    nextAttack = t.TimeUntilNextAttack,
                    target = t.CurrentTarget and tostring(t.CurrentTarget.UniqueId),
                    damageDealt = t.DamageDealt,
                    cashEarned = t.CashEarned,
                    cost = t.TotalCost,
                    sellValue = math.floor(util.GetSellReturnRate(t:IsConverted(),t.BuffHandler:GetSellback()) * t.TotalCost),
                    abilities = ab
                }
            end
        end

        if s.running or s.voting then
            s.spawnIndices = table.clone(path.GetSpawnIndices(teamId) or {})
        elseif s.phase == enums.GameStates.EndScreen then
            local gui = lp:FindFirstChild("PlayerGui")
            local interface = gui and gui:FindFirstChild("Interface")
            local screen = interface and interface:FindFirstChild("GameOverScreen")
            local main = screen and screen:FindFirstChild("Main")
            local win = main and main:FindFirstChild("VictoryText")
            local loss = main and main:FindFirstChild("DefeatText")
            if win and loss and win.Visible ~= loss.Visible then
                s.outcome = win.Visible and "win" or "loss"
            end
        end

        return s
    end

    return r
end

return m
