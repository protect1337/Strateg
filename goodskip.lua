local m = {}

function m.assess(s,c,routes,los,elapsed,spots,funded)
    local wi=s.wave
    local nextWave=c.forecast.wave(wi+1)
    local current=c.forecast.wave(wi)
    if not nextWave or not current then return {allowed=false,reason="last_or_setup"} end
    local speed=math.max(0.01,s.speed or 1)
    local delay=s.timerRemaining
    if type(delay)~="number" or delay<2 then return {allowed=false,reason="no_time_saved",delay=delay} end
    if elapsed==nil then return {allowed=false,reason="unknown_wave_age"} end
    if current.unknown>0 or nextWave.unknown>0 then return {allowed=false,reason="unknown_enemy"} end
    local bonus=c.economy.bonus(wi+1)
    local best=nil
    local threat=0
    for _,e in pairs(s.enemies) do threat+=e.hp+(e.shield or 0) end
    local reserve=math.max(20,s.lives*0.20)
    local horizon=0
    local worstLoss,waitLoss,winTime,waitTime=0,0,0,0
    for idx,r in pairs(routes) do
        local longest=0
        for _,g in ipairs(nextWave.groups) do
            longest=math.max(longest,g.last+r.length/math.max(0.1,g.speed))
        end
        horizon=math.min(300,math.max(35,longest+delay+5))
        local live=c.forecast.scenario(s,routes,wi,elapsed,horizon,idx,true)
        local now=c.forecast.scenario(live,routes,wi+1,-0.5*speed,horizon,idx,true)
        local later=c.forecast.scenario(live,routes,wi+1,-delay,horizon,idx,true)
        local a,b
        if best then
            a=table.clone(best)
            b=table.clone(best)
            local build=(1.5+(best.buildDelay or 0))*speed
            a.at=build
            b.at=best.price<=s.cash and build or delay+build
        end
        local fast=c.combat.run(now,routes,c.physics,los,a,horizon)
        local slow=c.combat.run(later,routes,c.physics,los,b,horizon)
        local risk=nextWave.complex and 1.35 or 1.15
        worstLoss=math.max(worstLoss,(fast.leaks+fast.remaining+fast.remainingShield+fast.unknown)*risk)
        waitLoss=math.max(waitLoss,slow.leaks+slow.remaining+slow.remainingShield+slow.unknown)
        winTime=math.max(winTime,fast.finish)
        waitTime=math.max(waitTime,slow.finish)
        if worstLoss>=s.lives-reserve then break end
    end
    local saved=waitTime-winTime
    local allowed=worstLoss<=0.01 and waitLoss<=0.01 and saved>0.8
    local buy
    if best then
        buy={kind=best.kind,id=best.id,path=best.path,levels=best.levels,path1=best.stats.path1,path2=best.stats.path2,price=best.price,pos=best.pos and c.physics.pack(best.pos)}
    end
    return {allowed=allowed,reason=allowed and "zero_loss_skip" or "risk_or_no_gain",predictedLoss=worstLoss,waitLoss=waitLoss,saved=saved,savedReal=saved/speed,delay=delay,bonus=bonus,purchase=buy,threat=threat,lives=s.lives,horizon=horizon}
end

return m
