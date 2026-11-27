local m = {}

function m.rank(s, physics)
    local out = {}
    for id, t in pairs(s.towers) do
        if t.owned and t.type == "Ranger" and t.target then
            local e = s.enemies[t.target]
            if e then
                for name, a in pairs(t.abilities) do
                    local radius = name == "GrenadeLevel1" and 3 or name == "GrenadeLevel2" and 4 or nil
                    if radius and not a.disabled and (a.cooldown or math.huge) <= 0 then
                        local value = 0
                        local damage = radius == 3 and 75 or 100
                        for _, other in pairs(s.enemies) do
                            if not other.air and not other.invulnerable and not other.noDamage and (physics.vec(other.pos) - physics.vec(e.pos)).Magnitude <= radius then
                                value += math.min(other.hp + (other.shield or 0), damage)
                            end
                        end
                        if value > 0 then
                            table.insert(out, {kind = "ability", id = id, name = name, score = value, target = e.id})
                        end
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.score > b.score end)
    return out
end

return m
