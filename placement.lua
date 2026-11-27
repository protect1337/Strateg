local m={}

function m.candidates(routes,physics,placement,ranger,team,snapshot,los)
    local step=(ranger.config.Radius or 1.5)*2+0.05
    local dz=step*math.sqrt(3)/2
    local seen={}
    local out={}
    local samples={}
    local checks=0
    for idx,r in pairs(routes) do
        local points={}
        for d=0,r.length,2 do
            points[#points+1]={pos=physics.at(r,d),d=d}
        end
        samples[idx]=points
    end
    for _,r in pairs(routes) do
        for d=0,r.length,4 do
            local p=physics.at(r,d)
            local z0=math.floor((p.Z-12)/dz)
            local z1=math.ceil((p.Z+12)/dz)
            for row=z0,z1 do
                local shift=row%2*step/2
                local x0=math.floor((p.X-12-shift)/step)
                local x1=math.ceil((p.X+12-shift)/step)
                for col=x0,x1 do
                    local x=col*step+shift
                    local z=row*dz
                    local k=row..":"..col
                    if not seen[k] and (x-p.X)^2+(z-p.Z)^2<=144 then
                        seen[k]=true
                        checks+=1
                        if checks%100==0 then task.wait() end
                        local y=placement.GetGroundHeightAtXZ(x,z,p.Y)
                        if type(y)=="number" then
                            local pos=Vector3.new(x,y,z)
                            if placement.Check(pos,ranger.config,team) then
                                local first=math.huge
                                local early,total,up=0,0,0
                                for _,points in pairs(samples) do
                                    for _,q in ipairs(points) do
                                        local dist=(q.pos-pos).Magnitude
                                        if dist<=16 and los(pos,q.pos) then
                                            up+=2
                                            if dist<=9 then
                                                total+=2
                                                early+=2/(1+q.d/24)^2
                                                first=math.min(first,q.d)
                                            end
                                        end
                                    end
                                end
                                if total>0 then out[#out+1]={pos=pos,coverage=early+up*0.025,total=total,first=first,grid=k} end
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(out,function(a,b) return a.coverage>b.coverage end)
    local result={}
    local used={}
    for i=1,math.min(180,#out) do result[#result+1]=out[i] used[out[i].grid]=true end
    table.sort(out,function(a,b) return a.total>b.total end)
    for _,v in ipairs(out) do
        if not used[v.grid] then
            result[#result+1]=v
            used[v.grid]=true
            if #result>=360 then break end
        end
    end
    table.sort(result,function(a,b) return a.coverage>b.coverage end)
    return result
end
return m
