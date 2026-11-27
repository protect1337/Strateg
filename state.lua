local m = {}

local function freeze(t)
    for _, v in pairs(t) do
        if type(v) == "table" and not table.isfrozen(v) then
            freeze(v)
        end
    end
    return table.freeze(t)
end

function m.new()
    local current
    local rev = 0
    local changed = Instance.new("BindableEvent")

    local s = {}

    function s.get()
        return current
    end

    function s.publish(snap)
        rev += 1
        snap.revision = rev
        current = freeze(snap)
        changed:Fire(current)
        return current
    end

    function s.subscribe(fn)
        return changed.Event:Connect(fn)
    end

    return s
end

return m
