local m = {}

function m.candidates(routes, physics, placement, ranger, team, snapshot, los)
    local out = {}
    local seen = {}
    local checks = 0
    local samples = {}
    local routeCount = 0
    for _, r in pairs(routes) do
        routeCount += 1
        local points = {}
        local step = math.max(3, r.length / 80)
        for d = 0, r.length, step do
            table.insert(points, {pos = physics.at(r,d), weight = 1.15 - 0.3 * d / r.length, step = step})
        end
        table.insert(samples, points)
    end
    for _, r in pairs(routes) do
        local step = math.max(4, r.length / math.max(8, math.floor(36 / routeCount)))
        for d = 0, r.length, step do
            local p = physics.at(r,d)
            for _, radius in ipairs({3.5, 6, 8.5}) do
                for i = 0, 7 do
                    local angle = i * math.pi / 4
                    local x = math.round((p.X + radius * math.cos(angle)) / 1.5) * 1.5
                    local z = math.round((p.Z + radius * math.sin(angle)) / 1.5) * 1.5
                    local key = string.format("%.1f:%.1f",x,z)
                    if not seen[key] then
                        seen[key] = true
                        checks += 1
                        if checks % 80 == 0 then task.wait() end
                        local y = placement.GetGroundHeightAtXZ(x,z,p.Y)
                        local pos = Vector3.new(x,y,z)
                        if placement.Check(pos,ranger.config,team) then
                            local score = 0
                            local upgraded = 0
                            for _, points in ipairs(samples) do
                                for _, q in ipairs(points) do
                                    local dist = (q.pos - pos).Magnitude
                                    if dist <= 14 and los(pos,q.pos) then
                                        if dist <= 9 then score += q.step * q.weight end
                                        upgraded += q.step * q.weight
                                    end
                                end
                            end
                            if score > 0 then table.insert(out,{pos=pos,coverage=score + upgraded * 0.2}) end
                        end
                    end
                end
            end
        end
    end
    table.sort(out,function(a,b) return a.coverage > b.coverage end)
    for i = #out, 121, -1 do out[i] = nil end
    return out
end

return m
