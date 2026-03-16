-- ffa_radar_hud.lua
-- Beyond All Reason — Spectator FFA radar HUD
-- Shows a hexagon radar chart for the top 2-6 remaining players
-- Axes: M/s, E/s, BP, MP (metal stored), AV (army value), Dmg (damage dealt)
-- Place in: Beyond All Reason/LuaUI/Widgets/

function widget:GetInfo()
    return {
        name    = "FFA Radar HUD",
        desc    = "Spectator hexagon radar chart for top 2-6 FFA players",
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
-- 6 axes evenly spaced, starting from top (M/s) going clockwise

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
local spGetTeamList      = Spring.GetTeamList
local spGetPlayerList    = Spring.GetPlayerList
local spGetPlayerInfo    = Spring.GetPlayerInfo
local spGetTeamInfo      = Spring.GetTeamInfo
local spGetTeamStatsHistory = Spring.GetTeamStatsHistory
local spIsSpectator      = Spring.IsSpectator  -- may not exist in all versions
local spGetSpectatingState = Spring.GetSpectatingState
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
        local isBP, isArmy, isDef = false, false, false
        local bp = 0

        if ud.buildSpeed and ud.buildSpeed > 0 then
            isBP = true
            bp   = ud.buildSpeed
        end

        local canAttack = ud.weapons and #ud.weapons > 0
        local isStatic  = (not ud.canMove) or (ud.speed == 0)

        if canAttack and isStatic and not isBP then isDef  = true end
        if canAttack and ud.canMove and ud.speed and ud.speed > 0 then isArmy = true end

        if cost > 0 and (isBP or isArmy or isDef) then
            udCache[udid] = { cost=cost, isBP=isBP, isArmy=isArmy,
                              isDef=isDef, bp=bp }
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
    -- Per-team unit scan
    local teamBP    = {}
    local teamArmy  = {}

    local units = spGetAllUnits()
    for i = 1, #units do
        local uid  = units[i]
        local tid  = spGetUnitTeam(uid)
        local info = udCache[spGetUnitDefID(uid)]
        if info then
            local hp, maxHp = spGetUnitHealth(uid)
            local frac = (hp and maxHp and maxHp > 0) and (hp / maxHp) or 1.0

            teamBP[tid]   = (teamBP[tid]   or 0) + (info.isBP and info.bp or 0)
            teamArmy[tid] = (teamArmy[tid] or 0)
                + (info.isArmy and mfloor(info.cost * frac) or 0)
                + (info.isDef  and mfloor(info.cost * frac) or 0)
        end
    end

    for _, p in ipairs(pd) do
        local tid = p.teamID
        local mCur, mStore, _, mInc = spGetTeamResources(tid, "metal")
        local _,    _,      _, eInc = spGetTeamResources(tid, "energy")

        mCur  = mCur  or 0
        mInc  = mInc  or 0
        eInc  = eInc  or 0

        -- Damage dealt: use GetTeamStatsHistory if available
        local dmg = 0
        if spGetTeamStatsHistory then
            local hist = spGetTeamStatsHistory(tid, 0, 1)
            if hist and hist[1] then
                dmg = hist[1].damageDealt or 0
            end
        end

        p.stats.metalIncome  = mfloor(mInc  * 10) / 10
        p.stats.energyIncome = mfloor(eInc  * 10) / 10
        p.stats.bp           = mfloor(teamBP[tid]   or 0)
        p.stats.metalStored  = mfloor(mCur)
        p.stats.armyValue    = teamArmy[tid] or 0
        p.stats.dmgDealt     = mfloor(dmg)
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
    -- Sort by armyValue desc, keep top maxPlayers
    table.sort(pd, function(a, b)
        return (a.stats.armyValue or 0) > (b.stats.armyValue or 0)
    end)
    while #pd > CFG.maxPlayers do
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

local function drawLegend()
    if #playerData == 0 then return end
    local lx = CFG.legendX
    local ly = CFG.legendY
    local fs = CFG.fontSize - 1
    local rh = 22
    local bw = 160
    local bh = rh * #playerData + 16

    -- Legend background
    glColor(0.04, 0.05, 0.08, 0.78)
    glRect(lx, ly, lx + bw, ly + bh)
    glColor(0.28, 0.48, 0.78, 0.40)
    glBeginEnd(GL_LINE_LOOP, function()
        glVertex(lx,      ly)
        glVertex(lx + bw, ly)
        glVertex(lx + bw, ly + bh)
        glVertex(lx,      ly + bh)
    end)

    local ty = ly + bh - 8 - fs
    for i, p in ipairs(playerData) do
        local col = p.color
        -- Colour swatch
        glColor(col[1], col[2], col[3], 0.9)
        glRect(lx + 8, ty + 2, lx + 22, ty + fs - 2)
        -- Name
        glColor(0.88, 0.90, 0.95, 1.0)
        glText(p.name, lx + 28, ty, fs, "o")
        ty = ty - rh
    end
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
    CFG.cx      = mfloor(screenW * 0.42)
    CFG.cy      = mfloor(screenH * 0.50)
    CFG.legendX = screenW - 185
    CFG.legendY = screenH - 30 - 22 * CFG.maxPlayers
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
    if #playerData < CFG.minPlayers then
        -- Not enough players — show a small hint
        glColor(0.60, 0.65, 0.73, 0.7)
        glText("FFA Radar HUD: waiting for 2+ players...",
               CFG.cx - 160, CFG.cy, CFG.fontSize, "o")
        return
    end

    gl.LineWidth(1.0)

    drawBackground()
    drawGrid()
    drawAxisLabels()

    -- Draw all polygons back to front (last player drawn on top)
    for i = #playerData, 1, -1 do
        drawPlayerPolygon(playerData[i], CFG.lineAlpha)
    end

    drawLegend()
end

-- ─── Dragging (move chart centre) ────────────────────────────────────────────

local dragging = false
local dragOffX = 0
local dragOffY = 0

local function inChart(mx, my)
    local fy  = screenH - my
    local dx  = mx - CFG.cx
    local dy  = fy - CFG.cy
    local r   = CFG.radius + CFG.labelOffset + 10
    return (dx*dx + dy*dy) <= (r*r)
end

function widget:MousePress(mx, my, btn)
    if btn ~= 1 then return false end
    if inChart(mx, my) then
        local fy = screenH - my
        dragging = true
        dragOffX = mx - CFG.cx
        dragOffY = fy - CFG.cy
        return true
    end
    return false
end

function widget:MouseMove(mx, my, dx, dy)
    if dragging then
        local fy = screenH - my
        CFG.cx = mx - dragOffX
        CFG.cy = fy - dragOffY
    end
end

function widget:MouseRelease(mx, my, btn)
    if btn == 1 then dragging = false end
end
