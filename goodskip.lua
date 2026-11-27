local m={}
function m.assess(s,c,routes,los,elapsed,spots,funded,search,rollout)
    if not search or not rollout then return {allowed=false,reason="no_continuation"} end
    return search.compareSkips(s,rollout)
end
return m
