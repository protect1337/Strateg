local m = {}

function m.vec(v)
    return Vector3.new(v.x, v.y, v.z)
end

function m.pack(v)
    return {x = v.X, y = v.Y, z = v.Z}
end

function m.routes(path, team, indices)
    local routes = {}
    for _, idx in ipairs(indices or {}) do
        local node = path.GetSpawn(idx, team)
        local points = {}
        local lengths = {}
        local total = 0
        local seen = {}
        while node and not seen[node] do
            seen[node] = true
            local p = node:GetPosition()
            if #points > 0 then
                total += (p - points[#points]).Magnitude
            end
            table.insert(points, p)
            table.insert(lengths, total)
            if node:IsEnd() then break end
            node = node:GetNext(idx)
        end
        if #points > 1 and total > 0 then
            routes[idx] = {points = points, lengths = lengths, length = total}
        end
    end
    return routes
end

function m.at(r, d)
    d = math.clamp(d, 0, r.length)
    for i = 2, #r.points do
        if d <= r.lengths[i] then
            local len = r.lengths[i] - r.lengths[i - 1]
            return r.points[i - 1]:Lerp(r.points[i], len > 0 and (d - r.lengths[i - 1]) / len or 0)
        end
    end
    return r.points[#r.points]
end

function m.project(r, p)
    local best = math.huge
    local dist = 0
    for i = 2, #r.points do
        local a = r.points[i - 1]
        local d = r.points[i] - a
        local dot = d:Dot(d)
        local t = dot > 0 and math.clamp((p - a):Dot(d) / dot, 0, 1) or 0
        local err = (p - a - d * t).Magnitude
        if err < best then
            best = err
            dist = r.lengths[i - 1] + t * d.Magnitude
        end
    end
    return dist
end

function m.los(map)
    local p = RaycastParams.new()
    p.FilterType = Enum.RaycastFilterType.Include
    p.FilterDescendantsInstances = map.GetLOSInstances()
    p.IgnoreWater = true
    local cache = {}
    return function(a, b)
        local key = string.format("%.1f:%.1f:%.1f:%.1f:%.1f:%.1f", a.X, a.Y, a.Z, b.X, b.Y, b.Z)
        if cache[key] ~= nil then return cache[key] end
        local from = a + Vector3.new(0, 1.6, 0)
        local to = b + Vector3.new(0, 1, 0)
        local clear = workspace:Raycast(from, to - from, p) == nil
        cache[key] = clear
        return clear
    end
end

return m
