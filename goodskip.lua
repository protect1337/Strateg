local m = {}

function m.assess(s,c,routes,los,elapsed,spots)
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
    local best
    local score=0
    local function consider(a,st,pos,old)
        if a.price>s.cash+bonus then return end
        local gain=st.dps-(old and old.dps or 0)
        if st.ignoreResistance and not (old and old.ignoreResistance) and nextWave.armorHp>0 then gain+=st.dps*0.8 end
        if st.stealthDetection and not (old and old.stealthDetection) and nextWave.stealthHp>0 then gain+=st.dps*2 end
        if st.path2>=4 and (not old or old.path2<st.path2) then gain+=8 end
        local early=math.huge
        for _,r in pairs(routes) do
            for d=0,r.length,4 do
                local p=c.physics.at(r,d)
                if (p-pos).Magnitude<=st.range and los(pos,p) then early=math.min(early,d) break end
            end
        end
        local rank=gain/(1+early/18)/math.max(1,a.price)^0.65
        if rank>score then score=rank best=a end
    end
    for id,t in pairs(s.towers) do
        if t.owned and t.type=="Ranger" then
            local old=c.ranger.stats(t.path1,t.path2)
            for _,u in ipairs(c.ranger.upgrades(t)) do
                consider({kind="upgrade",id=id,path=u.path,stats=u,price=u.price},u,c.physics.vec(t.pos),old)
            end
        end
    end
    if s.towerCount<(s.towerLimit or 0) then
        local st=c.ranger.stats(0,0)
        for i=1,math.min(3,#spots) do
            local p=spots[i].pos
            consider({kind="place",pos=p,stats=st,price=st.cost},st,p)
        end
    end
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
        horizon=math.min(180,math.max(35,longest+delay+3))
        local live=c.forecast.scenario(s,routes,wi,elapsed,horizon,idx,true)
        local now=c.forecast.scenario(live,routes,wi+1,-0.5*speed,horizon,idx,true)
        local later=c.forecast.scenario(live,routes,wi+1,-delay,horizon,idx,true)
        local a,b
        if best then
            a=table.clone(best)
            b=table.clone(best)
            a.at=1.5*speed
            b.at=best.price<=s.cash and 1.5*speed or delay+1.5*speed
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
    local allowed=worstLoss<s.lives-reserve and (saved>0.8 or worstLoss+5<waitLoss) and worstLoss<=waitLoss+math.max(15,s.lives*0.12)
    local buy
    if best then
        buy={kind=best.kind,id=best.id,path=best.path,price=best.price,pos=best.pos and c.physics.pack(best.pos)}
    end
    return {allowed=allowed,reason=allowed and "economic_skip" or "risk_or_no_gain",predictedLoss=worstLoss,waitLoss=waitLoss,saved=saved,savedReal=saved/speed,delay=delay,bonus=bonus,purchase=buy,threat=threat,lives=s.lives,horizon=horizon}
end

return m
