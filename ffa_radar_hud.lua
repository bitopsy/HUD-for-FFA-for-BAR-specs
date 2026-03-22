-- ffa_radar_hud.lua
-- Beyond All Reason — Spectator FFA radar HUD
-- Axes: M/s, E/s, BP, MP (metal stored), AV (army value), Dmg (damage dealt), DV (defense value)
-- Place in: Beyond All Reason/LuaUI/Widgets/

function widget:GetInfo()
    return {
        name    = "FFA Radar HUD",
        desc    = "Spectator radar/nightingale/scatter HUD for top 2-6 FFA players — v2.4",
        author  = "goddot",
        date    = "2026",
        license = "GNU GPL v2",
        layer   = 0,
        enabled = true,
    }
end

-- ─── Config ───────────────────────────────────────────────────────────────────

local CFG = {
    cx             = 0,
    cy             = 0,
    radius         = 220,
    rings          = 4,
    maxPlayers     = 6,
    minPlayers     = 2,
    bgAlpha        = 0.55,
    lineAlpha      = 0.85,
    fontSize       = 14,
    labelOffset    = 28,
    updateInterval = 1.0,
    trailMaxLen    = 12,   -- number of historical snapshots kept per player
    trailInterval  = 2.0,  -- seconds between trail snapshots
}

