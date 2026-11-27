local m = {}

local function at(e, t, physics)
    local p = physics.vec(e.pathPos or e.pos)
    if not e.predicted then return p end
    local a = physics.vec(e.predicted[1])
    local b = physics.vec(e.predicted[2])
    if t <= 0.75 then return p:Lerp(a, math.clamp(t / 0.75,0,1)) end
    return a:Lerp(b,math.clamp((t - 0.75) / 0.75,0,1))
end

function m.rank(s, physics)
    local out = {}
    for id,t in pairs(s.towers) do
        if t.owned and t.type == "Ranger" and t.target then
            local e = s.enemies[t.target]
            if e then
                for name,a in pairs(t.abilities) do
                    local radius = name == "GrenadeLevel1" and 3 or name == "GrenadeLevel2" and 4 or nil
                    if radius and not a.disabled and (a.cooldown or math.huge) <= 0 then
                        local damage = radius == 3 and 75 or 100
                        local origin = physics.vec(t.pos)
                        local target = physics.vec(e.pathPos or e.pos)
                        local delay = 0.15 + math.max(0.15,(target-origin).Magnitude/15,2*math.sqrt(math.abs(target.Y-origin.Y)/120))
                        local lead = at(e,delay,physics)
                        local fixed, moving = 0,0
                        for _,other in pairs(s.enemies) do
                            if not other.air and not other.invulnerable and not other.noDamage and not other.untargetable then
                                local resist = math.clamp((other.resist.Explosive or 0) + (other.resist.Explosive and other.resistModifier or 0),0,1)
                                local d = math.min(other.hp + (other.shield or 0),damage*(1-resist))
                                local p = at(other,delay,physics)
                                if (p-target).Magnitude <= radius then fixed += d end
                                if (p-lead).Magnitude <= radius then moving += d end
                            end
                        end
                        local value = math.min(fixed,moving)*0.65 + math.max(fixed,moving)*0.35
                        if value >= 15 or value > 0 and e.hp >= 30 then
                            table.insert(out,{kind="ability",id=id,name=name,score=value,target=e.id,flight=delay,fixedValue=fixed,trackedValue=moving})
                        end
                    end
                end
            end
        end
    end
    table.sort(out,function(a,b) return a.score > b.score end)
    return out
end

return m
