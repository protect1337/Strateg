local m = {}

function m.new(common)
    local cfg = require(common.Resources.Towers.Configs.Ranger)
    local util = require(common.TowerUtilities)
    local data = cfg.UpgradePathData
    local r = {config = cfg}

    function r.valid(a, b)
        return a >= 0 and b >= 0 and a <= #data.Path1Data and b <= #data.Path2Data and not (a >= data.PathLockLevel and b >= data.PathLockLevel)
    end

    function r.stats(a, b)
        assert(r.valid(a, b), "invalid levels")
        local s = util.GetLevelStats(data, a, b)
        return {
            path1 = a, path2 = b, cost = s.TotalCost,
            damage = s.Damage, reload = s.ReloadTime,
            burstSize = s.IsBurst and s.BurstSize or 1,
            burstInterval = s.BurstInterval or 0,
            range = s.Range, radius = cfg.Radius,
            damageType = s.DamageType, ignoreResistance = s.IgnoreResistance,
            stealthDetection = s.StealthDetection,
            dps = util.CalculateAttackDataDPS(s)
        }
    end

    function r.upgrades(t)
        local out = {}
        for path = 1, 2 do
            local a = t.path1 + (path == 1 and 1 or 0)
            local b = t.path2 + (path == 2 and 1 or 0)
            if r.valid(a, b) then
                local s = r.stats(a, b)
                local base = r.stats(t.path1, t.path2)
                s.price = s.cost - base.cost
                s.path = path
                table.insert(out, s)
            end
        end
        return out
    end

    function r.all()
        local out = {}
        for a = 0, #data.Path1Data do
            for b = 0, #data.Path2Data do
                if r.valid(a, b) then
                    table.insert(out, r.stats(a, b))
                end
            end
        end
        return out
    end

    return r
end

return m
