local m={}

function m.new(c)
    local x={}
    local lastTarget=-math.huge
    local lastRecycle=-math.huge
    local lastMap
    local replaced={}
    local cache={}

    local function routeSamples(r)
        if cache[r] then return cache[r] end
        local out={}
        for d=0,r.length,2 do out[#out+1]={d=d,pos=c.physics.at(r,d)} end
        out[#out+1]={d=r.length,pos=c.physics.at(r,r.length)}
        cache[r]=out
        return out
    end

    local function reach(pos,range,q,los,back,slice)
        local seconds=0
        local first=math.huge
        local speed=math.max(0.1,q.speed or q.e.speed or 0)
        local d0=math.max(0,q.d-(back or 0))
        for i,p in ipairs(routeSamples(q.r)) do
            if slice and i%32==0 then slice() end
            if p.d>=d0 and (p.pos-pos).Magnitude<=range and los(pos,p.pos) then
                seconds+=2/speed
                first=math.min(first,math.max(0,p.d-q.d)/speed)
            end
        end
        return seconds,first
    end

    function x.reach(pos,range,q,los,back)
        return reach(pos,range,q,los,back)
    end

    function x.target(s,ts,los,slice)
        if s.time-lastTarget<0.25 or #ts==0 then return end
        lastTarget=s.time
        local targets={}
        local assigned={}
        for _,t in pairs(s.towers) do
            if slice then slice() end
            if t.target then assigned[t.target]=(assigned[t.target] or 0)+(t.damage or 0)/math.max(0.15,t.reload or 1) end
        end
        for _,t in pairs(s.towers) do
            if slice then slice() end
            if t.owned and t.type=="Ranger" and not t.attackDisabled and not t.stunned and t.query~=nil then
                local pos=c.physics.vec(t.pos)
                local choices={}
                local scores={}
                local st=c.ranger.stats(t.path1,t.path2)
                for _,q in ipairs(ts) do
                    if slice then slice() end
                    local e=q.e
                    if not e.air and not e.invulnerable and not e.untargetable and not e.noDamage and not e.stasis and (not e.stealth or t.stealthDetection) then
                        local p=c.physics.vec(e.pos or e.pathPos)
                        if (p-pos).Magnitude<=t.range and los(pos,p) then
                            local hp=e.hp+(e.shield or 0)
                            local order={q.d/q.r.length,-q.d/q.r.length,hp,-hp}
                            for i,k in ipairs(order) do
                                if not scores[i] or k>scores[i] then scores[i]=k choices[i]=q end
                            end
                        end
                    end
                end
                local function score(q)
                    if not q then return 0 end
                    local e=q.e
                    local hp=e.hp+(e.shield or 0)
                    local power=st.dps*(st.ignoreResistance and 1 or 1-math.clamp((e.resist or {})[tostring(st.damageType)] or 0,0,1))
                    local urgency=e.hp/math.max(1,q.eta)
                    local fatal=e.hp>=s.lives and 4 or 1
                    local boss=(e.type=="Plague Doctor" or e.name=="Plague Doctor") and 2 or 1
                    local support=math.max(0,(assigned[q.id] or 0)-(t.target==q.id and power or 0))
                    local spare=math.max(0,hp-support*math.min(8,q.eta))
                    local useful=math.min(hp,power*math.min(6,q.eta))
                    return useful*(1+urgency*0.03)*fatal*boss*(0.2+0.8*spare/math.max(1,hp))
                end
                local current=choices[(t.query or 0)+1]
                for _,q in ipairs(ts) do if q.id==t.target then current=q break end end
                local old=score(current)
                for i,q in pairs(choices) do
                    local v=score(q)
                    if i-1~=t.query and (not current or current.id~=q.id) and v>old*1.35+5 then
                        targets[#targets+1]={kind="target",id=t.id,query=i-1,target=q.id,gain=v-old}
                    end
                end
            end
        end
        table.sort(targets,function(a,b) return a.gain>b.gain end)
        return targets
    end

    function x.recycle(s,ts,los,slice)
        if s.time-lastRecycle<0.35 or #ts==0 then return end
        lastRecycle=s.time
        local w=c.forecast.wave(s.wave)
        if not w or s.wave~=#c.economy.config.Waves or not s.waveAge or s.waveAge<w.last+1 then return end
        for _,e in pairs(s.enemies) do if e.reverse then return end end
        local best
        for id,t in pairs(s.towers) do
            if slice then slice() end
            if t.owned and t.type=="Ranger" and (t.sellValue or 0)>0 and c.executor.available({kind="sell",id=id}) then
                local st=c.ranger.stats(t.path1,t.path2)
                local pos=c.physics.vec(t.pos)
                local useful=t.target~=nil and s.enemies[t.target]~=nil
                for _,q in ipairs(ts) do
                    if slice then slice() end
                    if not q.e.air and (not q.e.stealth or st.stealthDetection) then
                        local boss=q.e.type=="Plague Doctor" or q.e.name=="Plague Doctor"
                        local seconds=reach(pos,st.range,q,los,boss and 20 or 0,slice)
                        if seconds>0 then useful=true break end
                    end
                end
                if not useful and (not best or t.sellValue>best.refund) then
                    best={kind="sell",id=id,refund=t.sellValue,reason="final_wave_no_remaining_target"}
                end
            end
        end
        return best
    end

    function x.rebuild(s,ts,los,slice)
        if s.wave~=#c.economy.config.Waves then return end
        local best
        for id,t in pairs(s.towers) do
            if slice then slice() end
            if t.owned and t.type=="Ranger" and t.sellValue and next(t.debuffs or {}) and c.executor.available({kind="sell",id=id}) then
                local st=c.ranger.stats(t.path1,t.path2)
                local pos=c.physics.vec(t.pos)
                local key=string.format("%.1f:%.1f:%.1f",pos.X,pos.Y,pos.Z)
                if s.time-(replaced[key] or -math.huge)<10 then continue end
                local cost=st.cost-t.sellValue
                if s.cash<cost or s.cash+t.sellValue<st.cost or t.debuffs.PlagueDoctorSmokeDebuff then continue end
                local left=0
                for name,b in pairs(t.debuffs) do
                    if name~="PlagueDoctorSmokeDebuff" then left=math.max(left,b.remaining or 0) end
                end
                local delay=(0.8+(t.path1>0 and 0.25 or 0)+(t.path2>0 and 0.25 or 0))*(s.speed or 1)
                if left<=delay+1 then continue end
                for _,q in ipairs(ts) do
                    if slice then slice() end
                    if q.e.boss and q.e.hp>7500 and not q.e.air and (not q.e.stealth or st.stealthDetection) then
                        local clean,first=reach(pos,st.range,q,los,0,slice)
                        local weak=reach(pos,t.range,q,los,0,slice)
                        local effective=t.stunned and 0 or st.dps*math.max(0,1+(t.buffDamageMultiplier or 0))*math.max(0,1+(t.fireMultiplier or 0))
                        local gained=st.dps*math.max(0,math.min(clean,left-first)-delay)-effective*math.min(weak,left)
                        if gained>math.max(30,cost*0.03) and (not best or gained>best.gain) then
                            best={kind="sell",id=id,reason="debuff_replacement",gain=gained,refund=t.sellValue,goal={pos=t.pos,path1=t.path1,path2=t.path2,live=true},key=key}
                        end
                    end
                end
            end
        end
        if best then replaced[best.key]=s.time best.key=nil end
        return best
    end

    function x.reset(map)
        if map~=lastMap then cache={} replaced={} lastMap=map end
    end
    return x
end
return m
