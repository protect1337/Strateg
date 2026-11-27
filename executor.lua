local m = {}
local ps = game:GetService("Players")

function m.new(common, reader, ctx, log)
    local client = ps.LocalPlayer.PlayerScripts:WaitForChild("Client")
    local gc = client:WaitForChild("GameClass")
    local tc = require(gc:WaitForChild("TowerClass"))
    local gameClass = require(gc)
    local pc = require(client:WaitForChild("PlayerClass"))
    local net = require(common.NetworkingHandler)
    local place = net.GetFunction("PlaceTower")
    local upgrade = net.GetEvent("TowerUpgradeRequest")
    local sell = net.GetEvent("SellTower")
    local vote = net.GetEvent("SkipWaveVoteCast")
    local query = net.GetEvent("ChangeQueryType")
    local queryAcks={}
    local queryPending={}
    local queryTime={}
    local nu=require(common.NetworkingUtilities)
    net.GetEvent("TowerQueryTypeIndexChanged"):AttachCallback(function(data)
        for _,v in pairs(data) do
            local hash,index=nu.DecompressDoubleHash(v)
            queryAcks[hash]=index
        end
    end)
    local canVote = false
    local pending
    local nextAt = 0
    local votedWave
    local confirmedSkipWave
    local blocked = {}
    local x = {}

    net.GetEvent("SkipWaveVoteStateUpdate"):AttachCallback(function(data)
        canVote = data.VotingEnabled == true
    end)

    local function allowed(s)
        return s and s.running and s.difficulty == "Easy" and s.playerCount == 1
    end

    local function tower(id)
        for _, t in pairs(tc.GetTowers()) do
            if tostring(t.UniqueId) == id and t.IsAlive and t.OwnedByLocalPlayer and t.Type == "Ranger" then
                return t
            end
        end
    end

    local function key(a)
        local pos = a.pos
        return table.concat({a.kind, a.id or "", tostring(a.path or ""), a.name or "", pos and string.format("%.1f:%.1f:%.1f", pos.x, pos.y, pos.z) or ""}, "/")
    end

    local function report(a, status, reason)
        log.record("decisions", {event = "action", action = a, status = status, reason = reason})
        if status == "failed" then
            blocked[key(a)] = os.clock() + 1.5
            log.record("errors", {stage = "action", action = a, error = reason})
        end
    end

    function x.available(a)
        return not blocked[key(a)] or os.clock() >= blocked[key(a)]
    end

    function x.ready(s)
        for id,p in pairs(queryPending) do
            local t=s and s.towers[id]
            if queryAcks[p.hash]==p.action.query then
                local obj=tower(id)
                if obj then obj:SetQueryTypeIndex(p.action.query) end
                report(p.action,"confirmed","server_query_update")
                queryPending[id]=nil
            elseif t and p.action.target and t.target==p.action.target and t.target~=p.prior then
                local obj=tower(id)
                if obj then obj:SetQueryTypeIndex(p.action.query) end
                report(p.action,"observed","target_changed")
                queryPending[id]=nil
            elseif os.clock()>=p.deadline then
                report(p.action,"unconfirmed","query_update_missing")
                queryPending[id]=nil
            end
        end
        if not allowed(s) then
            pending = nil
            return false
        end
        if pending then
            local a = pending.action
            local confirmed = false
            local t = a.id and s.towers[a.id]
            if a.kind == "place" then
                for id, item in pairs(s.towers) do
                    if not pending.ids[id] and item.owned and item.type == "Ranger" and (ctx.physics.vec(item.pos) - ctx.physics.vec(a.pos)).Magnitude < 2 then
                        confirmed = true
                        break
                    end
                end
            elseif a.kind == "upgrade" then
                confirmed = t and (a.path == 1 and t.path1 or t.path2) >= pending.level + (pending.levels or 1)
            elseif a.kind == "sell" then
                confirmed = not t
            elseif a.kind == "ability" then
                local ab = t and t.abilities[a.name]
                confirmed = ab and (ab.cooldown or 0) > pending.cooldown
            elseif a.kind == "skip" then
                confirmed = s.wave ~= pending.wave
            end
            if confirmed then
                report(a, "confirmed")
                if a.kind=="skip" then confirmedSkipWave=pending.wave end
                pending = nil
            elseif os.clock() >= pending.deadline then
                report(a, "failed", "confirmation_timeout")
                pending = nil
            end
        end
        return not pending and os.clock() >= nextAt
    end

    function x.skipConfirmed(wi) return confirmedSkipWave==wi end

    function x.canSkip(s)
        return canVote and votedWave ~= s.wave
    end

    function x.target(a,s)
        if not allowed(s) or s.wave<12 or not a or queryPending[a.id] or os.clock()-(queryTime[a.id] or -math.huge)<2 then return false end
        local t=tower(a.id)
        if not t or t.CustomQueryOptions or type(a.query)~="number" or a.query%1~=0 or a.query<0 or a.query>3 or t.QueryTypeIndex==a.query then return false end
        local ok=pcall(function()
            queryAcks[t.Hash]=nil
            query:FireServer(t.Hash,a.query)
        end)
        if not ok then return false end
        queryTime[a.id]=os.clock()
        queryPending[a.id]={hash=t.Hash,action=a,prior=s.towers[a.id] and s.towers[a.id].target,deadline=os.clock()+0.8}
        report(a,"sent")
        return true
    end

    function x.run(a)
        if not a or a.kind == "hold" or not x.available(a) then return false end
        local s = reader.read()
        if not allowed(s) or not x.ready(s) then return false end
        if a.kind=="sell" and s.wave<12 or a.kind=="skip" and s.wave<1 then return false end
        local player = pc.GetLocalPlayerWrapper()
        if not player or not player.Stats then return false end
        local stats = player.Stats
        local t = a.id and tower(a.id)
        local p = {action = a, wave = s.wave, deadline = os.clock() + 5}
        local ok, accepted, reason = pcall(function()
            if a.kind == "place" then
                local cfg = ctx.ranger.config
                local cost = cfg.UpgradePathData.BaseLevelData.Cost * gameClass.GetTowerCostMultiplier("Ranger")
                if not stats:HasCash(cost) or stats:MaxTowersReached() or player:TowerTypeLimitReached("Ranger") then return false, "placement_limit" end
                local pos = ctx.physics.vec(a.pos)
                if not ctx.placementHandler.Check(pos, cfg, ctx.team.GetLocalPlayerTeamIndex()) then return false, "invalid_placement" end
                p.ids = {}
                for id in pairs(s.towers) do p.ids[id] = true end
                return not not place:InvokeServer(os.clock(), "Ranger", pos, 0), "placement_rejected"
            elseif a.kind == "upgrade" then
                if not t then return false, "tower_missing" end
                local l = t.LevelHandler
                if t:IsRebuilding() or t:IsReviving() or not t.AbilityHandler:CanUpgrade() then return false, "tower_busy" end
                p.level = l:GetLevelOnPath(a.path)
                if p.level >= l:GetMaxPossibleLevel(a.path) then return false, "path_locked" end
                local levels = math.clamp(a.levels or 1, 1, l:GetMaxPossibleLevel(a.path)-p.level)
                local cost = l:GetLevelUpgradeCost(a.path, levels, t.BuffHandler:GetDiscount(), gameClass.GetTowerCostMultiplier(t.Type), t:GetDynamicPriceScalingData())
                if not stats:HasCash(cost) then return false, "cash" end
                p.levels=levels
                upgrade:FireServer(t.Hash, a.path, levels)
                return true
            elseif a.kind == "sell" then
                if not t or t:IsRebuilding() or t:IsReviving() then return false, "tower_missing_or_busy" end
                sell:FireServer(t.Hash)
                return true
            elseif a.kind == "ability" then
                if not t or not t.CurrentTarget then return false, "target_missing" end
                local ab = t.AbilityHandler:GetAbility(a.name)
                if not ab or ab.Passive or not ab:CanUse() or not ab:CanAfford() then return false, "ability_unavailable" end
                p.cooldown = ab:GetCooldownRemaining()
                return not not ab:Use(), "ability_rejected"
            elseif a.kind == "skip" then
                if not x.canSkip(s) or a.wave ~= s.wave then return false, "vote_unavailable" end
                local threat = 0
                for _, e in pairs(s.enemies) do threat += e.hp + (e.shield or 0) end
                if threat > (a.threat or 0) + math.max(8, (a.threat or 0) * 0.05) or s.lives < (a.lives or s.lives) then return false, "forecast_changed" end
                vote:FireServer(true)
                votedWave = s.wave
                return true
            end
            return false, "unknown_action"
        end)
        nextAt = os.clock() + 0.06
        if not ok or not accepted then
            report(a, "failed", tostring(ok and reason or accepted))
            return false
        end
        p.deadline = os.clock() + (a.kind=="upgrade" and 1.5 or 5)
        pending = p
        report(a, "sent")
        return true
    end

    return x
end

return m
