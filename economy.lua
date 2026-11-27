local m = {}

function m.new(common)
    local cfg = require(common.Resources.Waves.Easy)
    local e = {config = cfg}

    function e.rate(wave)
        local w = cfg.Waves[wave]
        return w and w.CashMultiplierOverride or cfg.CashPerDamageData[1].CashPerDamage
    end

    function e.income(wave, hpDamage)
        return math.max(0, hpDamage) * e.rate(wave)
    end

    function e.bonus(wave)
        local w = cfg.Waves[wave]
        return w and w.CashBonus or 0
    end

    function e.afford(s, cost)
        return type(cost) == "number" and cost >= 0 and s.cash >= cost
    end

    return e
end

return m
