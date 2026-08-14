-- MiniMap v9 - R.E.P.O.-style toggleable minimap for Grain Rot
--
-- v9 (from live calibration with F8 dumps):
--  * merges ExternalDungeonActors sub-dungeons into the map - parts of the
--    dungeon (long hallways/stair sections) live on attached dungeon actors
--    with their own grids, which is why pawn grid (4,-15) had no geometry
--  * whole map auto-rotates so the spawn elevator's opening faces UP
--    (HeldenElevator actor yaw, rounded to 90 degrees); marker heading
--    rotates to match
--
-- Grid facts (calibrated): TileSize=200, dungeon actor location = grid
-- origin, spawn elevator = grid (0,0) (green square), pawn grid =
-- (pawnWorld - actorWorld)/TileSize - verified against room rects.
--
-- Controls: M = toggle, Numpad +/- = resize, F9 = debug, F8 = grid dump.
--
-- Landmines respected (see grain-rot-modding memory): no LoopAsync timers
-- (per-frame work rides the ABP_HeldenPlayer BlueprintUpdateAnimation hook,
-- registered lazily), no FKey/IsInputKeyDown, structs passed as tables.
-- ClientRestart fires DURING normal play - never drop a live widget on it.
-- Never hot reload during a level transition (crash).

local UEHelpers = require("UEHelpers")

