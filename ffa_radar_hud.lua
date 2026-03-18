-- ffa_radar_hud.lua
-- Beyond All Reason — Spectator FFA radar HUD
-- Shows a hexagon radar chart for the top 2-6 remaining players
-- Axes: M/s, E/s, BP, MP (metal stored), AV (army value), Dmg (damage dealt)
-- Place in: Beyond All Reason/LuaUI/Widgets/

function widget:GetInfo()
    return {
        name    = "FFA Radar HUD",
        desc    = "Spectator hexagon radar chart for top 2-6 FFA players — v2.1",
        author  = "goddot",
        date    = "2026",
        license = "GNU GPL v2",
        layer   = 0,
        enabled = true,
    }
end

-- ─── Config ───────────────────────────────────────────────────────────────────

local CFG = {
    cx           = 0,       -- centre X (set on init/resize)
    cy           = 0,       -- centre Y (set on init/resize)
    radius       = 220,     -- outer ring radius in px
    rings        = 4,       -- concentric grid rings
    maxPlayers   = 6,
    minPlayers   = 2,
    bgAlpha      = 0.55,    -- radar background fill alpha
    lineAlpha    = 0.85,    -- player polygon line alpha
    fontSize     = 14,
    labelOffset  = 28,      -- extra px beyond radius for axis labels
    legendX      = 0,       -- set on init
    legendY      = 0,
    updateInterval = 1.0,
}

-- ─── Player colours (RGBA, matching reference image style) ────────────────────

local PLAYER_COLORS = {
    { 0.20, 0.35, 1.00, 1.0 },  -- blue
    { 0.15, 0.85, 0.75, 1.0 },  -- teal
    { 0.70, 0.20, 0.90, 1.0 },  -- purple
    { 0.80, 0.72, 0.05, 1.0 },  -- gold
    { 0.95, 0.15, 0.15, 1.0 },  -- red
    { 0.15, 0.85, 0.25, 1.0 },  -- green
}

-- ─── Axes: label, key into playerStats ────────────────────────────────────────
-- 7 axes evenly spaced, starting from top (M/s) going clockwise

local AXES = {
    { label = "M/s", key = "metalIncome"  },
    { label = "E/s", key = "energyIncome" },
    { label = "BP",  key = "bp"           },
    { label = "MP",  key = "metalStored"  },
    { label = "AV",  key = "armyValue"    },
    { label = "Dmg", key = "dmgDealt"     },
}
local NUM_AXES = #AXES

-- ─── Spring API locals ────────────────────────────────────────────────────────

local spGetAllUnits      = Spring.GetAllUnits
local spGetUnitDefID     = Spring.GetUnitDefID
local spGetUnitTeam      = Spring.GetUnitTeam
local spGetUnitHealth    = Spring.GetUnitHealth
local spGetTeamResources = Spring.GetTeamResources
local spGetTeamDamageStats = Spring.GetTeamDamageStats
local spGetTeamList      = Spring.GetTeamList
local spGetPlayerList    = Spring.GetPlayerList
local spGetPlayerInfo    = Spring.GetPlayerInfo
local spGetTeamInfo      = Spring.GetTeamInfo
local spGetMouseState    = Spring.GetMouseState

local glColor      = gl.Color
local glVertex     = gl.Vertex
local glBeginEnd   = gl.BeginEnd
local glText       = gl.Text
local glRect       = gl.Rect
local GL_LINE_LOOP = GL.LINE_LOOP
local GL_LINES     = GL.LINES
local GL_LINE_STRIP = GL.LINE_STRIP
local GL_POLYGON   = GL.POLYGON

local msin = math.sin
local mcos = math.cos
local mpi  = math.pi
local mfloor = math.floor
local msqrt  = math.sqrt
local mmax   = math.max

-- ─── Unit def cache ───────────────────────────────────────────────────────────

local udCache = {}   -- [udid] = { cost, isBP, isArmy, isDef, bp }

local function classifyUnitDefs()
    for udid, ud in pairs(UnitDefs) do
        local cost = ud.metalCost or 0
        local isBP, isArmy, isDef, isCmd = false, false, false, false
        local bp = 0

        if ud.buildSpeed and ud.buildSpeed > 0 then
            isBP = true
            bp   = ud.buildSpeed
        end

        -- Commander detection: check customParams.unitGroup or name pattern
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

local screenW   = 1280
local screenH   = 768
local timer     = 0

-- playerData: array of { teamID, name, color, stats{} }
local playerData = {}

