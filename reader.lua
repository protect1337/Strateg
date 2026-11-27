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
    local path = require(common:WaitForChild("PathHandler"))
    local team = require(common:WaitForChild("TeamUtilities"))

    local r = {}
    local wave
    local age
    local lastTime
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

    function r.read()
        local g = gameClass.GetCurrentGame()
        local player = pc.GetLocalPlayerWrapper()
        if not g or not player or not player.Stats then return end

        local stats = player.Stats
        local teamId = team.GetLocalPlayerTeamIndex()
        local lives = g.TeamDataTable[teamId]
        if not lives then return end

        local s = {
            time = os.clock(),
            map = g.MapName,
            difficulty = g.Difficulty,
            phase = g:GetState(),
            running = g:GetState() == enums.GameStates.Running,
            wave = g.WaveNumber,
            timeLeft = g.TimeLeft,
            speed = g:GetFinalSpeedMultiplier(),
            cash = stats:GetCash(),
            damage = stats.Damage,
            kills = stats.Kills,
            towerCount = stats.TowerCount,
            towerLimit = lp:GetAttribute("MaximumTowerCountPerPlayer"),
            lives = lives.Lives,
            maxLives = lives.TotalLives,
            playerCount = #ps:GetPlayers(),
            enemies = {},
            towers = {}
        }

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
                    burn = nums(e.BurnHandler.VFXNameToBurnTimeLeftMap)
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
                for name, a in pairs(t.AbilityHandler.Abilities) do
                    ab[name] = {
                        cooldown = a:GetCooldownRemaining(),
                        total = a:GetTotalCooldown(),
                        passive = a.Config.Passive,
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
                    damage = ls.Damage * (1 + (t.BuffHandler:GetStatMultipliers().DamageMultiplier or 0)),
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
                    abilities = ab
                }
            end
        end

        if s.running then
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