-- ─── Obfuscated credit ───────────────────────────────────────────────────────
local _ac = { 0x67,0x6f,0x64,0x64,0x6f,0x74 }
local function _da()
    local s = {}
    for _, b in ipairs(_ac) do s[#s+1] = string.char(b) end
    return table.concat(s)
end

-- ─── Vis mode ────────────────────────────────────────────────────────────────
-- 1 = radar lines  2 = nightingale rose  3 = scatter + trail
local visMode     = 1
local MODE_LABELS = { "Lines", "Rose", "Scatter" }

-- Button at bottom-right corner of chart bounding box
local BTN = { x=0, y=0, w=68, h=20 }

-- ─── Player colours ───────────────────────────────────────────────────────────

local PLAYER_COLORS = {
    { 0.20, 0.35, 1.00, 1.0 },
    { 0.15, 0.85, 0.75, 1.0 },
    { 0.70, 0.20, 0.90, 1.0 },
    { 0.80, 0.72, 0.05, 1.0 },
    { 0.95, 0.15, 0.15, 1.0 },
    { 0.15, 0.85, 0.25, 1.0 },
}

-- ─── Axes ─────────────────────────────────────────────────────────────────────

local AXES = {
    { label = "M/s", key = "metalIncome"  },
    { label = "E/s", key = "energyIncome" },
    { label = "BP",  key = "bp"           },
    { label = "MP",  key = "metalStored"  },
    { label = "AV",  key = "armyValue"    },
    { label = "Dmg", key = "dmgDealt"     },
    { label = "DV",  key = "defenseValue" },
}
local NUM_AXES = #AXES

-- ─── Spring API locals ────────────────────────────────────────────────────────

local spGetAllUnits        = Spring.GetAllUnits
local spGetUnitDefID       = Spring.GetUnitDefID
local spGetUnitTeam        = Spring.GetUnitTeam
local spGetUnitHealth      = Spring.GetUnitHealth
local spGetTeamResources   = Spring.GetTeamResources
local spGetTeamDamageStats = Spring.GetTeamDamageStats
local spGetTeamList        = Spring.GetTeamList
local spGetPlayerList      = Spring.GetPlayerList
local spGetPlayerInfo      = Spring.GetPlayerInfo
local spGetTeamInfo        = Spring.GetTeamInfo

local glColor      = gl.Color
local glVertex     = gl.Vertex
local glBeginEnd   = gl.BeginEnd
local glText       = gl.Text
local GL_LINE_LOOP = GL.LINE_LOOP
local GL_LINES     = GL.LINES
local GL_POLYGON   = GL.POLYGON

local msin   = math.sin
local mcos   = math.cos
local mpi    = math.pi
local mfloor = math.floor
local mmax   = math.max

-- ─── Unit def cache ───────────────────────────────────────────────────────────

local udCache = {}

local function classifyUnitDefs()
    for udid, ud in pairs(UnitDefs) do
        local cost = ud.metalCost or 0
        local isBP, isArmy, isDef, isCmd = false, false, false, false
        local bp = 0
        if ud.buildSpeed and ud.buildSpeed > 0 then isBP = true; bp = ud.buildSpeed end
        local cp = ud.customParams
        if cp and (cp.unitGroup == "commander" or cp.iscommander == "1") then
            isCmd = true
        elseif ud.name and ud.name:lower():find("commander") then
            isCmd = true
        end
        local canAttack = ud.weapons and #ud.weapons > 0
        local isStatic  = (not ud.canMove) or (ud.speed == 0)
        if canAttack and isStatic and not isBP then isDef  = true end
        if canAttack and ud.canMove and ud.speed and ud.speed > 0 then isArmy = true end
        if cost > 0 and (isBP or isArmy or isDef or isCmd) then
            udCache[udid] = { cost=cost, isBP=isBP, isArmy=isArmy,
                              isDef=isDef, bp=bp, isCmd=isCmd }
        end
    end
end

-- ─── State ────────────────────────────────────────────────────────────────────

local screenW    = 1280
local screenH    = 768
local timer      = 0
local trailTimer = 0

local playerData = {}
local axisMax    = {}
for i = 1, NUM_AXES do axisMax[i] = 1 end

-- Scatter trail: keyed by teamID → array of {x,y} snapshots (oldest first)
local scatterTrail = {}

-- ─── Geometry helpers ─────────────────────────────────────────────────────────

local function axisPoint(i, r)
    local angle = (2 * mpi * (i - 1) / NUM_AXES) - mpi / 2
    return CFG.cx + mcos(angle) * r,
           CFG.cy + msin(angle) * r
end

local function edgeMidPoint(i, r)
    local a1   = (2 * mpi * (i - 1) / NUM_AXES) - mpi / 2
    local a2   = (2 * mpi * (i     ) / NUM_AXES) - mpi / 2
    local aMid = (a1 + a2) / 2
    return CFG.cx + mcos(aMid) * r,
           CFG.cy + msin(aMid) * r,
           aMid
end

-- ─── Data collection ──────────────────────────────────────────────────────────

local function getActivePlayers()
    local teams = spGetTeamList()
    if not teams then return {} end
    local result = {}
    for _, tid in ipairs(teams) do
        local tInfo  = { spGetTeamInfo(tid) }
        local isDead = tInfo and tInfo[1] ~= nil and tInfo[3]
        if not isDead then
            local name    = "Team " .. tid
            local players = spGetPlayerList(tid, false) or {}
            if #players > 0 then
                local n = spGetPlayerInfo(players[1], false)
                if n then name = n end
            end
            local r, g, b = Spring.GetTeamColor(tid)
            local col = (r and g and b) and { r, g, b, 1.0 }
                        or PLAYER_COLORS[((#result) % #PLAYER_COLORS) + 1]
            result[#result + 1] = {
                teamID = tid, name = name, color = col,
                stats  = { metalIncome=0, energyIncome=0, bp=0,
                           metalStored=0, armyValue=0, dmgDealt=0, defenseValue=0 },
            }
        end
    end
    return result
end

local function collectStats(pd)
    local teamBP={} local teamArmy={} local teamCmd={} local teamDef={}
    local units = spGetAllUnits()
    for i = 1, #units do
        local uid  = units[i]
        local tid  = spGetUnitTeam(uid)
        local info = udCache[spGetUnitDefID(uid)]
        if info then
            local hp, maxHp = spGetUnitHealth(uid)
            local frac = (hp and maxHp and maxHp > 0) and (hp/maxHp) or 1.0
            teamBP[tid]   = (teamBP[tid]   or 0) + (info.isBP   and info.bp                  or 0)
            teamArmy[tid] = (teamArmy[tid]  or 0) + (info.isArmy and mfloor(info.cost * frac) or 0)
            teamDef[tid]  = (teamDef[tid]   or 0) + (info.isDef  and mfloor(info.cost * frac) or 0)
            if info.isCmd then teamCmd[tid] = (teamCmd[tid] or 0) + 1 end
        end
    end
    for _, p in ipairs(pd) do
        local tid = p.teamID
        local mCur, _, _, mInc = spGetTeamResources(tid, "metal")
        local _,   _, _, eInc  = spGetTeamResources(tid, "energy")
        local dmgDealt = 0
        if spGetTeamDamageStats then
            local d = spGetTeamDamageStats(tid)
            if d then dmgDealt = d end
        end
        p.stats.metalIncome  = mfloor((mInc or 0) * 10) / 10
        p.stats.energyIncome = mfloor((eInc or 0) * 10) / 10
        p.stats.bp           = mfloor(teamBP[tid]  or 0)
        p.stats.metalStored  = mfloor(mCur         or 0)
        p.stats.armyValue    = teamArmy[tid]        or 0
        p.stats.dmgDealt     = mfloor(dmgDealt)
        p.stats.defenseValue = teamDef[tid]         or 0
        p.cmdCount           = teamCmd[tid]         or 0
    end
end

local function updateAxisMaxima(pd)
    for ai, ax in ipairs(AXES) do
        local m = 1
        for _, p in ipairs(pd) do
            local v = p.stats[ax.key] or 0
            if v > m then m = v end
        end
        axisMax[ai] = m
    end
end

local function sortAndTrim(pd)
    table.sort(pd, function(a, b)
        return (a.stats.armyValue or 0) > (b.stats.armyValue or 0)
    end)
    local keep = mmax(5, #pd)
    if keep > CFG.maxPlayers then keep = CFG.maxPlayers end
    while #pd > keep do table.remove(pd) end
end

local function refreshData()
    local pd = getActivePlayers()
    if #pd < CFG.minPlayers then playerData = pd; return end
    collectStats(pd)
    sortAndTrim(pd)
    updateAxisMaxima(pd)
    playerData = pd
end

-- ─── Trail snapshot ───────────────────────────────────────────────────────────

local SCATTER_X_KEY = "armyValue"
local SCATTER_Y_KEY = "metalIncome"
local SCATTER_X_AX  = 5
local SCATTER_Y_AX  = 1

local function snapshotTrail()
    local maxX = axisMax[SCATTER_X_AX] or 1
    local maxY = axisMax[SCATTER_Y_AX] or 1
    local R    = CFG.radius * 0.88
    for _, p in ipairs(playerData) do
        local tid = p.teamID
        if not scatterTrail[tid] then scatterTrail[tid] = {} end
        local trail = scatterTrail[tid]
        local nx = maxX > 0 and ((p.stats[SCATTER_X_KEY] or 0) / maxX) or 0
        local ny = maxY > 0 and ((p.stats[SCATTER_Y_KEY] or 0) / maxY) or 0
        if nx > 1 then nx = 1 end
        if ny > 1 then ny = 1 end
        trail[#trail+1] = {
            x = CFG.cx + (nx * 2 - 1) * R,
            y = CFG.cy + (ny * 2 - 1) * R,
        }
        while #trail > CFG.trailMaxLen do table.remove(trail, 1) end
    end
end

-- ─── Drawing: shared grid / labels ───────────────────────────────────────────

local function drawGrid()
    for ring = 1, CFG.rings do
        local r = CFG.radius * ring / CFG.rings
        glColor(1,1,1, 0.12)
        glBeginEnd(GL_LINE_LOOP, function()
            for i = 1, NUM_AXES do
                local ax,ay = axisPoint(i,r)
                glVertex(ax,ay)
            end
        end)
    end
    glColor(1,1,1, 0.18)
    for i = 1, NUM_AXES do
        local ax,ay = axisPoint(i, CFG.radius)
        glBeginEnd(GL_LINES, function()
            glVertex(CFG.cx, CFG.cy)
            glVertex(ax, ay)
        end)
    end
    glColor(1,1,1, 0.35)
    glBeginEnd(GL_LINE_LOOP, function()
        for i = 1, NUM_AXES do
            local ax,ay = axisPoint(i, CFG.radius)
            glVertex(ax,ay)
        end
    end)
end

local function drawAxisLabels()
    local lo = CFG.labelOffset
    for i, ax in ipairs(AXES) do
        local lx,ly = axisPoint(i, CFG.radius + lo)
        glColor(0.88, 0.90, 0.95, 1.0)
        glText(ax.label, lx, ly, CFG.fontSize, "oc")
    end
end

local function drawScaleLabels()
    local nudge = 5
    for ai = 1, NUM_AXES do
        local angle = (2*mpi*(ai-1)/NUM_AXES) - mpi/2
        local px = -msin(angle)*nudge
        local py =  mcos(angle)*nudge
        for ring = 1, CFG.rings do
            local frac = ring/CFG.rings
            local r    = CFG.radius * frac
            local sx   = CFG.cx + mcos(angle)*r + px
            local sy   = CFG.cy + msin(angle)*r + py
            local maxV = axisMax[ai] or 1
            local val  = maxV * frac
            local label
            if     val >= 10000 then label = string.format("%.0fk", val/1000)
            elseif val >= 1000  then label = string.format("%.1fk", val/1000)
            elseif val >= 10    then label = string.format("%.0f",  val)
            else                     label = string.format("%.1f",  val)
            end
            glColor(0,0,0, 0.65)
            glText(label, sx+1, sy-1, 8, "oc")
            glColor(0.75,0.78,0.82, 0.90)
            glText(label, sx, sy, 8, "oc")
        end
    end
end

-- ─── Drawing: radar polygon ───────────────────────────────────────────────────

local function drawPlayerPolygon(p, colorAlpha)
    local col = p.color
    glColor(col[1],col[2],col[3], 0.10)
    glBeginEnd(GL_POLYGON, function()
        for ai, ax in ipairs(AXES) do
            local val  = p.stats[ax.key] or 0
            local norm = axisMax[ai] > 0 and (val/axisMax[ai]) or 0
            if norm > 1 then norm = 1 end
            local px,py = axisPoint(ai, norm*CFG.radius)
            glVertex(px,py)
        end
    end)
    glColor(col[1],col[2],col[3], colorAlpha)
    gl.LineWidth(2.0)
    glBeginEnd(GL_LINE_LOOP, function()
        for ai, ax in ipairs(AXES) do
            local val  = p.stats[ax.key] or 0
            local norm = axisMax[ai] > 0 and (val/axisMax[ai]) or 0
            if norm > 1 then norm = 1 end
            local px,py = axisPoint(ai, norm*CFG.radius)
            glVertex(px,py)
        end
    end)
    gl.LineWidth(1.0)
    for ai, ax in ipairs(AXES) do
        local val  = p.stats[ax.key] or 0
        local norm = axisMax[ai] > 0 and (val/axisMax[ai]) or 0
        if norm > 1 then norm = 1 end
        local px,py = axisPoint(ai, norm*CFG.radius)
        glColor(col[1],col[2],col[3], 1.0)
        glBeginEnd(GL_POLYGON, function()
            for s=0,7 do
                local a = s*mpi/4
                glVertex(px+mcos(a)*4, py+msin(a)*4)
            end
        end)
    end
end

-- ─── Drawing: Nightingale rose (split per-axis wedge chart) ──────────────────
--
-- Each of the NUM_AXES axes owns an equal angular wedge of the full circle.
-- Within a wedge, each player is drawn as a concentric arc band whose
-- radial thickness is proportional to their normalised value on that axis.
-- Bands are stacked from the outside inward, largest value outermost.
-- Thick dark radial lines act as dividers between axes.

local ROSE_GAP_DEG  = 4      -- degrees of blank gap at each wedge boundary
local PLAYER_GAP_PX = 2      -- px gap between successive player bands
local ARC_STEPS     = 26     -- polygon resolution per arc

local function drawNightingaleRose()
    local n = #playerData
    if n == 0 then return end

    local wedgeAngle = 2*mpi / NUM_AXES
    local gapR       = ROSE_GAP_DEG * mpi / 180

    for ai, ax in ipairs(AXES) do
        local baseAngle = (2*mpi*(ai-1)/NUM_AXES) - mpi/2
        local a1 = baseAngle - wedgeAngle/2 + gapR/2
        local a2 = baseAngle + wedgeAngle/2 - gapR/2

        -- Sort players by value on this axis, descending
        local sorted = {}
        for _, p in ipairs(playerData) do sorted[#sorted+1] = p end
        table.sort(sorted, function(a,b)
            return (a.stats[ax.key] or 0) > (b.stats[ax.key] or 0)
        end)

        -- Compute band thicknesses proportional to each player's normalised value
        local maxVal     = axisMax[ai] or 1
        local totalThick = 0
        local thick      = {}
        for _, p in ipairs(sorted) do
            local v    = p.stats[ax.key] or 0
            local norm = maxVal > 0 and (v/maxVal) or 0
            if norm > 1 then norm = 1 end
            local t = norm * CFG.radius
            thick[p.teamID] = t
            totalThick = totalThick + t
        end

        -- Scale so total bands + gaps fit within CFG.radius
        local totalGap = (n - 1) * PLAYER_GAP_PX
        local scale    = (totalThick > 0)
                         and math.min(1, (CFG.radius - totalGap) / totalThick)
                         or  1

        -- Draw from outermost ring inward
        local outerR = CFG.radius
        for _, p in ipairs(sorted) do
            local t      = thick[p.teamID] * scale
            local innerR = outerR - t
            if innerR < 2 then innerR = 2 end

            local col = p.color

            -- Filled annular sector
            glColor(col[1],col[2],col[3], 0.80)
            glBeginEnd(GL_POLYGON, function()
                for s=0,ARC_STEPS do
                    local ang = a1 + (a2-a1)*s/ARC_STEPS
                    glVertex(CFG.cx + mcos(ang)*outerR, CFG.cy + msin(ang)*outerR)
                end
                for s=ARC_STEPS,0,-1 do
                    local ang = a1 + (a2-a1)*s/ARC_STEPS
                    glVertex(CFG.cx + mcos(ang)*innerR, CFG.cy + msin(ang)*innerR)
                end
            end)

            -- Soft bright rim on outer arc
            glColor(math.min(col[1]*1.3,1), math.min(col[2]*1.3,1), math.min(col[3]*1.3,1), 0.40)
            gl.LineWidth(1.2)
            glBeginEnd(GL_LINE_LOOP, function()
                for s=0,ARC_STEPS do
                    local ang = a1 + (a2-a1)*s/ARC_STEPS
                    glVertex(CFG.cx + mcos(ang)*outerR, CFG.cy + msin(ang)*outerR)
                end
                for s=ARC_STEPS,0,-1 do
                    local ang = a1 + (a2-a1)*s/ARC_STEPS
                    glVertex(CFG.cx + mcos(ang)*innerR, CFG.cy + msin(ang)*innerR)
                end
            end)
            gl.LineWidth(1.0)

            outerR = innerR - PLAYER_GAP_PX
        end

        -- Thick dark dividers between wedges
        glColor(0.04, 0.04, 0.06, 1.0)
        gl.LineWidth(3.5)
        glBeginEnd(GL_LINES, function()
            glVertex(CFG.cx, CFG.cy)
            glVertex(CFG.cx + mcos(a1)*CFG.radius, CFG.cy + msin(a1)*CFG.radius)
        end)
        glBeginEnd(GL_LINES, function()
            glVertex(CFG.cx, CFG.cy)
            glVertex(CFG.cx + mcos(a2)*CFG.radius, CFG.cy + msin(a2)*CFG.radius)
        end)
        gl.LineWidth(1.0)
    end

    -- Axis labels sit just outside the chart, same positions as Lines mode
    drawAxisLabels()
end

-- ─── Drawing: scatter + trail ─────────────────────────────────────────────────

local function drawScatter()
    -- Faint bounding frame
    glColor(1,1,1, 0.07)
    glBeginEnd(GL_LINE_LOOP, function()
        for i=1,NUM_AXES do
            local ax,ay = axisPoint(i, CFG.radius)
            glVertex(ax,ay)
        end
    end)
    glColor(1,1,1, 0.10)
    glBeginEnd(GL_LINES, function()
        glVertex(CFG.cx - CFG.radius, CFG.cy)
        glVertex(CFG.cx + CFG.radius, CFG.cy)
    end)
    glBeginEnd(GL_LINES, function()
        glVertex(CFG.cx, CFG.cy - CFG.radius)
        glVertex(CFG.cx, CFG.cy + CFG.radius)
    end)
    local fs = CFG.fontSize - 3
    glColor(0.75,0.78,0.82, 0.70)
    glText("→ AV",  CFG.cx + CFG.radius + 4, CFG.cy,                  fs, "ol")
    glText("↑ M/s", CFG.cx,                  CFG.cy + CFG.radius + 6,  fs, "oc")

    local R = CFG.radius * 0.88

    for _, p in ipairs(playerData) do
        local col   = p.color
        local tid   = p.teamID
        local trail = scatterTrail[tid] or {}
        local tSize = #trail

        -- Draw trail ghost circles, oldest (most transparent/small) first
        for ti = 1, tSize do
            local pt    = trail[ti]
            local frac  = ti / tSize          -- 0 = oldest, 1 = newest
            local alpha = frac * frac * 0.45  -- quadratic fade
            local tR    = 6 + frac * 9        -- grows toward present
            glColor(col[1],col[2],col[3], alpha)
            glBeginEnd(GL_POLYGON, function()
                for s=0,11 do
                    local a = s * mpi/6
                    glVertex(pt.x + mcos(a)*tR, pt.y + msin(a)*tR)
                end
            end)
        end

        -- Connect trail dots with a fading polyline
        if tSize > 1 then
            for ti = 1, tSize-1 do
                local frac  = ti / tSize
                local alpha = frac * 0.30
                glColor(col[1],col[2],col[3], alpha)
                gl.LineWidth(1.5)
                glBeginEnd(GL_LINES, function()
                    glVertex(trail[ti].x,   trail[ti].y)
                    glVertex(trail[ti+1].x, trail[ti+1].y)
                end)
            end
            gl.LineWidth(1.0)
        end

        -- Live position
        local maxX = axisMax[SCATTER_X_AX] or 1
        local maxY = axisMax[SCATTER_Y_AX] or 1
        local nx = maxX > 0 and ((p.stats[SCATTER_X_KEY] or 0)/maxX) or 0
        local ny = maxY > 0 and ((p.stats[SCATTER_Y_KEY] or 0)/maxY) or 0
        if nx > 1 then nx = 1 end
        if ny > 1 then ny = 1 end
        local bx    = CFG.cx + (nx*2 - 1)*R
        local by    = CFG.cy + (ny*2 - 1)*R
        local ballR = 14 + nx*8

        -- Outer glow
        glColor(col[1],col[2],col[3], 0.18)
        glBeginEnd(GL_POLYGON, function()
            for s=0,15 do
                local a = s*mpi/8
                glVertex(bx + mcos(a)*(ballR+6), by + msin(a)*(ballR+6))
            end
        end)
        -- Main ball
        glColor(col[1],col[2],col[3], 0.72)
        glBeginEnd(GL_POLYGON, function()
            for s=0,15 do
                local a = s*mpi/8
                glVertex(bx + mcos(a)*ballR, by + msin(a)*ballR)
            end
        end)
        -- Specular highlight
        glColor(1,1,1, 0.28)
        glBeginEnd(GL_POLYGON, function()
            glVertex(bx, by)
            for s=8,12 do
                local a = s*mpi/8
                glVertex(bx + mcos(a)*ballR*0.55, by + msin(a)*ballR*0.55)
            end
        end)
        -- Outline
        gl.LineWidth(1.5)
        glColor(col[1],col[2],col[3], 0.90)
        glBeginEnd(GL.LINE_LOOP, function()
            for s=0,15 do
                local a = s*mpi/8
                glVertex(bx + mcos(a)*ballR, by + msin(a)*ballR)
            end
        end)
        gl.LineWidth(1.0)

        -- Two-letter initials inside ball
        local initLabel = p.name:sub(1,2):upper()
        glColor(0,0,0, 0.70)
        glText(initLabel, bx+1, by-1, CFG.fontSize-1, "oc")
        glColor(1,1,1, 0.95)
        glText(initLabel, bx, by,   CFG.fontSize-1, "oc")
    end
end

-- ─── Player names on edge midpoints ──────────────────────────────────────────

local function drawPlayerNamesOnEdges()
    local n = #playerData
    if n == 0 then return end
    local fs        = CFG.fontSize - 1
    local nameR     = CFG.radius + CFG.labelOffset + 18
    local freeEdges = NUM_AXES - 1   -- edge NUM_AXES reserved for title

    for i, p in ipairs(playerData) do
        local edgeIdx = ((i-1) % freeEdges) + 1
        local nx, ny  = edgeMidPoint(edgeIdx, nameR)
        local col     = p.color
        glColor(0,0,0, 0.7)
        glText(p.name, nx+1, ny-1, fs, "oc")
        glColor(col[1],col[2],col[3], 1.0)
        glText(p.name, nx, ny, fs, "oc")
        if p.cmdCount and p.cmdCount > 0 then
            local nameW = #p.name * fs * 0.55
            local cx    = nx + nameW*0.5 + 4
            glColor(0,0,0, 0.7)
            glText("("..p.cmdCount..")", cx+1, ny-1, fs+2, "ol")
            glColor(col[1],col[2],col[3], 1.0)
            glText("("..p.cmdCount..")", cx, ny, fs+2, "ol")
        end
    end

    -- Title block on reserved top edge (edge NUM_AXES: between axis NUM_AXES and axis 1)
    local tx, ty = edgeMidPoint(NUM_AXES, nameR)
    local lineH  = fs + 2
    local authorStr = _da()
    glColor(0,0,0, 0.7)
    glText("FFA Radar HUD", tx+1, ty+lineH-1, fs, "oc")
    glColor(0.88,0.90,0.95, 0.95)
    glText("FFA Radar HUD", tx, ty+lineH, fs, "oc")
    glColor(0,0,0, 0.6)
    glText("Author: "..authorStr, tx+1, ty-1, fs-1, "oc")
    glColor(0.62,0.65,0.70, 0.85)
    glText("Author: "..authorStr, tx, ty, fs-1, "oc")
    glColor(0,0,0, 0.5)
    glText("Version 2.4", tx+1, ty-lineH-1, fs-2, "oc")
    glColor(0.50,0.53,0.58, 0.75)
    glText("Version 2.4", tx, ty-lineH, fs-2, "oc")
end

-- ─── Background ──────────────────────────────────────────────────────────────

local function drawBackground()
    glColor(0.04,0.05,0.08, 0.60)
    glBeginEnd(GL_POLYGON, function()
        for i=1,NUM_AXES do
            local ax,ay = axisPoint(i, CFG.radius + CFG.labelOffset + 10)
            glVertex(ax,ay)
        end
    end)
end

-- ─── Mode-cycle button ────────────────────────────────────────────────────────

local function drawModeButton()
    local bx = BTN.x
    local by = BTN.y
    local bw = BTN.w
    local bh = BTN.h

    -- Background
    glColor(0.08,0.10,0.14, 0.88)
    glBeginEnd(GL_POLYGON, function()
        glVertex(bx,    by)
        glVertex(bx+bw, by)
        glVertex(bx+bw, by+bh)
        glVertex(bx,    by+bh)
    end)
    -- Border
    glColor(0.40,0.45,0.55, 0.70)
    glBeginEnd(GL.LINE_LOOP, function()
        glVertex(bx,    by)
        glVertex(bx+bw, by)
        glVertex(bx+bw, by+bh)
        glVertex(bx,    by+bh)
    end)
    -- Colour stripe (left edge, mode colour)
    local sc = ({ {0.25,0.55,1.00}, {0.95,0.60,0.10}, {0.20,0.85,0.50} })[visMode]
    glColor(sc[1],sc[2],sc[3], 0.80)
    glBeginEnd(GL_POLYGON, function()
        glVertex(bx,   by)
        glVertex(bx+4, by)
        glVertex(bx+4, by+bh)
        glVertex(bx,   by+bh)
    end)
    -- Label
    glColor(0,0,0, 0.60)
    glText(MODE_LABELS[visMode], bx+bw/2+1, by+bh/2-5, 10, "oc")
    glColor(0.88,0.91,0.95, 0.95)
    glText(MODE_LABELS[visMode], bx+bw/2,   by+bh/2-4, 10, "oc")
end

-- ─── Layout ───────────────────────────────────────────────────────────────────

local function updateLayout()
    CFG.cx = screenW - 180
    CFG.cy = mfloor(screenH * 0.50)
    -- Button: bottom-right corner of the chart bounding box
    local chartR = CFG.radius + CFG.labelOffset + 12
    BTN.x = CFG.cx + chartR - BTN.w
    BTN.y = CFG.cy - chartR - BTN.h - 4
end

-- ─── Widget callbacks ─────────────────────────────────────────────────────────

function widget:Initialize()
    local info = { Spring.GetViewGeometry() }
    if info[3] and info[3] > 100 then
        screenW = info[3]
        screenH = info[4]
    end
    classifyUnitDefs()
    updateLayout()
    refreshData()
end

function widget:ViewResize(vw, vh)
    screenW = vw
    screenH = vh
    updateLayout()
end

function widget:Update(dt)
    timer      = timer + dt
    trailTimer = trailTimer + dt
    if timer >= CFG.updateInterval then
        timer = 0
        refreshData()
    end
    if trailTimer >= CFG.trailInterval and visMode == 3 and #playerData >= CFG.minPlayers then
        trailTimer = 0
        snapshotTrail()
    end
end

function widget:DrawScreen()
    local n = #playerData
    if n < 2 then
        glColor(0.60,0.65,0.73, 0.7)
        glText("FFA Radar HUD: waiting for 2+ players...",
               CFG.cx - 160, CFG.cy, CFG.fontSize, "o")
        drawModeButton()
        return
    end

    gl.LineWidth(1.0)
    drawBackground()

    if     visMode == 1 then
        drawGrid()
        drawAxisLabels()
        drawScaleLabels()
        for i = #playerData, 1, -1 do
            drawPlayerPolygon(playerData[i], CFG.lineAlpha)
        end
    elseif visMode == 2 then
        drawNightingaleRose()
    elseif visMode == 3 then
        drawScatter()
    end

    drawPlayerNamesOnEdges()
    drawModeButton()
end

-- ─── Dragging ─────────────────────────────────────────────────────────────────

local dragging = false
local dragOffX = 0
local dragOffY = 0

local function inChart(mx, my)
    local dx = mx - CFG.cx
    local dy = my - CFG.cy
    local r  = CFG.radius + CFG.labelOffset + 10
    return (dx*dx + dy*dy) <= (r*r)
end

local function inButton(mx, my)
    return mx >= BTN.x and mx <= BTN.x + BTN.w
       and my >= BTN.y and my <= BTN.y + BTN.h
end

function widget:MousePress(mx, my, btn)
    if btn ~= 1 then return false end
    if inButton(mx, my) then
        visMode = (visMode % 3) + 1
        return true
    end
    if inChart(mx, my) then
        dragging = true
        dragOffX = mx - CFG.cx
        dragOffY = my - CFG.cy
        return true
    end
    return false
end

function widget:MouseMove(mx, my)
    if dragging then
        CFG.cx = mx - dragOffX
        CFG.cy = my - dragOffY
        local chartR = CFG.radius + CFG.labelOffset + 12
        BTN.x = CFG.cx + chartR - BTN.w
        BTN.y = CFG.cy - chartR - BTN.h - 4
    end
end

function widget:MouseRelease(mx, my, btn)
    if btn == 1 then dragging = false end
end