-- Per-axis maximums used to normalise values to [0,1]
local axisMax = {}
for i = 1, NUM_AXES do axisMax[i] = 1 end

-- ─── Geometry helpers ─────────────────────────────────────────────────────────

-- Returns the x,y screen position for axis i at distance r from centre
-- Axis 0 points straight up, then clockwise
local function axisPoint(i, r)
    local angle = (2 * mpi * (i - 1) / NUM_AXES) - mpi / 2
    return CFG.cx + mcos(angle) * r,
           CFG.cy + msin(angle) * r
end

-- ─── Data collection ──────────────────────────────────────────────────────────

local function getActivePlayers()
    local teams = spGetTeamList()
    if not teams then return {} end

    local result = {}
    for _, tid in ipairs(teams) do
        -- Skip gaia (team -1 or the special gaia team)
        local luaAI, isAI, side, allyID, hasLeader = nil, nil, nil, nil, nil
        local isDead = false

        -- GetTeamInfo returns: teamID, leader, isDead, isAI, side, allyTeam
        local tInfo = { spGetTeamInfo(tid) }
        if tInfo and tInfo[1] ~= nil then
            isDead  = tInfo[3]
            allyID  = tInfo[6]
        end

        if not isDead then
            -- Find player name for this team
            local name = "Team " .. tid
            local players = spGetPlayerList(tid, false) or {}
            if #players > 0 then
                local n, active, spec = spGetPlayerInfo(players[1], false)
                if n then name = n end
            end

            -- Get a colour for this team from Spring if available
            local r, g, b = Spring.GetTeamColor(tid)
            local col = (r and g and b)
                and { r, g, b, 1.0 }
                or  PLAYER_COLORS[((#result) % #PLAYER_COLORS) + 1]

            result[#result + 1] = {
                teamID = tid,
                name   = name,
                color  = col,
                stats  = { metalIncome=0, energyIncome=0, bp=0,
                           metalStored=0, armyValue=0, dmgDealt=0 },
            }
        end
    end

    -- Sort by army value descending as a rough "top player" proxy
    -- (will update after stats are populated)
    return result
end

local function collectStats(pd)
    local teamBP   = {}
    local teamArmy = {}
    local teamCmd  = {}

    local units = spGetAllUnits()
    for i = 1, #units do
        local uid  = units[i]
        local tid  = spGetUnitTeam(uid)
        local info = udCache[spGetUnitDefID(uid)]
        if info then
            local hp, maxHp = spGetUnitHealth(uid)
            local frac = (hp and maxHp and maxHp > 0) and (hp / maxHp) or 1.0
            teamBP[tid]  = (teamBP[tid]  or 0) + (info.isBP   and info.bp                 or 0)
            teamArmy[tid]= (teamArmy[tid] or 0) + (info.isArmy and mfloor(info.cost * frac) or 0)
            if info.isCmd then
                teamCmd[tid] = (teamCmd[tid] or 0) + 1
            end
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
        p.cmdCount           = teamCmd[tid]         or 0
    end
end

local function updateAxisMaxima(pd)
    -- Each axis scales to the maximum value across all displayed players.
    -- This means the best player on each dimension always reaches the outer ring,
    -- and everyone else is drawn proportionally.
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
    -- Show at least 5 players when available, never more than maxPlayers
    local keep = math.max(5, #pd)
    if keep > CFG.maxPlayers then keep = CFG.maxPlayers end
    while #pd > keep do
        table.remove(pd)
    end
end

local function refreshData()
    local pd = getActivePlayers()
    if #pd < CFG.minPlayers then
        playerData = pd
        return
    end
    collectStats(pd)
    sortAndTrim(pd)
    updateAxisMaxima(pd)
    playerData = pd
end

-- ─── Drawing ──────────────────────────────────────────────────────────────────

local function drawGrid()
    local rings = CFG.rings

    -- Ring lines
    for ring = 1, rings do
        local r = CFG.radius * ring / rings
        glColor(1, 1, 1, 0.12)
        glBeginEnd(GL_LINE_LOOP, function()
            for i = 1, NUM_AXES do
                local ax, ay = axisPoint(i, r)
                glVertex(ax, ay)
            end
        end)
    end

    -- Spoke lines from centre to outer
    glColor(1, 1, 1, 0.18)
    for i = 1, NUM_AXES do
        local ax, ay = axisPoint(i, CFG.radius)
        glBeginEnd(GL_LINES, function()
            glVertex(CFG.cx, CFG.cy)
            glVertex(ax, ay)
        end)
    end

    -- Outer ring slightly brighter
    glColor(1, 1, 1, 0.35)
    glBeginEnd(GL_LINE_LOOP, function()
        for i = 1, NUM_AXES do
            local ax, ay = axisPoint(i, CFG.radius)
            glVertex(ax, ay)
        end
    end)
end

local function drawAxisLabels()
    local fs = CFG.fontSize
    local lo = CFG.labelOffset
    for i, ax in ipairs(AXES) do
        local lx, ly = axisPoint(i, CFG.radius + lo)
        glColor(0.88, 0.90, 0.95, 1.0)
        glText(ax.label, lx, ly, fs, "oc")
    end
end

-- Tiny scale value labels along each spoke at each ring intersection
-- Rendered at a small fixed size, nudged slightly off-centre so they
-- don't sit directly on the grid lines.
local function drawScaleLabels()
    local rings  = CFG.rings
    local fs     = 8          -- tiny font
    local nudge  = 5          -- px sideways offset from spoke
    for ai = 1, NUM_AXES do
        -- angle of this spoke
        local angle = (2 * mpi * (ai - 1) / NUM_AXES) - mpi / 2
        -- perpendicular nudge direction (rotate 90 degrees)
        local px = -msin(angle) * nudge
        local py =  mcos(angle) * nudge
        for ring = 1, rings do
            local frac = ring / rings
            local r    = CFG.radius * frac
            local sx   = CFG.cx + mcos(angle) * r + px
            local sy   = CFG.cy + msin(angle) * r + py
            -- Format the scale value for this ring on this axis
            local maxV = axisMax[ai] or 1
            local val  = maxV * frac
            local label
            if val >= 10000 then
                label = string.format("%.0fk", val / 1000)
            elseif val >= 1000 then
                label = string.format("%.1fk", val / 1000)
            elseif val >= 10 then
                label = string.format("%.0f", val)
            else
                label = string.format("%.1f", val)
            end
            -- Shadow
            glColor(0, 0, 0, 0.65)
            glText(label, sx + 1, sy - 1, fs, "oc")
            -- Label in silver/white
            glColor(0.75, 0.78, 0.82, 0.90)
            glText(label, sx, sy, fs, "oc")
        end
    end
end

local function drawPlayerPolygon(p, colorAlpha)
    local col = p.color
    -- Filled polygon (semi-transparent)
    glColor(col[1], col[2], col[3], 0.10)
    glBeginEnd(GL_POLYGON, function()
        for ai, ax in ipairs(AXES) do
            local val  = p.stats[ax.key] or 0
            local norm = axisMax[ai] > 0 and (val / axisMax[ai]) or 0
            if norm > 1 then norm = 1 end
            local px, py = axisPoint(ai, norm * CFG.radius)
            glVertex(px, py)
        end
    end)

    -- Outline
    glColor(col[1], col[2], col[3], colorAlpha)
    gl.LineWidth(2.0)
    glBeginEnd(GL_LINE_LOOP, function()
        for ai, ax in ipairs(AXES) do
            local val  = p.stats[ax.key] or 0
            local norm = axisMax[ai] > 0 and (val / axisMax[ai]) or 0
            if norm > 1 then norm = 1 end
            local px, py = axisPoint(ai, norm * CFG.radius)
            glVertex(px, py)
        end
    end)

    -- Dots at each axis vertex
    gl.LineWidth(1.0)
    for ai, ax in ipairs(AXES) do
        local val  = p.stats[ax.key] or 0
        local norm = axisMax[ai] > 0 and (val / axisMax[ai]) or 0
        if norm > 1 then norm = 1 end
        local px, py = axisPoint(ai, norm * CFG.radius)
        -- Draw a small filled circle approximation (octagon)
        glColor(col[1], col[2], col[3], 1.0)
        glBeginEnd(GL_POLYGON, function()
            for s = 0, 7 do
                local a = s * mpi / 4
                glVertex(px + mcos(a)*4, py + msin(a)*4)
            end
        end)
    end
end

local function drawPlayerNames()
    if #playerData == 0 then return end
    local fs    = CFG.fontSize - 1
    local nameR = CFG.radius + CFG.labelOffset + 18
    local n     = #playerData
    -- Total slots = n players + 1 for the title block, evenly distributed
    local total = n + 1
    for i, p in ipairs(playerData) do
        local angle = (2 * mpi * (i - 1) / total) - mpi / 2
        local nx = CFG.cx + mcos(angle) * nameR
        local ny = CFG.cy + msin(angle) * nameR
        local col = p.color
        -- Draw name at normal size
        glColor(0, 0, 0, 0.7)
        glText(p.name, nx + 1, ny - 1, fs, "oc")
        glColor(col[1], col[2], col[3], 1.0)
        glText(p.name, nx, ny, fs, "oc")
        -- Commander count slightly larger, appended after name
        if p.cmdCount and p.cmdCount > 0 then
            local nameW = #p.name * fs * 0.55   -- rough pixel width estimate
            local cx    = nx + nameW * 0.5 + 4
            glColor(0, 0, 0, 0.7)
            glText("("..p.cmdCount..")", cx + 1, ny - 1, fs + 2, "ol")
            glColor(col[1], col[2], col[3], 1.0)
            glText("("..p.cmdCount..")", cx, ny, fs + 2, "ol")
        end
    end
    -- Title block occupies the last slot, equidistant from all player names
    local gangle = (2 * mpi * n / total) - mpi / 2
    local gx = CFG.cx + mcos(gangle) * nameR
    local gy = CFG.cy + msin(gangle) * nameR
    local lineH = fs + 2
    -- "FFA Radar HUD" — brighter white
    glColor(0, 0, 0, 0.7)
    glText("FFA Radar HUD", gx + 1, gy + lineH - 1, fs, "oc")
    glColor(0.88, 0.90, 0.95, 0.95)
    glText("FFA Radar HUD", gx, gy + lineH, fs, "oc")
    -- "Author: goddot" — silver
    glColor(0, 0, 0, 0.6)
    glText("Author: goddot", gx + 1, gy - 1, fs - 1, "oc")
    glColor(0.62, 0.65, 0.70, 0.85)
    glText("Author: goddot", gx, gy, fs - 1, "oc")
    -- "Version 2.1" — dimmer silver
    glColor(0, 0, 0, 0.5)
    glText("Version 2.1", gx + 1, gy - lineH - 1, fs - 2, "oc")
    glColor(0.50, 0.53, 0.58, 0.75)
    glText("Version 2.1", gx, gy - lineH, fs - 2, "oc")
end

local function drawBackground()
    -- Subtle dark radial-ish background behind the chart
    glColor(0.04, 0.05, 0.08, 0.60)
    glBeginEnd(GL_POLYGON, function()
        for i = 1, NUM_AXES do
            local ax, ay = axisPoint(i, CFG.radius + CFG.labelOffset + 10)
            glVertex(ax, ay)
        end
    end)
end

-- ─── Widget callbacks ─────────────────────────────────────────────────────────

local function updateLayout()
    CFG.cx = screenW - 180
    CFG.cy = mfloor(screenH * 0.50)
end

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
    timer = timer + dt
    if timer >= CFG.updateInterval then
        timer = 0
        refreshData()
    end
end

function widget:DrawScreen()
    local n = #playerData
    if n < 2 then
        glColor(0.60, 0.65, 0.73, 0.7)
        glText("FFA Radar HUD: waiting for 2+ players...",
               CFG.cx - 160, CFG.cy, CFG.fontSize, "o")
        return
    end

    gl.LineWidth(1.0)

    drawBackground()
    drawGrid()
    drawAxisLabels()
    drawScaleLabels()

    -- Draw all polygons back to front (last player drawn on top)
    for i = #playerData, 1, -1 do
        drawPlayerPolygon(playerData[i], CFG.lineAlpha)
    end

    drawPlayerNames()
end

-- ─── Dragging (move chart centre) ────────────────────────────────────────────

local dragging = false
local dragOffX = 0
local dragOffY = 0

local function inChart(mx, my)
    local dx = mx - CFG.cx
    local dy = my - CFG.cy
    local r  = CFG.radius + CFG.labelOffset + 10
    return (dx*dx + dy*dy) <= (r*r)
end

function widget:MousePress(mx, my, btn)
    if btn ~= 1 then return false end
    if inChart(mx, my) then
        dragging = true
        dragOffX = mx - CFG.cx
        dragOffY = my - CFG.cy
        return true
    end
    return false
end

function widget:MouseMove(mx, my, dx, dy)
    if dragging then
        CFG.cx = mx - dragOffX
        CFG.cy = my - dragOffY
    end
end

function widget:MouseRelease(mx, my, btn)
    if btn == 1 then dragging = false end
end