-- ============================== config =====================================
local TOGGLE_KEY = Key.M
local MAP_SIZE = 300
local MARGIN = 25
-- ------------------------- R.E.P.O.-inspired palette ----------------------
-- no backing panel: the map floats over the game, outlined for readability
local BG_COLOR = { R = 0.015, G = 0.03, B = 0.05, A = 0.0 } -- disabled
local BG_PAD = 10
local OUTLINE_COLOR = { R = 0.04, G = 0.08, B = 0.12, A = 0.8 } -- dark edge
local OUTLINE_FRAC = 0.16 -- outline thickness as a fraction of tile size
local ROOM_COLOR = { R = 0.84, G = 0.89, B = 0.85, A = 0.66 } -- mint-white
local START_COLOR = { R = 0.2, G = 0.9, B = 0.4, A = 0.9 } -- spawn elevator
-- tiles you walked through that no dungeon array describes (static level
-- geometry like stair hallways) get auto-mapped in this shade
local SHOW_TRAIL = false -- explored-tile tracer dots (off for release)
local TRAIL_COLOR = { R = 0.3, G = 0.75, B = 0.62, A = 0.66 } -- teal
-- trail tiles on a DIFFERENT floor than you are on right now
local TRAIL_OTHER_FLOOR = { R = 0.16, G = 0.32, B = 0.38, A = 0.5 }
local FLOOR_BAND = 600 -- world units of height per floor band
-- rooms with no per-tile part data only report a bounding box (often much
-- bigger than the real room); shown dim until you actually walk them
-- these are REAL rooms (they appear on the game's own table map), just with
-- bounding-box precision - drawn as a clearly visible mid-tone layer
local HINT_COLOR = { R = 0.42, G = 0.47, B = 0.52, A = 0.5 }
local MARKER_COLOR = { R = 1.0, G = 0.32, B = 0.18, A = 1.0 }
-- teammates: drawn as squares in each player's replicated spark color
local SHOW_TEAMMATES = true
local TEAM_MARKER_PX = 7
local TEAM_POOL = 15
-- used only if a player's replicated color can't be read (never draw black)
local TEAM_FALLBACK = {
    { 0.55, 0.35, 0.95 }, { 0.3, 0.6, 1.0 }, { 1.0, 0.85, 0.3 },
    { 0.95, 0.45, 0.75 }, { 0.4, 0.9, 0.5 }, { 0.9, 0.5, 0.25 },
}
-- inset (px at current scale) that lets the dark backing show through as
-- seams between rooms/corridors - gives the layout definition
local INSET_FRAC = 0.09
local MARKER_PX = 9
local SIZE_STEP = 40
local SIZE_MIN, SIZE_MAX = 140, 700
local REBIND_INTERVAL = 2.0
local ROOM_POOL = 768 -- large icy dungeons alone can use ~250 runs; the rest is trail headroom
-- extra quarter-turns on top of the elevator-facing auto-rotation (0-3);
-- set to 2 if maps consistently render upside down
local ROT_EXTRA = 0
-- mirror after rotation, if left/right ends up swapped vs. reality
local MIRROR_X = false
-- ===========================================================================

local S = {
    built = false,
    visible = false,
    size = MAP_SIZE,
    baseX = 0, baseY = 0,
    anchoredRight = false,
    errCount = 0,
    dungAddr = nil,
    rects = nil,
    geo = nil, -- { actX, actY, tile, addr, name, rot, ang, stats, ext }
    lay = nil,
    lastRebind = 0,
    band = 0, -- current floor band (from pawn height vs spawn height)
    -- live marker calibration in SCREEN tile units (Home/End/Del/Ins keys);
    -- report the F9 values so they can become permanent defaults.
    -- Defaults from the 2026-08-11 trail-overlap matrix (rot=1 aq=2 peak
    -- at screen +1,-1 with continuous offset ~ +0.5,-0.5)
    calX = 0.5, calY = -0.5,
}
local W = { widget = nil, canvas = nil, bg = nil, marker = nil,
            bgSlot = nil, markerSlot = nil, pool = nil }
local C = { pc = nil, pawn = nil, animAddr = nil, lastTry = 0, gs = nil }
local Hooked = false
local HookedAnimClasses = {}

local function Log(msg)
    print("[MiniMap] " .. msg .. "\n")
end

-- ---------------------------------------------------------------- player cache
local HookAnimClassOf -- forward decl (defined in the hook section)

-- On a multiplayer host several PlayerControllers exist; only the LOCAL one
-- (with a UPlayer attached) can own widgets. Pick it explicitly.
local function GetLocalPC()
    local best
    pcall(function()
        local pcs = FindAllOf("PlayerController")
        if pcs then
            for _, cand in ipairs(pcs) do
                if cand:IsValid() then
                    local ok, isLocal = pcall(function()
                        local pl = cand.Player
                        return pl and pl:IsValid()
                    end)
                    if ok and isLocal then
                        best = cand
                        break
                    end
                end
            end
        end
    end)
    if not best then
        pcall(function()
            local pc = UEHelpers.GetPlayerController()
            if pc and pc:IsValid() then best = pc end
        end)
    end
    return best
end

local function RefreshCache()
    C.pc, C.pawn, C.animAddr = nil, nil, nil
    pcall(function()
        local pc = GetLocalPC()
        if not pc or not pc:IsValid() then return end
        local pawn = pc.Pawn
        if not pawn or not pawn:IsValid() then return end
        C.pc = pc
        C.pawn = pawn
        pcall(function()
            C.animAddr = pawn.Mesh.AnimScriptInstance:GetAddress()
        end)
        -- pawn type can change mid-run (vessel -> spark); make sure whatever
        -- anim blueprint it uses also drives our per-frame updates
        if HookAnimClassOf then HookAnimClassOf(pawn) end
    end)
    return C.pawn ~= nil
end

local function CacheValid()
    return C.pc and C.pc:IsValid() and C.pawn and C.pawn:IsValid()
end

local function PawnPos()
    if not CacheValid() and not RefreshCache() then return nil end
    local p
    pcall(function()
        local l = C.pawn:K2_GetActorLocation()
        p = { X = l.X, Y = l.Y, Z = l.Z }
    end)
    return p
end

-- ------------------------------------------------------- rotation transforms
-- rot 0..3 = number of quarter-turns; maps grid point -> rotated grid point
local function RotPoint(rot, x, y)
    if rot == 1 then return y, -x end
    if rot == 2 then return -x, -y end
    if rot == 3 then return -y, x end
    return x, y
end

-- tile (x,y) covers [x,x+1)x[y,y+1); rotate as a cell
local function RotTile(rot, x, y)
    local ax, ay = RotPoint(rot, x, y)
    local bx, by = RotPoint(rot, x + 1, y + 1)
    return math.min(ax, bx), math.min(ay, by)
end

local ROT_ANGLE = { [0] = 0, [1] = -90, [2] = 180, [3] = 90 }

-- ------------------------------------------------------------- dungeon source
local function GetActiveDungeon()
    local d
    pcall(function()
        if not (C.gs and C.gs:IsValid()) then
            C.gs = FindFirstOf("HeldenGameState")
        end
        if C.gs and C.gs:IsValid() then
            local da = C.gs.CurrentDungeonRun.DungeonActor
            if da and da:IsValid() then d = da end
        end
    end)
    return d
end

-- run identity: CurrentSeed (HeldenDungeonGenerationInfo) is the REPLICATED
-- per-run seed+level; GenerationSeed proved to be a dead/dev field (read 0
-- every run, so v19's reset never fired and trails bled across runs)
local function RunId(d)
    local seed, level = 0, 0
    pcall(function()
        seed = d.CurrentSeed.Seed
        level = d.CurrentSeed.Level
    end)
    return seed .. "@" .. level
end

-- rotation that makes the spawn elevator's opening face screen-up.
-- aq = the dungeon ACTOR's own quarter-turn yaw: the generator spins the
-- whole grid per run, so world offsets must be un-rotated by aq to become
-- grid coords, and the elevator's world-space facing shifts by aq in grid
-- space (2026-08-11: same elevator yaw was verified correct one run and 180
-- degrees wrong the next - the dungeon actor rotation is the difference)
local function DetectRotation(al, tile, aq)
    local rot, yaw = 0, nil
    pcall(function()
        local elevs = FindAllOf("HeldenElevator")
        if not elevs then return end
        local best, bestD
        for _, e in ipairs(elevs) do
            if e:IsValid() then
                local ok = pcall(function()
                    local l = e:K2_GetActorLocation()
                    local dx, dy = l.X - al.X, l.Y - al.Y
                    local dist = dx * dx + dy * dy
                    if not bestD or dist < bestD then best, bestD = e, dist end
                end)
            end
        end
        -- only trust an elevator that is actually at the dungeon origin
        if best and bestD and bestD < (10 * tile) ^ 2 then
            yaw = best:K2_GetActorRotation().Yaw
            -- the elevator OPENING sits 90 degrees right of the actor's yaw
            -- (calibrated 2026-08-11: yaw=90 dungeon opens toward -X);
            -- subtract the dungeon actor's quarter-turn to get GRID direction
            local q = (math.floor(yaw / 90 + 0.5) + 1 - (aq or 0)) % 4
            if q < 0 then q = q + 4 end
            -- q = opening direction in grid space: rotate it to screen-up
            rot = (q + 1) % 4
        end
    end)
    return (rot + ROT_EXTRA) % 4, yaw
end

local function AddRoomTiles(room, occ, occHint, stats, offX, offY)
    local gx, gy = room.PositionInGrid.X, room.PositionInGrid.Y
    local sx, sy = room.Size.X, room.Size.Y
    local pts = {}
    local nParts = 0
    pcall(function() nParts = #room.RoomParts end)
    for i = 1, nParts do
        pcall(function()
            local part = room.RoomParts[i]
            local px, py = part.Point.X, part.Point.Y
            local pt = 0
            pcall(function() pt = tonumber(part.PartType) or 0 end)
            stats[pt] = (stats[pt] or 0) + 1
            pts[#pts + 1] = { x = px, y = py }
        end)
    end
    if #pts == 0 then
        -- bounding box only - queue as a PENDING hint; decided after all
        -- confirmed geometry is known (phantom generation regions overlap
        -- already-drawn rooms and get discarded; real prefab rooms don't)
        if sx and sy and sx > 0 and sy > 0 then
            occHint[#occHint + 1] = { gx = gx + offX, gy = gy + offY, sx = sx, sy = sy }
        end
        return 0
    end
    local inside = 0
    for _, p in ipairs(pts) do
        if p.x >= gx - 1 and p.x <= gx + (sx or 1) and p.y >= gy - 1 and p.y <= gy + (sy or 1) then
            inside = inside + 1
        end
    end
    local ox, oy = 0, 0
    if inside < #pts / 2 then ox, oy = gx, gy end
    for _, p in ipairs(pts) do
        occ[(p.x + ox + offX) .. "," .. (p.y + oy + offY)] = true
    end
    return #pts
end

local function ReadRoomsInto(arr, occ, occHint, stats, offX, offY, names)
    local num = 0
    pcall(function() num = #arr end)
    for i = 1, num do
        pcall(function()
            local room = arr[i]
            local n = AddRoomTiles(room, occ, occHint, stats, offX, offY)
            if names then
                local dn = ""
                pcall(function() dn = room.DebugName:ToString() end)
                names[#names + 1] = string.format("%s grid(%d,%d)+off(%d,%d) size(%d,%d) parts=%d",
                    dn ~= "" and dn or "?", room.PositionInGrid.X, room.PositionInGrid.Y,
                    offX, offY, room.Size.X, room.Size.Y, n)
            end
        end)
    end
end

local function ReadDungeonActorInto(da, occ, occHint, stats, offX, offY, names)
    pcall(function() ReadRoomsInto(da.Rooms, occ, occHint, stats, offX, offY, names) end)
    pcall(function() ReadRoomsInto(da.Connections, occ, occHint, stats, offX, offY, names) end)
    pcall(function() ReadRoomsInto(da.CustomRooms, occ, occHint, stats, offX, offY, names) end)
end

-- Full parse: main dungeon + external sub-dungeons -> rotated runs + geometry
local function ParseDungeon(d, names)
    local rects, geo
    pcall(function()
        local al = d:K2_GetActorLocation()
        local tile = 200.0
        pcall(function()
            local t = d.TileSize
            if t and t > 1 then tile = t end
        end)
        -- the generator rotates the whole dungeon per run; world->grid must
        -- undo the actor's quarter-turn yaw
        local aq = 0
        pcall(function()
            local ay = d:K2_GetActorRotation().Yaw
            aq = math.floor(ay / 90 + 0.5) % 4
            if aq < 0 then aq = aq + 4 end
        end)
        local occ, occHint, stats = {}, {}, {}
        ReadDungeonActorInto(d, occ, occHint, stats, 0, 0, names)
        -- external sub-dungeon actors (stair sections, long connectors)
        local nExt = 0
        pcall(function()
            local exts = d.ExternalDungeonActors
            local num = 0
            pcall(function() num = #exts end)
            for i = 1, num do
                pcall(function()
                    local e = exts[i]
                    if e and e:IsValid() then
                        local el = e:K2_GetActorLocation()
                        local offX = math.floor((el.X - al.X) / tile + 0.5)
                        local offY = math.floor((el.Y - al.Y) / tile + 0.5)
                        ReadDungeonActorInto(e, occ, occHint, stats, offX, offY, names)
                        nExt = nExt + 1
                    end
                end)
            end
        end)

        local rot, yaw = DetectRotation(al, tile, aq)

        -- resolve pending bounding-box hints: a box whose interior is
        -- already substantially covered by confirmed floor is a phantom
        -- generation region (e.g. the reserved start area), not a room -
        -- the game's own table map does not draw those either
        local hintTiles = {}
        for _, h in ipairs(occHint) do
            local total, covered = 0, 0
            for x = h.gx, h.gx + h.sx - 1 do
                for y = h.gy, h.gy + h.sy - 1 do
                    total = total + 1
                    if occ[x .. "," .. y] then covered = covered + 1 end
                end
            end
            if total > 0 and covered / total <= 0.35 then
                for x = h.gx, h.gx + h.sx - 1 do
                    for y = h.gy, h.gy + h.sy - 1 do
                        hintTiles[x .. "," .. y] = true
                    end
                end
            end
        end

        -- rotate occupancy sets
        local function Rotate(set)
            local out = {}
            for key in pairs(set) do
                local x, y = key:match("^(-?%d+),(-?%d+)$")
                local rx, ry = RotTile(rot, tonumber(x), tonumber(y))
                out[rx .. "," .. ry] = true
            end
            return out
        end
        local rocc = Rotate(occ)
        local rhint = Rotate(hintTiles)
        -- confirmed floor wins over hint
        for key in pairs(rocc) do rhint[key] = nil end

        local minX, minY, maxX, maxY
        for _, set in ipairs({ rocc, rhint }) do
            for key in pairs(set) do
                local x, y = key:match("^(-?%d+),(-?%d+)$")
                x, y = tonumber(x), tonumber(y)
                minX = (not minX or x < minX) and x or minX
                minY = (not minY or y < minY) and y or minY
                maxX = (not maxX or x > maxX) and x or maxX
                maxY = (not maxY or y > maxY) and y or maxY
            end
        end
        if not minX then return end
        rects = {}
        local full = false
        local function BuildRuns(set, isHint)
            for y = minY, maxY do
                local runStart
                for x = minX, maxX + 1 do
                    local on = set[x .. "," .. y] and x <= maxX
                    if on and not runStart then
                        runStart = x
                    elseif not on and runStart then
                        if #rects < ROOM_POOL - 1 then
                            rects[#rects + 1] = { gx = runStart, gy = y,
                                sx = x - runStart, sy = 1, hint = isHint }
                        else
                            full = true
                        end
                        runStart = nil
                    end
                end
            end
        end
        BuildRuns(rhint, true) -- hints first = drawn underneath
        BuildRuns(rocc, false)
        if full then Log("WARNING: pool full - map partially drawn (raise ROOM_POOL)") end
        rects[#rects + 1] = { gx = -1, gy = -1, sx = 2, sy = 2, start = true }
        geo = { runId = RunId(d), actX = al.X, actY = al.Y, actZ = al.Z, tile = tile,
                addr = d:GetAddress(),
                name = d:GetFullName(), stats = stats, rot = rot, aq = aq,
                ang = ROT_ANGLE[(rot + aq) % 4], yaw = yaw, ext = nExt, occ = rocc }
    end)
    if not rects or #rects <= 1 then return nil end
    return rects, geo
end

-- --------------------------------------------------------------- widget build
local function RemoveStrays()
    local removed = 0
    pcall(function()
        local widgets = FindAllOf("UserWidget")
        if not widgets then return end
        for _, w in ipairs(widgets) do
            pcall(function()
                if w:IsValid() then
                    local rt = w.WidgetTree.RootWidget
                    if rt and rt:IsValid()
                        and rt:GetFName():ToString():find("GRMM_Canvas", 1, true) then
                        w:RemoveFromParent()
                        removed = removed + 1
                    end
                end
            end)
        end
    end)
    if removed > 0 then Log("removed " .. removed .. " stray widget(s)") end
end

local function DropWidget()
    pcall(function()
        if W.widget and W.widget:IsValid() then W.widget:RemoveFromParent() end
    end)
    W.widget = nil
    W.pool = nil
    W.team = nil
    S.built = false
    S.visible = false
    S.dungAddr = nil
    S.rects = nil
end

local function Build()
    local pc = C.pc
    if not pc or not pc:IsValid() then return false end

    RemoveStrays()

    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local uwClass = StaticFindObject("/Script/UMG.UserWidget")
    local canvasClass = StaticFindObject("/Script/UMG.CanvasPanel")
    local imgClass = StaticFindObject("/Script/UMG.Image")
    if not (wbl and wbl:IsValid() and uwClass and uwClass:IsValid()
            and canvasClass and canvasClass:IsValid() and imgClass and imgClass:IsValid()) then
        Log("build failed: UMG classes not found")
        return false
    end

    local widget = wbl:Create(pc, uwClass, pc)
    if not widget or not widget:IsValid() then
        -- stale or remote controller? re-resolve the local one and retry once
        local fresh = GetLocalPC()
        if fresh and fresh:IsValid() and fresh:GetAddress() ~= pc:GetAddress() then
            C.pc = fresh
            pc = fresh
            widget = wbl:Create(pc, uwClass, pc)
        end
    end
    if not widget or not widget:IsValid() then
        local pcName = "?"
        pcall(function() pcName = pc:GetFullName() end)
        Log("build failed: could not create UserWidget (pc=" .. pcName .. ")")
        return false
    end
    local wt = widget.WidgetTree
    if not wt or not wt:IsValid() then
        Log("build failed: widget has no WidgetTree")
        return false
    end

    local canvas = StaticConstructObject(canvasClass, wt, FName("GRMM_Canvas"))
    if not canvas or not canvas:IsValid() then
        Log("build failed: could not construct CanvasPanel")
        return false
    end
    wt.RootWidget = canvas

    local bg = StaticConstructObject(imgClass, wt, FName("GRMM_BG"))
    local bgSlot = canvas:AddChildToCanvas(bg)

    local pool = {}
    for i = 1, ROOM_POOL do
        local img = StaticConstructObject(imgClass, wt, FName("GRMM_R" .. i))
        if img and img:IsValid() then
            local slot = canvas:AddChildToCanvas(img)
            img:SetVisibility(1)
            pool[#pool + 1] = { img = img, slot = slot }
        end
    end

    -- teammate markers: above rooms/trail, below your own marker
    local team = {}
    for i = 1, TEAM_POOL do
        local img = StaticConstructObject(imgClass, wt, FName("GRMM_T" .. i))
        if img and img:IsValid() then
            local slot = canvas:AddChildToCanvas(img)
            img:SetVisibility(1)
            team[#team + 1] = { img = img, slot = slot }
        end
    end

    local halo = StaticConstructObject(imgClass, wt, FName("GRMM_Halo"))
    local haloSlot = canvas:AddChildToCanvas(halo)
    local marker = StaticConstructObject(imgClass, wt, FName("GRMM_Marker"))
    local markerSlot = canvas:AddChildToCanvas(marker)

    S.anchoredRight = pcall(function()
        local anchors = { Minimum = { X = 1.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 0.0 } }
        bgSlot:SetAnchors(anchors)
        haloSlot:SetAnchors(anchors)
        markerSlot:SetAnchors(anchors)
        for _, e in ipairs(pool) do e.slot:SetAnchors(anchors) end
        for _, e in ipairs(team) do e.slot:SetAnchors(anchors) end
    end)

    pcall(function()
        bg:SetColorAndOpacity(BG_COLOR)
        halo:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = 0.85 })
        marker:SetColorAndOpacity(MARKER_COLOR)
    end)

    widget:AddToViewport(50)
    widget:SetVisibility(1)

    W.widget, W.canvas, W.bg, W.marker = widget, canvas, bg, marker
    W.halo, W.haloSlot = halo, haloSlot
    W.bgSlot, W.markerSlot, W.pool, W.team = bgSlot, markerSlot, pool, team
    S.built = true
    Log("widget built (" .. #pool .. " run slots, anchor="
        .. (S.anchoredRight and "top-right" or "top-left") .. ")")
    return true
end

local function WidgetValid()
    return S.built and W.widget and W.widget:IsValid()
end

-- ------------------------------------------------------------------- layout
local function TileToPx(gx, gy, spanX, spanY)
    local L = S.lay
    if not L then return nil end
    local nx, ny = gx - L.minX, gy - L.minY
    if MIRROR_X then nx = L.w - nx - spanX end
    return L.ox + nx * L.scale, L.oy + ny * L.scale
end

local function ApplyLayout()
    if S.anchoredRight then
        S.baseX = -(MARGIN + S.size)
        S.baseY = MARGIN
    else
        S.baseX = MARGIN
        S.baseY = MARGIN
    end
    -- background panel removed: collapse it and let the map float
    pcall(function() W.bg:SetVisibility(1) end)
    if not S.rects then return end

    local minX, minY, maxX, maxY
    for _, r in ipairs(S.rects) do
        local ax, ay = r.gx, r.gy
        local bx, by = r.gx + r.sx, r.gy + r.sy
        minX = (not minX or ax < minX) and ax or minX
        minY = (not minY or ay < minY) and ay or minY
        maxX = (not maxX or bx > maxX) and bx or maxX
        maxY = (not maxY or by > maxY) and by or maxY
    end
    minX, minY, maxX, maxY = minX - 1, minY - 1, maxX + 1, maxY + 1
    local w, h = maxX - minX, maxY - minY
    local span = (w > h) and w or h
    local scale = S.size / span
    S.lay = {
        minX = minX, minY = minY, w = w, h = h, scale = scale,
        ox = S.baseX + (S.size - w * scale) / 2,
        oy = S.baseY + (S.size - h * scale) / 2,
    }

    pcall(function()
        -- two draw passes from one pool: pass 1 = dark OUTLINE rects (each
        -- room/hint run expanded on all sides), pass 2 = the fills. Interior
        -- outline overhangs are painted over by neighboring fills, so only
        -- true boundary edges keep their outline.
        local inset = math.min(1.5, scale * INSET_FRAC)
        local t = math.max(1.0, scale * OUTLINE_FRAC)
        local draw = {}
        for _, r in ipairs(S.rects) do
            if not r.trail and not r.start then
                draw[#draw + 1] = { r = r, ol = true }
            end
        end
        for _, r in ipairs(S.rects) do
            if SHOW_TRAIL or not r.trail then
                draw[#draw + 1] = { r = r }
            end
        end
        for i, e in ipairs(W.pool) do
            local d = draw[i]
            if d then
                local r = d.r
                local px, py = TileToPx(r.gx, r.gy, r.sx, r.sy)
                if d.ol then
                    e.slot:SetPosition({ X = px - t, Y = py - t })
                    e.slot:SetSize({ X = r.sx * scale + 2 * t, Y = r.sy * scale + 2 * t })
                    e.img:SetColorAndOpacity(OUTLINE_COLOR)
                else
                    local ins = r.trail and inset or 0
                    e.slot:SetPosition({ X = px + ins, Y = py + ins })
                    e.slot:SetSize({ X = r.sx * scale - 2 * ins, Y = r.sy * scale - 2 * ins })
                    e.img:SetColorAndOpacity(r.start and START_COLOR
                        or (r.trail and ((r.band or 0) == (S.band or 0)
                            and TRAIL_COLOR or TRAIL_OTHER_FLOOR))
                        or (r.hint and HINT_COLOR)
                        or ROOM_COLOR)
                end
                e.img:SetVisibility(3)
            else
                e.img:SetVisibility(1)
            end
        end
        local m = MARKER_PX * (S.size / MAP_SIZE)
        W.markerSlot:SetSize({ X = m, Y = m })
    end)
end

-- cheap change signature: dungeons can grow mid-run
local function DungeonSig(d)
    local n1, n2, n3 = 0, 0, 0
    pcall(function() n1 = #d.Rooms end)
    pcall(function() n2 = #d.Connections end)
    pcall(function() n3 = #d.CustomRooms end)
    -- run id included so a regenerated run ALWAYS reads as changed, even if
    -- the room counts happen to match the previous run
    return n1 .. ":" .. n2 .. ":" .. n3 .. ":" .. RunId(d)
end

local function EnsureMapData()
    local d = GetActiveDungeon()
    if not d or not d:IsValid() then
        return S.rects ~= nil
    end
    local addr = d:GetAddress()
    local sig = DungeonSig(d)
    -- rotation can be detected LATE (elevator actor streams in after the map
    -- is first bound); re-check it every rebind and rebuild on change,
    -- otherwise a wrong early rotation sticks for the whole run
    if addr == S.dungAddr and S.rects and S.geo then
        local rot, yaw = DetectRotation({ X = S.geo.actX, Y = S.geo.actY }, S.geo.tile, S.geo.aq)
        if yaw ~= nil and rot ~= S.geo.rot then
            Log(string.format("rotation corrected %d -> %d (elevator now detected)",
                S.geo.rot, rot))
            S.dungSig = nil -- force re-parse below
            S.visited = {} -- old trail tiles are in the wrong frame
        end
    end
    if addr == S.dungAddr and S.rects and sig == S.dungSig then return true end
    local rects, geo = ParseDungeon(d)
    if not rects then return S.rects ~= nil end
    -- the game REUSES the same dungeon actor across runs (regenerates in
    -- place), so a new RUN is detected by CurrentSeed (seed@level) changing,
    -- not by the actor address - otherwise last run's trail bleeds through
    if addr ~= S.dungAddr or not S.geo or geo.runId ~= S.geo.runId then
        if S.geo and geo.runId ~= S.geo.runId then
            Log("new run detected (" .. tostring(geo.runId) .. ") - trail cleared")
        end
        S.visited = {}
    end
    S.rects, S.geo, S.dungAddr, S.dungSig = rects, geo, addr, sig
    -- re-add explored static tiles (kept across re-parses of the same dungeon)
    if S.visited then
        for key, band in pairs(S.visited) do
            if not geo.occ[key] and #S.rects < ROOM_POOL then
                local x, y = key:match("^(-?%d+),(-?%d+)$")
                table.insert(S.rects, #S.rects, -- before the elevator square
                    { gx = tonumber(x), gy = tonumber(y), sx = 1, sy = 1,
                      trail = true, band = (band ~= true) and band or 0 })
            end
        end
    end
    ApplyLayout()
    Log(string.format("map built: %d runs, rot=%d aq=%d (elev yaw=%s), ext=%d",
        #rects, geo.rot, geo.aq, tostring(geo.yaw), geo.ext))
    return true
end

-- ------------------------------------------------------------- marker update
local function UpdateMarker()
    if not (S.visible and WidgetValid() and S.geo and S.lay) then return end
    local pawn = C.pawn
    if not pawn or not pawn:IsValid() then return end
    local loc = pawn:K2_GetActorLocation()

    local now = os.clock()
    if now - S.lastRebind > REBIND_INTERVAL then
        S.lastRebind = now
        EnsureMapData()
    end

    -- world offset -> grid (undo dungeon actor yaw) -> screen rotation,
    -- then the live-tunable calibration offset (Home/End/Delete/Insert)
    local gx = (loc.X - S.geo.actX) / S.geo.tile
    local gy = (loc.Y - S.geo.actY) / S.geo.tile
    gx, gy = RotPoint(S.geo.aq, gx, gy)
    gx, gy = RotPoint(S.geo.rot, gx, gy)
    gx, gy = gx + S.calX, gy + S.calY

    -- floor band from height: trail on your current floor draws bright,
    -- other floors dim (multi-level dungeons overlap in 2D). Anchored to
    -- your SPAWN height (rooms on one floor vary in height, so the dungeon
    -- actor Z is a bad reference), with hysteresis so stairs/jumps/uneven
    -- rooms don't flicker the band
    if not S.geo.baseZ then S.geo.baseZ = loc.Z end
    local rel = loc.Z - S.geo.baseZ
    local target = math.floor(rel / FLOOR_BAND + 0.5)
    if target ~= S.band
        and math.abs(rel - target * FLOOR_BAND) < FLOOR_BAND * 0.35 then
        S.band = target
        ApplyLayout() -- recolor trail tiles for the new floor
    end
    local band = S.band

    -- auto-map static geometry: walking through a tile no dungeon array
    -- describes adds it to the map in the trail shade
    local tx, ty = math.floor(gx), math.floor(gy)
    local tkey = tx .. "," .. ty
    if SHOW_TRAIL and tkey ~= S.lastTileKey then
        S.lastTileKey = tkey
        S.visited = S.visited or {}
        if not S.visited[tkey] and not S.geo.occ[tkey] then
            S.visited[tkey] = band
            if S.rects and #S.rects < ROOM_POOL then
                table.insert(S.rects, #S.rects,
                    { gx = tx, gy = ty, sx = 1, sy = 1, trail = true, band = band })
                ApplyLayout()
            end
        elseif not S.visited[tkey] then
            S.visited[tkey] = band
        end
    end

    local px, py = TileToPx(gx, gy, 0, 0)
    if not px then return end
    local lo, hi = S.baseX, S.baseX + S.size
    if px < lo then px = lo elseif px > hi then px = hi end
    if py < S.baseY then py = S.baseY elseif py > S.baseY + S.size then py = S.baseY + S.size end
    local m = MARKER_PX * (S.size / MAP_SIZE)
    W.markerSlot:SetPosition({ X = px - m / 2, Y = py - m / 2 })
    local yaw = 0
    pcall(function() yaw = C.pc:GetControlRotation().Yaw end)
    local ang = yaw + S.geo.ang
    if MIRROR_X then ang = 180 - ang end
    W.marker:SetRenderTransformAngle(ang)
    pcall(function()
        local h = m + 4
        W.haloSlot:SetPosition({ X = px - h / 2, Y = py - h / 2 })
        W.haloSlot:SetSize({ X = h, Y = h })
        W.halo:SetRenderTransformAngle(ang)
    end)

    -- teammates: every pawn in the replicated PlayerArray except our own,
    -- tinted with that player's replicated spark color
    if SHOW_TEAMMATES and W.team then
        local used = 0
        pcall(function()
            if not (C.gs and C.gs:IsValid()) then return end
            local arr = C.gs.PlayerArray
            local myAddr = pawn:GetAddress()
            local num = 0
            pcall(function() num = #arr end)
            for i = 1, num do
                pcall(function()
                    local ps = arr[i]
                    if not (ps and ps:IsValid()) then return end
                    local pw = ps.PawnPrivate
                    if not (pw and pw:IsValid()) then return end
                    if pw:GetAddress() == myAddr then return end
                    local l = pw:K2_GetActorLocation()
                    local tx = (l.X - S.geo.actX) / S.geo.tile
                    local ty = (l.Y - S.geo.actY) / S.geo.tile
                    tx, ty = RotPoint(S.geo.aq, tx, ty)
                    tx, ty = RotPoint(S.geo.rot, tx, ty)
                    tx, ty = tx + S.calX, ty + S.calY
                    local tpx, tpy = TileToPx(tx, ty, 0, 0)
                    if not tpx then return end
                    if tpx < lo then tpx = lo elseif tpx > hi then tpx = hi end
                    if tpy < S.baseY then tpy = S.baseY
                    elseif tpy > S.baseY + S.size then tpy = S.baseY + S.size end
                    local e = W.team[used + 1]
                    if not e then return end
                    used = used + 1
                    local m2 = TEAM_MARKER_PX * (S.size / MAP_SIZE)
                    e.slot:SetPosition({ X = tpx - m2 / 2, Y = tpy - m2 / 2 })
                    e.slot:SetSize({ X = m2, Y = m2 })
                    local cr, cg, cb
                    -- GetPlayerColor returns 0-1 floats (confirmed via F9
                    -- diagnostic 2026-08-13), NOT 0-255 bytes - dividing by
                    -- 255 was what rendered markers black
                    pcall(function()
                        local c = ps:GetPlayerColor()
                        local r, g, b = c.R, c.G, c.B
                        if r + g + b > 0.001 then
                            if r > 1.001 or g > 1.001 or b > 1.001 then
                                r, g, b = r / 255, g / 255, b / 255
                            end
                            cr, cg, cb = r, g, b
                        end
                    end)
                    if not cr or (cr == 0 and cg == 0 and cb == 0) then
                        local pal = TEAM_FALLBACK[(used - 1) % #TEAM_FALLBACK + 1]
                        cr, cg, cb = pal[1], pal[2], pal[3]
                    end
                    e.img:SetColorAndOpacity({ R = cr, G = cg, B = cb, A = 1.0 })
                    e.img:SetVisibility(3)
                end)
            end
        end)
        for i = used + 1, #W.team do
            pcall(function() W.team[i].img:SetVisibility(1) end)
        end
    end
end

-- ------------------------------------------------------------ per-frame hook
-- The marker update is instance-agnostic: ANY hooked anim tick drives it
-- (throttled), so the local player is tracked even when their own pawn has
-- no hooked anim BP (spark mode) as long as any character is animating.
local function OnAnimTick()
    if S.errCount >= 8 then return end
    local ok, err = pcall(function()
        if not S.visible then return end
        local now = os.clock()
        if now - (S.lastUpd or 0) < 0.02 then return end
        if not CacheValid() then
            if now - C.lastTry < 1.0 then return end
            C.lastTry = now
            if not RefreshCache() then return end
        elseif now - (C.lastPawnCheck or 0) > 1.0 then
            -- the controller can swap pawns while the old body stays a valid
            -- object (vessel dies -> spark): follow the controller's pawn
            C.lastPawnCheck = now
            pcall(function()
                local cur = C.pc.Pawn
                if cur and cur:IsValid()
                    and cur:GetAddress() ~= C.pawn:GetAddress() then
                    Log("pawn changed (spark/repossess) - retargeting marker")
                    RefreshCache()
                end
            end)
        end
        if not WidgetValid() then
            DropWidget()
            return
        end
        S.lastUpd = now
        UpdateMarker()
    end)
    if not ok then
        S.errCount = S.errCount + 1
        Log("frame ERROR (" .. S.errCount .. "/8): " .. tostring(err))
        if S.errCount >= 8 then
            Log("too many errors - MiniMap disabled, Ctrl+R to retry")
        end
    end
end

local function TryRegisterHook()
    RegisterHook("/Game/Animation/ABP_HeldenPlayer.ABP_HeldenPlayer_C:BlueprintUpdateAnimation",
        function(self, DeltaTimeX) OnAnimTick() end)
    HookedAnimClasses["/Game/Animation/ABP_HeldenPlayer.ABP_HeldenPlayer_C"] = true
end

-- hook the anim blueprint of whatever pawn the player currently controls
-- (vessel, spark, ...) so its ticks also drive updates
HookAnimClassOf = function(pawn)
    pcall(function()
        local inst = pawn.Mesh.AnimScriptInstance
        if not inst or not inst:IsValid() then return end
        local full = inst:GetClass():GetFullName()
        local path = full:match("%s(.+)$")
        if not path or HookedAnimClasses[path] then return end
        HookedAnimClasses[path] = true
        local ok = pcall(function()
            RegisterHook(path .. ":BlueprintUpdateAnimation",
                function(self, DeltaTimeX) OnAnimTick() end)
        end)
        Log("anim hook for pawn class " .. path .. (ok and " registered" or " FAILED"))
    end)
end

local function EnsureHook()
    if Hooked then return true end
    local ok, err = pcall(TryRegisterHook)
    if ok then
        Hooked = true
        Log("anim-update hook registered")
    else
        Log("hook registration failed (will retry): " .. tostring(err))
    end
    return Hooked
end

-- ----------------------------------------------------------------- controls
local function Toggle()
    if not CacheValid() and not RefreshCache() then
        Log("toggle: no local player yet")
        return
    end
    if not WidgetValid() then
        DropWidget()
        if not Build() then return end
    end
    if not S.visible then
        if not EnsureMapData() then
            Log("no dungeon map available here (not inside a dungeon?)")
            return
        end
        EnsureHook()
        S.visible = true
        W.widget:SetVisibility(3)
        UpdateMarker()
    else
        S.visible = false
        W.widget:SetVisibility(1)
    end
end

RegisterKeyBind(TOGGLE_KEY, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(Toggle)
        if not ok then Log("toggle ERROR: " .. tostring(err)) end
    end)
end)

local function Resize(delta)
    if not WidgetValid() then return end
    local n = S.size + delta
    if n < SIZE_MIN then n = SIZE_MIN elseif n > SIZE_MAX then n = SIZE_MAX end
    if n == S.size then return end
    S.size = n
    ApplyLayout()
    UpdateMarker()
end

pcall(function()
    RegisterKeyBind(Key.ADD, function()
        ExecuteInGameThread(function() pcall(Resize, SIZE_STEP) end)
    end)
    RegisterKeyBind(Key.SUBTRACT, function()
        ExecuteInGameThread(function() pcall(Resize, -SIZE_STEP) end)
    end)
end)

-- live calibration: nudge marker+trail in quarter-tile steps on screen.
-- Home = up, End = down, Delete = left, Insert = right. Read values with F9.
local function Nudge(dx, dy)
    S.calX = S.calX + dx
    S.calY = S.calY + dy
    Log(string.format("calibration offset: (%.2f, %.2f) screen tiles", S.calX, S.calY))
    pcall(UpdateMarker)
end

do
    local n = 0
    local function BindNudge(names, dx, dy)
        for _, name in ipairs(names) do
            local key = Key[name]
            if key then
                local ok = pcall(function()
                    RegisterKeyBind(key, function()
                        ExecuteInGameThread(function() pcall(Nudge, dx, dy) end)
                    end)
                end)
                if ok then n = n + 1 return end
            end
        end
        Log("WARNING: no key found for nudge (" .. table.concat(names, "/") .. ")")
    end
    BindNudge({ "HOME" }, 0, -0.25)
    BindNudge({ "END" }, 0, 0.25)
    BindNudge({ "DEL", "DELETE" }, -0.25, 0)
    BindNudge({ "INS", "INSERT" }, 0.25, 0)
    Log("nudge keys registered: " .. n .. "/4")
end

RegisterKeyBind(Key.F9, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            Log("=== debug ===")
            Log("built=" .. tostring(S.built) .. " visible=" .. tostring(S.visible)
                .. " hooked=" .. tostring(Hooked) .. " errs=" .. S.errCount
                .. " size=" .. S.size .. " runs=" .. (S.rects and #S.rects or 0))
            if S.geo then
                Log(string.format("rot=%d aq=%d ang=%.0f elevYaw=%s ext=%d",
                    S.geo.rot, S.geo.aq or 0, S.geo.ang, tostring(S.geo.yaw), S.geo.ext or 0))
            end
            Log(string.format("CALIBRATION: calX=%.2f calY=%.2f (report these!)",
                S.calX, S.calY))
            local p = PawnPos()
            if p and S.geo then
                local gx = (p.X - S.geo.actX) / S.geo.tile
                local gy = (p.Y - S.geo.actY) / S.geo.tile
                gx, gy = RotPoint(S.geo.aq or 0, gx, gy)
                local rx, ry = RotPoint(S.geo.rot, gx, gy)
                Log(string.format(
                    "pawn=(%.0f, %.0f, %.0f)  grid=(%.1f, %.1f)  rotated=(%.1f, %.1f)  band=%d",
                    p.X, p.Y, p.Z, gx, gy, rx, ry, S.band or 0))
            end
            -- teammate color diagnostic
            pcall(function()
                if not (C.gs and C.gs:IsValid()) then return end
                local arr = C.gs.PlayerArray
                for i = 1, #arr do
                    pcall(function()
                        local ps = arr[i]
                        local nm = "?"
                        pcall(function() nm = ps.PlayerNamePrivate:ToString() end)
                        local raw, lin = "err", "err"
                        pcall(function()
                            local c = ps:GetPlayerColor()
                            raw = string.format("%s,%s,%s", tostring(c.R), tostring(c.G), tostring(c.B))
                        end)
                        pcall(function()
                            local ml = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
                            local lc = ml:Conv_ColorToLinearColor(ps:GetPlayerColor())
                            lin = string.format("%.2f,%.2f,%.2f", lc.R, lc.G, lc.B)
                        end)
                        Log(string.format("player %s: rawColor=(%s) linear=(%s)", nm, raw, lin))
                    end)
                end
            end)
            if S.geo and S.geo.stats then
                local parts = {}
                for t, n in pairs(S.geo.stats) do
                    parts[#parts + 1] = t .. ":" .. n
                end
                Log("part types (type:count): " .. table.concat(parts, "  "))
            end
        end)
        if not ok then Log("F9 ERROR: " .. tostring(err)) end
    end)
end)

-- F8: room list + ASCII occupancy dump (rotated, same as render) with pawn P
RegisterKeyBind(Key.F8, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local d = GetActiveDungeon()
            if not d or not d:IsValid() then Log("F8: no active dungeon") return end
            local names = {}
            local rects, geo = ParseDungeon(d, names)
            if not rects then Log("F8: no grid data") return end
            local p = PawnPos()
            Log("=== grid dump ===")
            Log(string.format("actor=(%.0f, %.0f)  tile=%.0f  runs=%d  rot=%d  elevYaw=%s  ext=%d",
                geo.actX, geo.actY, geo.tile, #rects, geo.rot, tostring(geo.yaw), geo.ext))
            Log("legend: # room  + hint  S elevator  @ walked-room  * walked-hint  o walked-only  P you")
            for _, n in ipairs(names) do Log("  " .. n) end
            local occ, minGX, minGY, maxGX, maxGY = {}, nil, nil, nil, nil
            for _, r in ipairs(rects) do
                for x = r.gx, r.gx + r.sx - 1 do
                    for y = r.gy, r.gy + r.sy - 1 do
                        occ[x .. "," .. y] = r.start and "S" or (r.hint and "+" or "#")
                    end
                end
                minGX = (not minGX or r.gx < minGX) and r.gx or minGX
                minGY = (not minGY or r.gy < minGY) and r.gy or minGY
                local ex, ey = r.gx + r.sx - 1, r.gy + r.sy - 1
                maxGX = (not maxGX or ex > maxGX) and ex or maxGX
                maxGY = (not maxGY or ey > maxGY) and ey or maxGY
            end
            -- overlay walked trail: '@' = walked AND drawn (agreement),
            -- 'o' = walked but NOT drawn. Aligned maps show corridors as '@';
            -- a mirror/offset shows parallel 'o' lines next to '#' corridors.
            if S.visited and S.dungAddr == geo.addr then
                for key in pairs(S.visited) do
                    local x, y = key:match("^(-?%d+),(-?%d+)$")
                    if x then
                        local c = occ[key]
                        if c == "#" then occ[key] = "@" -- walked + confirmed
                        elseif c == "+" then occ[key] = "*" -- walked + hint
                        elseif c ~= "S" then occ[key] = "o" end -- walked only
                        x, y = tonumber(x), tonumber(y)
                        minGX = (not minGX or x < minGX) and x or minGX
                        minGY = (not minGY or y < minGY) and y or minGY
                        maxGX = (not maxGX or x > maxGX) and x or maxGX
                        maxGY = (not maxGY or y > maxGY) and y or maxGY
                    end
                end
            end
            local pgx, pgy
            if p then
                local gx = (p.X - geo.actX) / geo.tile
                local gy = (p.Y - geo.actY) / geo.tile
                Log(string.format("pawn RAW grid=(%.2f, %.2f)", gx, gy))
                gx, gy = RotPoint(geo.aq, gx, gy)
                local rx, ry = RotPoint(geo.rot, gx, gy)
                rx, ry = rx + S.calX, ry + S.calY
                pgx, pgy = math.floor(rx), math.floor(ry)
                Log(string.format("pawn rotated grid=(%d, %d)  liveRot=%s dumpRot=%d aq=%d",
                    pgx, pgy, S.geo and S.geo.rot or "?", geo.rot, geo.aq))
            end
            for y = minGY, maxGY do
                local row = {}
                for x = minGX, maxGX do
                    local ch = occ[x .. "," .. y] or "."
                    if pgx == x and pgy == y then ch = "P" end
                    row[#row + 1] = ch
                end
                Log("| " .. table.concat(row))
            end
        end)
        if not ok then Log("F8 ERROR: " .. tostring(err)) end
    end)
end)

pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self)
        C.animAddr = nil
        C.lastTry = 0
        C.gs = nil
        pcall(function()
            if not (W.widget and W.widget:IsValid()) then DropWidget() end
        end)
    end)
end)

ExecuteInGameThread(function()
    pcall(RemoveStrays)
end)

Log("v28 loaded (tracer dots removed). M = toggle, +/- = resize, Home/End/Del/Ins = nudge, F9 = debug, F8 = dump.")
