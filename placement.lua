local m = {}

function m.candidates(routes, physics, placement, ranger, team, snapshot, los)
    local out = {}
    local seen = {}
    local limit = 180
    for _, r in pairs(routes) do
        local step = math.max(4, r.length / 28)
        for d = 0, r.length, step do
            local p = physics.at(r, d)
            for _, radius in ipairs({4, 7, 10}) do
                for i = 0, 7 do
                    local angle = i * math.pi / 4
                    local x = math.round((p.X + radius * math.cos(angle)) / 2) * 2
                    local z = math.round((p.Z + radius * math.sin(angle)) / 2) * 2
                    local key = tostring(x) .. ":" .. tostring(z)
                    if not seen[key] and #out < limit then
                        seen[key] = true
                        local y = placement.GetGroundHeightAtXZ(x, z, p.Y)
                        local pos = Vector3.new(x, y, z)
                        if placement.Check(pos, ranger.config, team) then
                            local score = 0
                            for _, route in pairs(routes) do
                                for at = 0, route.length, 3 do
                                    local q = physics.at(route, at)
                                    if (q - pos).Magnitude <= 9 and los(pos, q) then
                                        score += 3
                                    end
                                end
                            end
                            if score > 0 then
                                table.insert(out, {pos = pos, coverage = score})
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.coverage > b.coverage end)
    return out
end

return m
