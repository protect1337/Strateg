local m = {}

function m.assess(s, baseline, nextWave, economy)
    if not nextWave then return {allowed = false, reason = "last_wave"} end
    if baseline.leaks >= s.lives then return {allowed = false, reason = "lethal_projection"} end
    local demand = 0
    for _, seq in ipairs(nextWave.SpawnSequences or {}) do demand += seq.Count or 0 end
    return {allowed = false, reason = "overlap_not_validated", nextCount = demand, bonus = economy.bonus(s.wave + 1), currentLeaks = baseline.leaks}
end

return m
