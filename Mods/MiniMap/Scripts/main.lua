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
-- backing panel disabled: the thick dark outlines carry the contrast even
-- at max gamma (confirmed by testing); the map floats clean over the game
local BG_COLOR = { R = 0.015, G = 0.03, B = 0.05, A = 0.0 }
local BG_PAD = 8
local OUTLINE_COLOR = { R = 0.55, G = 0.90, B = 0.80, A = 0.95 } -- seafoam edge
local OUTLINE_FRAC = 0.16 -- border thickness as a fraction of tile size
local ROOM_COLOR = { R = 0.16, G = 0.42, B = 0.37, A = 0.30 } -- deep glass
local START_COLOR = { R = 0.35, G = 1.0, B = 0.6, A = 0.85 } -- spawn elevator
-- tiles you walked through that no dungeon array describes (static level
-- geometry like stair hallways) get auto-mapped in this shade
-- v79: walked tiles in areas no data source describes get drawn as ordinary
-- floor, so the map completes itself where the ice cave and similar
-- unenumerable geometry live. Independent of SHOW_TRAIL (route dots).
-- DEFAULT OFF (v86): same A/B. Note this is the only source that can ever
-- draw the ice cave, so switch it on with F2 when exploring unmapped areas.
local FILL_UNMAPPED = false
local SHOW_TRAIL = false -- explored-tile tracer dots (off for release)
local TRAIL_COLOR = { R = 0.3, G = 0.75, B = 0.62, A = 0.66 } -- teal
-- trail tiles on a DIFFERENT floor than you are on right now
local TRAIL_OTHER_FLOOR = { R = 0.16, G = 0.32, B = 0.38, A = 0.5 }
local FLOOR_BAND = 600 -- world units of height per floor band
-- rooms with no per-tile part data only report a bounding box (often much
-- bigger than the real room); shown dim until you actually walk them
-- these are REAL rooms (they appear on the game's own table map), just with
-- bounding-box precision - drawn as a clearly visible mid-tone layer
-- these are real rooms (the game's own table map draws them), we just only
-- know their bounding box - so they render exactly like every other room:
-- one uniform map, the way the in-game map reads
-- v75: recover prefab-room interiors from ordinary StaticMeshActors. Runs
-- only when a prefab box is still unresolved after the floor pass, so on a
-- normal dungeon this costs nothing. Budget guards against the full-sweep
-- freezes this game is prone to; the scan logs its own duration.
local PREFAB_MESH_SCAN = true
local PREFAB_SCAN_BUDGET = 4000
-- Manual F7 probe: max tiles to test (2 reflection calls each).
-- NOTE this was omitted once because an "is it already added?" grep matched
-- the CONSTANT'S USAGE rather than its definition, leaving it nil - and
-- `tested >= nil` threw inside a pcall, so the probe died silently after
-- printing its header. Guard on the definition (`^local NAME`), not the name.
-- v83: navmesh as a floor source. Proven by the F7 probe to find the
-- corridors no mesh source exposes. Z extent is generous so a tile is still
-- found when the pawn stands a floor above or below it.
-- DEFAULT OFF (v86): user A/B-d all four source combinations across five
-- cycles and judged "rooms + floor meshes" the most accurate every time.
-- Navmesh contributed only 46 tiles once tuned safe and degraded the shape.
-- Kept behind F2 - the probe evidence that it SEES real corridors stands.
local NAVMESH_FILL = false
local NAV_FILL_MARGIN = 3     -- tiles beyond the known bbox to probe
local NAV_QUERY_XY = 25.0   -- tight horizontal query; big extents snap
local NAV_SNAP_MAX = 60.0   -- reject if projection moved further than this
local NAV_FILL_Z = 400.0      -- vertical tolerance of the projection
local NAV_PROBE_BUDGET = 2500
local PREFAB_DROP_EMPTY = true  -- stop drawing boxes with no geometry at all
local PREFAB_COMP_BUDGET = 20000  -- component fallback; ~4us per position test
local PREFAB_BOX_REPLACE = 0.20  -- fraction of a box that must be covered
                                 -- before its coarse outline is dropped;
                                 -- lower than the floor threshold because
                                 -- prop meshes are sparser than floor tiles
-- v73: prefab rooms that got NO floor data stay coarse bounding boxes, and
-- those boxes are much bigger than the real room. Drawn in the same colour as
-- real floor they read as a room you are standing inside when you are still in
-- the corridor outside (user hit exactly that 2026-08-18 on the big circular
-- room). Dimmer + more transparent so "approximate" is visible at a glance.
local HINT_COLOR = { R = 0.13, G = 0.28, B = 0.26, A = 0.07 }
-- purpose-built rooms (extract, elevator, objective) - the game's own map
-- shades these darker than plain corridors, so the layout reads at a glance
-- drawn OVER the normal fill, so a dark, fairly opaque wash is what actually
-- reads as "this room is different". The old brighter tint was invisible.
local SPECIAL_COLOR = { R = 0.02, G = 0.10, B = 0.09, A = 0.50 }
-- EHeldenDungeonRoomType, pinned from F8 dumps taken standing in the elevator
-- and extractor rooms (2026-08-17): 0/3 = generated rooms, 1 = corridors,
-- 2 = the game's hand-built prefab rooms (elevator, extract/crusher and
-- friends - always parts=0, bounding-box only). Shading 2 marks exactly the
-- purpose-built rooms, the way the in-game map calls them out.
local SPECIAL_TYPES = { [2] = true }
-- ---------------------- true floor from placed meshes ---------------------
-- The generator builds the dungeon out of instanced static meshes, and the
-- floor pieces are exactly one tile each (SM_DungeonFloor01_200x200). Reading
-- their positions gives the REAL walkable footprint of every room - including
-- the hand-built prefab rooms the room grid only describes as a bounding box.
-- This is local, available as soon as the dungeon exists, and needs no map to
-- be placed. Read via the reflected PerInstanceSMData array; the
-- GetInstanceTransform function exists but UE4SS cannot marshal its output.
-- v68: floor meshes back ON. They are the fix for the mod's real quality gap -
-- prefab (type=2) rooms report NO per-tile data, so they draw as crude
-- bounding boxes; the floor instances carry their true shape. Re-enabled after
-- the F7 probe read 2595 instances / 387 distinct tiles cleanly, and after
-- finding that this collector was adding the component location on top of an
-- already-world-space translation (see FLOOR_ADD_COMPONENT_LOC below).
local FLOOR_ADD_COMPONENT_LOC = false
-- Validity gate. The OLD test asked what fraction of floor tiles coincide with
-- rooms we already knew - but the whole point is to reveal geometry we DON'T
-- have, so it scored ~14% on good data and threw it away. The right question
-- is whether the tiles land inside the dungeon's known FOOTPRINT at all
-- (rooms OR the prefab bounding boxes); a broken transform scatters them far
-- outside it.
local FLOOR_MIN_INSIDE = 0.80
-- Drop floor tiles that fall outside every known room AND every prefab box.
-- Those are 200x200 pieces tucked under walls or spilling past doorways, and
-- drawing them made corridors read wider than they are in game. Tiles inside
-- a prefab box are KEPT - recovering those interiors is the whole point.
local FLOOR_CLIP_STRAYS = true
-- a prefab box is replaced by real floor only when floor actually covers it,
-- so thin floor data can never make a room vanish
local FLOOR_BOX_REPLACE = 0.35
local USE_FLOOR_MESHES = true -- was OFF: instance transforms never resolved to
-- world space correctly (7% overlap with the real rooms), so the data is not
-- trustworthy. The sanity gate below rejects it anyway; the flag just avoids
-- paying for the scan. F7 still probes it if we ever want to revisit.
local FLOOR_MESH_MATCH = "floor" -- mesh name must contain this...
local FLOOR_MESH_REJECT = "roof" -- ...and must not contain this
local FLOOR_SCAN_BUDGET = 40000  -- max instances read in one scan
-- dungeon geometry can stream in, so rescan a few times early in a run
local FLOOR_RESCANS = 4
local FLOOR_RESCAN_SECS = 6

-- ------------------------- game's own map image ---------------------------
-- The dungeon ships a finished map picture - the one the table map and the
-- end-screen "YOUR JOURNEY" draw - and it knows the true footprint of the
-- prefab rooms our room-grid reconstruction can only bound-box. It is NOT
-- ready when the dungeon generates (TextureSize reads 0), so we keep looking
-- for it and drop it in underneath our vector layer once it appears.
-- IMPORTANT: only ever DRAW this texture. Reading its pixels back
-- (ReadRenderTargetPixel in a loop) hard-crashed the game on 2026-08-17.
local SHOW_MAP_TEXTURE = false -- OFF for good: see notes above the material flag
-- not align in every dungeon, and added visual noise over a map that reads
-- better without it. The code stays, flip to true to experiment.
local MAP_TEX_TINT = { R = 1.0, G = 1.0, B = 1.0, A = 0.85 } -- material supplies its own colour
local MAP_TEX_MATERIAL = "/Game/UI/Dungeon/M_HeldenMapWidget.M_HeldenMapWidget"
local MAP_TEX_PARAM = "MapTexture"
local MAP_TEX_USE_MATERIAL = true -- render via M_HeldenMapWidget, not raw
local MAP_TEX_USE_UVCROP = false -- material shows the FULL texture (crop made it smaller)
-- When the game map image is available, show ONLY it, with our marker placed
-- in the image own space - the way the other dev mod works. Two independently
-- derived maps can never be made to agree; one source always agrees with
-- itself. Our vector map stays as the fallback until the image exists.
local MAP_IMAGE_EXCLUSIVE = false -- M_HeldenMapWidget is the END-SCREEN
-- material: it renders the journey/trail view (dominated by stale player
-- history we do not own), not the live table map. The live map plane uses
-- M_HeldenMap, a surface material that cannot be used as a UMG brush. So the
-- game image cannot be reproduced as a live minimap through any path we have.
-- The placement rectangle is confirmed correct, but which way the texture's
-- own U/V axes run relative to the world is not derivable from the numbers.
-- F6 cycles all 8 combinations live (mirror X, mirror Y, extra quarter turn)
-- and logs the active one, so the right setting can just be seen and pinned.
TEX_MIRROR_X = false
TEX_MIRROR_Y = false
TEX_QUARTER = 2 -- calibrated live 2026-08-17: image needs a 180 turn
-- faint horizontal scanlines across the map, CRT style
local SCANLINES = true
local SCANLINE_SPACING = 3   -- screen px between lines (smaller = denser)
local SCANLINE_THICKNESS = 1.0
local SCANLINE_COLOR = { R = 0.62, G = 0.94, B = 0.85, A = 0.055 }
-- warm amber reads instantly against the seafoam map; the old near-white
-- mint was the same family as the room borders and disappeared into them
local MARKER_COLOR = { R = 1.0, G = 0.62, B = 0.18, A = 1.0 }
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
local MARKER_TRI_SEGS = 3 -- three bars = the three edges of a hollow triangle
local MARKER_LEN = 1.2    -- tip-to-tail length, in marker units
local MARKER_WIDTH = 1.05 -- width at the tail
local MARKER_STROKE = 0.2 -- outline thickness (kept up as the arrow shrank)
local SIZE_STEP = 40
local SIZE_MIN, SIZE_MAX = 140, 700
local REBIND_INTERVAL = 2.0
local ROOM_POOL = 2048 -- large icy dungeons alone can use ~250 runs; the rest is trail headroom
-- extra quarter-turns on top of the elevator-facing auto-rotation (0-3);
-- set to 2 if maps consistently render upside down
local ROT_EXTRA = 0
-- mirror after rotation, if left/right ends up swapped vs. reality
local MIRROR_X = false
-- ------------------------------------------- DungeonBounds / seed (v62)
-- AHeldenDungeonActor.DungeonBounds is an FHeldenOrientBox
-- {FVector Center; FVector Extents; FQuat Rotation} - the generator's own
-- oriented world box for the dungeon. Its quaternion carries the per-run
-- spin EXACTLY, where our world->grid quarter-turn is INFERRED by rounding
-- the dungeon actor's yaw. If those two ever disagree the whole map lands
-- rotated, which is the "verified correct one run, 180 degrees wrong the
-- next" bug we chased on 2026-08-11. Prefer the box; keep the actor yaw as
-- the fallback so an unreadable box can never make things worse.
local USE_BOUNDS_ROT = true
-- MapData.Seed records which run the map PICTURE was built for. The dungeon
-- actor is reused across runs and keeps the previous run's map until a new
-- one is revealed, so comparing that against CurrentSeed.Seed is an exact
-- staleness test - much better than asking whether the covered rect looks
-- plausible against the rooms we parsed.
local SEED_GUARD = true
-- ------------------------------------------- the game's own map widget (v63)
-- Stop reconstructing the dungeon and host the game's OWN map panel:
-- /Game/UI/Dungeon/WBP_DungoenEndMapWidget.WBP_DungoenEndMapWidget_C, which
-- the object dump shows is WBP_DungeonEndScreen_C:WidgetTree.MapWidget - the
-- map from the "YOUR JOURNEY" screen. It ships MapImage + PlayerHistoryRT +
-- DynamicMapMaterial already wired together, so we inherit the game's real
-- per-tile floor: interior walls, corridors and prefab rooms that our
-- rectangle reconstruction can only ever bounding-box. The shimmering border
-- is baked into M_HeldenMapWidget, which is why it comes along for free.
-- DEFAULT OFF (v70). The hosted picture is still misaligned - its placement
-- cannot be derived because LocationMin/Max and UVOffset/CoverPercent describe
-- mutually inconsistent regions (proven 2026-08-18). Leaving it ON meant that
-- the moment a player placed a map, GM_EXCLUSIVE hid the CORRECT vector map
-- and replaced it with the wrong picture - a regression against the shipped
-- behaviour. The vector map is now strictly better than it has ever been
-- (real floor in the prefab rooms), so it is the default and the picture is
-- an opt-in experiment behind F5.
local USE_GAME_MAP = false
-- when the image is up, hide the vector rectangles - two independently
-- derived maps can never be made to agree, one source always agrees with itself
local GM_EXCLUSIVE = true
-- the material's placement parameter. The rival dll sets exactly ONE vector
-- param ("UVOffset") while reading BOTH MapData.UVOffset and CoverPercent, so
-- the channels are very likely RG=offset BA=cover. INFERRED - if the picture
-- lands at the wrong scale or offset this packing is the first suspect.
local GM_UV_PARAM = "UVOffset"
local GM_PACK_COVER = true -- put CoverPercent in BA; false = leave BA at 1,1
-- history render target: wipe it so no previous run's route is drawn. Set
-- false to leave the game's own trail rendering alone.
local GM_CLEAR_TRAIL = true
-- Does the hosted panel show the FULL texture, or only the dungeon's
-- sub-rect? Decides how the marker maps into it, and it is the one thing
-- that cannot be settled from the log alone. Evidence for CROPPED (true):
-- the first live run reported cover=(0.531,0.438), so a full-texture view
-- would leave the dungeon occupying barely a quarter of the panel's area -
-- yet on screen it very nearly filled it. That means the material IS
-- honouring the UVOffset parameter. F2 flips it live if the marker is wrong.
local GM_MARKER_CROPPED = true
-- Size the picture from the dungeon's REAL extent (DungeonBounds) rather than
-- from LocationMin/Max, and allow for the texture's empty border. Calibrated
-- 2026-08-18: a 36x36-tile dungeon with a 32px texture needed exactly 1.200,
-- which is 36/(32-2) - i.e. a one-pixel border on each side. F11/F12 still
-- multiply on top, so they stay available if a dungeon disagrees.
-- v66 EXPERIMENT: strip the stack back to the simplest model that can be
-- true. Standing STILL, straight after a reload, the picture was still
-- misaligned (2026-08-18) - so the base placement is wrong, not just its
-- scale, and every correction layered on top has been fitting noise.
-- Three unknowns were stacked: whether the material honours UVOffset, what
-- CoverPercent means, and the border/scale correction. Remove all three:
-- draw the FULL texture over exactly the world rect LocationMin/Max
-- describes, and every pixel lands at its true world position by
-- construction. If the picture then reads correct-but-small (dungeon
-- occupying part of the panel with margins), THIS is the right model and
-- only presentation is left. If it is still misaligned, the fault is in
-- LocationMin/Max itself and no amount of scaling was ever going to fix it.
local GM_SET_UV_PARAM = false  -- do not touch the material's UVOffset
local GM_AUTO_SCALE = false    -- no derived scale
-- v67: place the picture by anchoring it to the VECTOR map's rooms box
-- instead of deriving it from map-data fields. GM_CONTENT_FILLS says whether
-- the panel shows only the content (true) or the whole texture (false) - the
-- one remaining unknown, and F2 flips it live so it can be settled by eye.
local GM_ANCHOR_TO_ROOMS = true
local GM_CONTENT_FILLS = false
local GM_TEX_MARGIN = 1   -- empty pixels on each edge (only used if AUTO_SCALE)
-- MARKER-ONLY uv convention. TEX_QUARTER/TEX_MIRROR are applied to the map
-- AND the marker, so they spin the whole panel and can never change how the
-- two line up against each other - which is why cycling all 8 of them fixed
-- nothing (2026-08-17 23:41). A marker/map mismatch can only come from the
-- world->texture-UV step: whether texture U runs along world X or world Y,
-- and which way each axis points. These three flags cover all 8 of those
-- conventions and apply to the MARKER ONLY. F2 cycles them.
local MK_SWAP_UV = false
local MK_FLIP_U = false
local MK_FLIP_V = false
-- NOTE (2026-08-17): the game also ships a finished map image on
-- MapData.Texture (what the table map and end screen draw), and drawing that
-- instead of reconstructing rooms would be simpler. It is NOT usable on this
-- build - the active dungeon's MapData comes back empty (texture invalid,
-- TextureSize 0), which is also why the Nexus "Dynamic Map Toggle" mod, which
-- relies on it, no longer loads. Reconstruction from the room grid stays.
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

-- defined further down, but called from the layout pass above it
local ApplyMapTexture

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

-- Move a set of walked tiles from one display rotation to another. Tiles are
-- CELLS, not points, so RotTile (which rotates the cell's whole footprint and
-- takes the min corner) is the correct primitive - RotPoint on the origin
-- alone shifts by one on odd quarter turns.
function RekeyVisited(visited, oldRot, newRot)
    if not visited then return {} end
    local out = {}
    local undo = (4 - (oldRot or 0)) % 4
    for key, band in pairs(visited) do
        local sx, sy = key:match("^(-?%d+),(-?%d+)$")
        if sx then
            local x, y = RotTile(undo, tonumber(sx), tonumber(sy))
            x, y = RotTile(newRot or 0, x, y)
            out[x .. "," .. y] = band
        end
    end
    return out
end

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

-- just the seed, for comparing against the seed the map picture was built for
local function RunSeed(d)
    local s
    pcall(function() s = d.CurrentSeed.Seed end)
    return s
end

-- ------------------------------------------------------------ DungeonBounds
-- FHeldenOrientBox on AHeldenDungeonActor. Everything read here is a plain
-- struct field - no TMap traversal, no pixel readback, none of the shapes
-- that have crashed this game.
local function QuatYaw(q)
    -- UE quaternion -> yaw in degrees. Roll/pitch are irrelevant: the
    -- generator only ever spins the dungeon about Z.
    local s = 2.0 * (q.W * q.Z + q.X * q.Y)
    local c = 1.0 - 2.0 * (q.Y * q.Y + q.Z * q.Z)
    return math.deg(math.atan(s, c))
end

local function ReadDungeonBounds(d)
    local b
    pcall(function()
        local ob = d.DungeonBounds
        local c, e = ob.Center, ob.Extents
        -- a dungeon that has not generated - or a client that never received
        -- the box - reads all zeroes. Treat that as "no data", never as a
        -- zero-sized dungeon sitting at the world origin.
        if not (e and (math.abs(e.X) > 1.0 or math.abs(e.Y) > 1.0)) then return end
        b = { cx = c.X, cy = c.Y, cz = c.Z,
              ex = math.abs(e.X), ey = math.abs(e.Y), ez = math.abs(e.Z) }
        -- quaternion read separately: if FQuat's members don't resolve on
        -- this build we still keep centre/extents, which is what the map
        -- image placement will want later
        pcall(function() b.yaw = QuatYaw(ob.Rotation) end)
    end)
    return b
end

-- Quarter-turn implied by the box, or nil (plus a reason) if unusable.
-- Sanity gate: the generator spins the dungeon in quarter turns, so a true
-- yaw is always within rounding of a multiple of 90. A reflection route that
-- returns a well-formed WRONG number is indistinguishable from a working one
-- on any single reading, so demand something only a real answer can produce.
local function BoundsQuarter(b)
    if not (b and b.yaw) then return nil end
    local off = math.abs(b.yaw - 90 * math.floor(b.yaw / 90 + 0.5))
    if off > 5.0 then
        return nil, string.format("yaw %.1f is %.1f deg off a quarter turn", b.yaw, off)
    end
    local q = math.floor(b.yaw / 90 + 0.5) % 4
    if q < 0 then q = q + 4 end
    return q
end

-- has the box moved enough to matter? (centre/extent in world units)
local function BoundsDiffer(a, b)
    if not (a and b) then return a ~= b end
    return math.abs(a.cx - b.cx) > 1.0 or math.abs(a.cy - b.cy) > 1.0
        or math.abs(a.ex - b.ex) > 1.0 or math.abs(a.ey - b.ey) > 1.0
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

local function AddRoomTiles(room, occ, occHint, stats, offX, offY, occSpecial)
    local gx, gy = room.PositionInGrid.X, room.PositionInGrid.Y
    local sx, sy = room.Size.X, room.Size.Y
    -- non-zero EHeldenDungeonRoomType = a purpose-built room (extract,
    -- elevator, objective) rather than plain corridor/filler; the game's own
    -- map shades these, so we do too
    local special = false
    if occSpecial then
        pcall(function()
            local ty = tonumber(room.Type) or 0
            -- EHeldenDungeonRoomType is mostly non-zero (plain rooms are the
            -- exception), so "non-zero = special" shaded nearly everything.
            -- Only the types listed in SPECIAL_TYPES shade; F8 prints each
            -- room's type so the right ones can be named.
            special = SPECIAL_TYPES[ty] == true
            stats["roomType" .. ty] = (stats["roomType" .. ty] or 0) + 1
        end)
    end
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
        -- No per-tile parts. TileHeightOffsets is keyed by grid point, so if
        -- the room populated it we get the room's REAL footprint instead of
        -- flooding its whole bounding box (which made big prefab rooms render
        -- as one solid slab with their courtyards/pits filled in).
        -- REMOVED (2026-08-17): iterating room.TileHeightOffsets (a TMap with
        -- FIntPoint keys) to recover the true prefab footprint. It returned
        -- nothing on every room AND the game crashed natively at dungeon
        -- generation right after it shipped - the same class of landmine as
        -- iterating Niagara's parameter store from Lua. Do not re-add without
        -- a safer read. Prefab rooms stay bounding-box only.
        -- bounding box only - queue as a PENDING hint; decided after all
        -- confirmed geometry is known (phantom generation regions overlap
        -- already-drawn rooms and get discarded; real prefab rooms don't)
        if sx and sy and sx > 0 and sy > 0 then
            occHint[#occHint + 1] = { gx = gx + offX, gy = gy + offY,
                                      sx = sx, sy = sy, special = special }
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
        local key = (p.x + ox + offX) .. "," .. (p.y + oy + offY)
        occ[key] = true
        if special and occSpecial then occSpecial[key] = true end
    end
    return #pts
end

local function ReadRoomsInto(arr, occ, occHint, stats, offX, offY, names, occSpecial)
    local num = 0
    pcall(function() num = #arr end)
    for i = 1, num do
        pcall(function()
            local room = arr[i]
            local n = AddRoomTiles(room, occ, occHint, stats, offX, offY, occSpecial)
            if names then
                local dn = ""
                pcall(function() dn = room.DebugName:ToString() end)
                local ty = -1
                pcall(function() ty = tonumber(room.Type) or -1 end)
                names[#names + 1] = string.format("type=%d %s grid(%d,%d)+off(%d,%d) size(%d,%d) parts=%d",
                    ty, dn ~= "" and dn or "?", room.PositionInGrid.X, room.PositionInGrid.Y,
                    offX, offY, room.Size.X, room.Size.Y, n)
            end
        end)
    end
end

local function ReadDungeonActorInto(da, occ, occHint, stats, offX, offY, names, occSpecial)
    pcall(function() ReadRoomsInto(da.Rooms, occ, occHint, stats, offX, offY, names, occSpecial) end)
    pcall(function() ReadRoomsInto(da.Connections, occ, occHint, stats, offX, offY, names, occSpecial) end)
    pcall(function() ReadRoomsInto(da.CustomRooms, occ, occHint, stats, offX, offY, names, occSpecial) end)
end

-- World-space positions of every placed floor tile in this dungeon. Returns a
-- flat list of {x,y}; the caller converts to grid space (it owns the rotation).
local function CollectFloorWorldPoints(d)
    local pts = {}
    if not (USE_FLOOR_MESHES and d and d:IsValid()) then return pts end
    local dAddr = d:GetAddress()
    local read = 0
    for _, cls in ipairs({ "InstancedStaticMeshComponent",
                           "HierarchicalInstancedStaticMeshComponent" }) do
        pcall(function()
            local found = FindAllOf(cls)
            if not found then return end
            for _, c in ipairs(found) do
                if read >= FLOOR_SCAN_BUDGET then break end
                pcall(function()
                    if not c:IsValid() then return end
                    local owner
                    pcall(function() owner = c:GetOwner() end)
                    if not (owner and owner:IsValid() and owner:GetAddress() == dAddr) then
                        return
                    end
                    local name = ""
                    pcall(function() name = c.StaticMesh:GetFullName():lower() end)
                    if name == "" or not name:find(FLOOR_MESH_MATCH, 1, true) then return end
                    if name:find(FLOOR_MESH_REJECT, 1, true) then return end
                    -- PerInstanceSMData transforms are in the COMPONENT's local
                    -- space (GetInstanceTransform(bWorldSpace) would convert,
                    -- but UE4SS cannot marshal its output), so offset by where
                    -- the component itself sits in the world.
                    -- v68 FIX: do NOT add the component location by default.
                    -- The F7 probe reads the SAME transforms without adding it
                    -- and produced a plausible 387 tiles, while this collector
                    -- (adding it) historically managed only 7% overlap with
                    -- known rooms. That is the signature of double-counting an
                    -- offset that is already baked in: these translations are
                    -- effectively world space. Flag kept so the old behaviour
                    -- is one edit away if a dungeon ever disagrees.
                    -- v69: keep the component's own transform WITH each point
                    -- instead of baking in one guess. PerInstanceSMData holds
                    -- FMatrix transforms in COMPONENT space, so turning them
                    -- into world space needs the component's rotation applied
                    -- to the offset AND then its location - not just the
                    -- location (7% overlap) and not neither (43%). The caller
                    -- scores all three candidates and picks the winner, so the
                    -- question gets answered by measurement, not by me.
                    local cx, cy, cyaw = 0, 0, 0
                    pcall(function()
                        local cl = c:K2_GetComponentLocation()
                        cx, cy = cl.X, cl.Y
                    end)
                    pcall(function()
                        local cr = c:K2_GetComponentRotation()
                        cyaw = cr.Yaw or 0
                    end)
                    local arr = c.PerInstanceSMData
                    local n = 0
                    pcall(function() n = #arr end)
                    for i = 1, n do
                        if read >= FLOOR_SCAN_BUDGET then break end
                        pcall(function()
                            local m = arr[i].Transform
                            local lx = m.WPlane and m.WPlane.X or m.M[3][0]
                            local ly = m.WPlane and m.WPlane.Y or m.M[3][1]
                            if lx and ly then
                                read = read + 1
                                pts[#pts + 1] = { lx = lx, ly = ly,
                                                  cx = cx, cy = cy, cyaw = cyaw }
                            end
                        end)
                    end
                end)
            end
        end)
    end
    return pts
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
        local aqActor = 0
        pcall(function()
            local ay = d:K2_GetActorRotation().Yaw
            aqActor = math.floor(ay / 90 + 0.5) % 4
            if aqActor < 0 then aqActor = aqActor + 4 end
        end)
        local aq = aqActor
        -- DungeonBounds carries the generator's spin as a quaternion - the
        -- same number we have been rounding off the actor's yaw. Prefer it,
        -- and log both, so a disagreement shows up the first time it happens
        -- instead of after a run of wrong-looking maps.
        -- NOTE: the box POPULATES LATE (confirmed 2026-08-17 22:46->22:47: a
        -- new run built its map while DungeonBounds still held the PREVIOUS
        -- dungeon's values, correcting ~70s later). ParseDungeon runs the
        -- instant you enter, so what we read here may describe the last
        -- dungeon. EnsureMapData re-checks it every rebind and forces a
        -- rebuild if the implied quarter-turn changes.
        local bnd = ReadDungeonBounds(d)
        local aqBounds, aqReject = BoundsQuarter(bnd)
        if aqBounds and USE_BOUNDS_ROT then aq = aqBounds end
        -- one line per parse carrying everything v62 is about: the box, both
        -- candidate quarter-turns, and whether the map picture is stale.
        -- Extents are half-sizes, so the tile span is 2*extent/tile - if that
        -- does not look like a dungeon-sized number the box is not what we
        -- think it is and USE_BOUNDS_ROT should go back to false.
        pcall(function()
            local rs, ms = RunSeed(d), nil
            pcall(function() ms = d.MapData.Seed end)
            -- Seed and Texture are INDEPENDENT: Seed is stamped when the run's
            -- map data is initialised (observed going -1 -> run seed with no
            -- map placed), while Texture/TextureSize only fill in once the
            -- game actually builds the picture. Log both, or a matching seed
            -- reads as "the picture is ready" when there may be no picture at
            -- all - which is exactly the wrong conclusion I drew on 23:10.
            local tsz, thas = -1, false
            pcall(function() tsz = d.MapData.TextureSize end)
            pcall(function()
                local t = d.MapData.Texture
                thas = (t ~= nil and t:IsValid()) and true or false
            end)
            local bs = "UNREADABLE"
            if bnd then
                bs = string.format("c(%.0f,%.0f) e(%.0f,%.0f)=%.1fx%.1f tiles yaw %.1f",
                    bnd.cx, bnd.cy, bnd.ex, bnd.ey,
                    bnd.ex * 2 / tile, bnd.ey * 2 / tile, bnd.yaw or 0)
            end
            local msg = string.format(
                "bounds: %s | aq actor=%s bounds=%s using=%s | seed run=%s map=%s | picture=%s (%s px)%s",
                bs, tostring(aqActor), tostring(aqBounds), tostring(aq),
                tostring(rs), tostring(ms),
                thas and "YES" or "none", tostring(tsz),
                -- -1 means the run's map data has not been stamped yet, which
                -- is NOT the same as holding another run's map. Tagging both
                -- "STALE" sent me down the wrong path once already.
                (ms == -1) and "  <- no picture yet"
                or ((rs and ms and rs ~= ms) and "  <- STALE (previous run's map)" or ""))
            -- ParseDungeon is retried on EVERY rebind tick for as long as the
            -- signature keeps moving, which it does for ~30s while a run
            -- regenerates - so this printed ~15 identical lines per level
            -- transition (observed 22:08:44-22:09:15, 2026-08-17). Only print
            -- when something actually changed; a repeat carries no news.
            if msg ~= S.lastBoundsLog then
                S.lastBoundsLog = msg
                Log(msg)
                if aqReject then Log("bounds rotation REJECTED: " .. aqReject) end
            end
        end)
        local occ, occHint, stats, occSpecial = {}, {}, {}, {}
        ReadDungeonActorInto(d, occ, occHint, stats, 0, 0, names, occSpecial)
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
                        ReadDungeonActorInto(e, occ, occHint, stats, offX, offY, names, occSpecial)
                        nExt = nExt + 1
                    end
                end)
            end
        end)

        -- Real placed floor beats every guess we make. Each floor instance is
        -- one tile; convert world -> dungeon grid (undo the actor's yaw) and
        -- fold it into the occupancy the map is built from.
        local floorTiles, nFloor = {}, 0
        if USE_FLOOR_MESHES then
            local raw = CollectFloorWorldPoints(d)
            -- v69: three candidate component->world conversions, scored against
            -- the dungeon's known footprint. Whichever actually places tiles
            -- inside the dungeon is the right one; no more guessing.
            local function worldOf(p, mode)
                if mode == 1 then return p.lx, p.ly end                 -- already world
                if mode == 2 then return p.cx + p.lx, p.cy + p.ly end   -- + location
                local r = math.rad(p.cyaw or 0)                          -- full transform
                local c, s = math.cos(r), math.sin(r)
                return p.cx + (p.lx * c - p.ly * s), p.cy + (p.lx * s + p.ly * c)
            end
            local function inFootprint(key)
                if occ[key] then return true, true end
                local x, y = key:match("^(-?%d+),(-?%d+)$")
                x, y = tonumber(x), tonumber(y)
                for _, h in ipairs(occHint) do
                    if x >= h.gx and x < h.gx + h.sx
                       and y >= h.gy and y < h.gy + h.sy then return true, false end
                end
                return false, false
            end
            local best, bestMode, bestScore, bestRooms = nil, 0, -1, 0
            for mode = 1, 3 do
                local set, n, ins, rm = {}, 0, 0, 0
                for _, p in ipairs(raw) do
                    local wx, wy = worldOf(p, mode)
                    local gx = (wx - al.X) / tile
                    local gy = (wy - al.Y) / tile
                    gx, gy = RotPoint(aq, gx, gy)
                    local key = math.floor(gx) .. "," .. math.floor(gy)
                    if not set[key] then
                        set[key] = true
                        n = n + 1
                        local isIn, isRoom = inFootprint(key)
                        if isIn then ins = ins + 1 end
                        if isRoom then rm = rm + 1 end
                    end
                end
                local sc = (n > 0) and (ins / n) or 0
                Log(string.format("floor candidate %d (%s): %d tiles, %d%% inside footprint",
                    mode, (mode == 1) and "raw" or (mode == 2) and "+location"
                        or "+rotation+location", n, math.floor(sc * 100)))
                if sc > bestScore then
                    best, bestMode, bestScore, bestRooms = set, mode, sc, rm
                end
            end
            local inRooms = bestRooms
            if best then
                for k in pairs(best) do
                    if not floorTiles[k] then
                        floorTiles[k] = true
                        nFloor = nFloor + 1
                    end
                end
            end
            stats.floorMode = bestMode
            -- v68 GATE: does the floor land inside the dungeon's known
            -- FOOTPRINT (rooms OR prefab bounding boxes)? The old test asked
            -- how much it overlapped the rooms we already had, which scored
            -- ~14% on perfectly good data precisely BECAUSE the new tiles are
            -- the prefab interiors we lack. A broken transform scatters tiles
            -- far outside every known box, so this separates the two cases.
            local inside, strays = 0, {}
            for key in pairs(floorTiles) do
                if occ[key] then
                    inside = inside + 1
                else
                    local x, y = key:match("^(-?%d+),(-?%d+)$")
                    x, y = tonumber(x), tonumber(y)
                    local hit = false
                    for _, h in ipairs(occHint) do
                        if x >= h.gx and x < h.gx + h.sx
                           and y >= h.gy and y < h.gy + h.sy then
                            hit = true
                            break
                        end
                    end
                    if hit then inside = inside + 1 else strays[key] = true end
                end
            end
            local frac = (nFloor > 0) and (inside / nFloor) or 0
            stats.floorTiles = nFloor
            stats.floorAgree = math.floor(frac * 100)
            stats.floorInRooms = inRooms
            if nFloor > 0 and frac >= FLOOR_MIN_INSIDE then
                -- CLIP THE STRAYS (v71). ~20% of accepted floor tiles fall
                -- outside every known room AND every prefab box. A 200x200
                -- floor piece tucked under a wall or spilling past a doorway
                -- lands exactly there, and drawing it is what made corridors
                -- read WIDER than they are in game (user report 2026-08-18:
                -- "hallways showing up a lot wider than they actually are").
                -- Tiles inside a prefab box are kept - those are the real win.
                -- THIN-FRINGE TEST (v72). v71 clipped EVERY stray and deleted
                -- a whole snow-cave room (user report 2026-08-18) - static
                -- level geometry like mine tunnels and stair halls appears in
                -- NO dungeon array, so its floor is 100% "stray" by this
                -- measure. Losing a real room is far worse than a corridor
                -- reading a tile wide. Discriminator: floor tucked under a
                -- wall forms a ONE-TILE-WIDE fringe hugging known geometry,
                -- while a real room forms a BLOB. So a stray survives if it
                -- belongs to a solid 2x2 of floor, and only the 1-wide fringe
                -- is dropped.
                local function hasFloor(x, y)
                    local k = x .. "," .. y
                    return (floorTiles[k] or occ[k]) and true or false
                end
                -- v73 RULE, replacing the 2x2 guess (which clipped 0 and so
                -- did nothing). Corridors and normal rooms are type=0/1 with
                -- PER-TILE part data - the generator already states their exact
                -- shape, so floor data cannot improve them, it can only add
                -- tiles AROUND them. That is the corridor widening. Prefab
                -- (parts=0) rooms and static level geometry are the only places
                -- floor actually adds knowledge. So: a stray touching known
                -- per-tile geometry is wall bleed -> drop. A stray away from it
                -- is real unmapped geometry (snow caves, stair halls) -> keep.
                -- occ still holds ONLY generator parts at this point; floor is
                -- folded in afterwards.
                local function touchesKnown(x, y)
                    return occ[(x + 1) .. "," .. y] or occ[(x - 1) .. "," .. y]
                        or occ[x .. "," .. (y + 1)] or occ[x .. "," .. (y - 1)]
                end
                -- decide everything BEFORE mutating, or each deletion changes
                -- the answer for its neighbours mid-pass
                -- DEEP-NEIGHBOUR RULE (v78). Dropping every stray that touches
                -- known geometry also eats the MOUTH of every corridor, since
                -- a corridor is a thin run of floor whose ends meet rooms -
                -- the map then shows rooms with the links between them missing
                -- (user report 2026-08-18, bottom-right section disconnected).
                -- Wall bleed is a fringe LAYER: every tile in it hugs known
                -- geometry. A corridor mouth is different - it has a neighbour
                -- leading AWAY into open space. So a stray is only dropped if
                -- none of its neighbours is "deep" (a stray not itself touching
                -- known geometry). Fringe goes, junctions stay.
                local deep = {}
                for key in pairs(strays) do
                    if floorTiles[key] then
                        local x, y = key:match("^(-?%d+),(-?%d+)$")
                        x, y = tonumber(x), tonumber(y)
                        if not touchesKnown(x, y) then deep[key] = true end
                    end
                end
                local function hasDeepNeighbour(x, y)
                    return deep[(x + 1) .. "," .. y] or deep[(x - 1) .. "," .. y]
                        or deep[x .. "," .. (y + 1)] or deep[x .. "," .. (y - 1)]
                end
                local drops = {}
                if FLOOR_CLIP_STRAYS then
                    for key in pairs(strays) do
                        if floorTiles[key] then
                            local x, y = key:match("^(-?%d+),(-?%d+)$")
                            x, y = tonumber(x), tonumber(y)
                            if touchesKnown(x, y) and not hasDeepNeighbour(x, y) then
                                drops[#drops + 1] = key
                            end
                        end
                    end
                end
                local clipped = 0
                for _, key in ipairs(drops) do
                    floorTiles[key] = nil
                    clipped = clipped + 1
                end
                for key in pairs(floorTiles) do occ[key] = true end
                if clipped > 0 then
                    nFloor = nFloor - clipped
                    Log(string.format(
                        "floor clipped %d stray tile(s) outside the known footprint (wall bleed beside per-tile geometry; unmapped rooms kept)",
                        clipped))
                end
                Log(string.format(
                    "floor ACCEPTED: %d tiles, %d%% inside the known footprint (%d already in rooms, %d new)",
                    nFloor, math.floor(frac * 100), inRooms, nFloor - inRooms))
            else
                if nFloor > 0 then
                    Log(string.format(
                        "floor data rejected (%d tiles, only %d%% inside the known footprint)",
                        nFloor, math.floor(frac * 100)))
                    S.floorRejected = true -- stop rescanning; it will not improve
                end
                floorTiles, nFloor = {}, 0
            end
        end

        -- ================= NAVMESH FILL (v83) =========================
        -- The game paths enemies through every reachable space, so the nav
        -- data knows about geometry NO asset source exposes - measured with
        -- the F7 probe 2026-08-18: 487 walkable tiles vs our 357, and the
        -- 147 we lacked formed long thin runs between rooms, i.e. exactly the
        -- corridors the user reported missing. (The overlap test in the same
        -- probe returned TRUE for all 990 tiles - no discrimination, dropped.)
        -- K2_ProjectPointToNavigation returns a bool + an FVector out-param,
        -- so it avoids the FHitResult crash landmine. ~17ms for a full grid.
        if NAVMESH_FILL then
            local t0 = os.clock()
            local navSys = StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1")
            local added, probed, snapped = 0, 0, 0
            if navSys and C.pc then
                local pz
                pcall(function() pz = C.pawn:K2_GetActorLocation().Z end)
                if pz then
                    -- bbox of what we already know, with a margin so corridors
                    -- leading away from known rooms are still reached
                    local lo, hi, lo2, hi2
                    for key in pairs(occ) do
                        local sx, sy = key:match("^(-?%d+),(-?%d+)$")
                        if sx then
                            local x, y = tonumber(sx), tonumber(sy)
                            lo = (not lo or x < lo) and x or lo
                            hi = (not hi or x > hi) and x or hi
                            lo2 = (not lo2 or y < lo2) and y or lo2
                            hi2 = (not hi2 or y > hi2) and y or hi2
                        end
                    end
                    if lo then
                        local undoAq = (4 - aq) % 4
                        for y = lo2 - NAV_FILL_MARGIN, hi2 + NAV_FILL_MARGIN do
                            for x = lo - NAV_FILL_MARGIN, hi + NAV_FILL_MARGIN do
                                if probed >= NAV_PROBE_BUDGET then break end
                                local key = x .. "," .. y
                                if not occ[key] then
                                    probed = probed + 1
                                    local rx, ry = RotTile(undoAq, x, y)
                                    local wx = al.X + (rx + 0.5) * tile
                                    local wy = al.Y + (ry + 0.5) * tile
                                    pcall(function()
                                        local out = {}
                                        local ok = navSys:K2_ProjectPointToNavigation(
                                            C.pc, { X = wx, Y = wy, Z = pz }, out, nil, nil,
                                            { X = NAV_QUERY_XY, Y = NAV_QUERY_XY, Z = NAV_FILL_Z })
                                        -- A bare `true` is NOT "this tile is
                                        -- walkable" - projection SNAPS to the
                                        -- nearest navmesh inside the query
                                        -- extent, so a point buried in a wall
                                        -- still succeeds by finding floor a few
                                        -- cm away. With a half-tile extent that
                                        -- filled the gaps between every room
                                        -- and merged the map into one blob
                                        -- (user screenshots, 2026-08-18).
                                        -- The out-param is the answer: if the
                                        -- point had to MOVE to reach navmesh,
                                        -- it was not standing on it.
                                        if ok == true and out and out.X then
                                            local dx = (out.X or 0) - wx
                                            local dy = (out.Y or 0) - wy
                                            if (dx * dx + dy * dy) <= (NAV_SNAP_MAX * NAV_SNAP_MAX) then
                                                occ[key] = true
                                                added = added + 1
                                            else
                                                snapped = snapped + 1
                                            end
                                        end
                                    end)
                                end
                            end
                        end
                    end
                end
            end
            Log(string.format(
                "navmesh fill: %d probed, %d added, %d rejected as snap-to-nearby (%.0f ms)",
                probed, added, snapped, (os.clock() - t0) * 1000))
        end

        local rot, yaw = DetectRotation(al, tile, aq)
        -- F4 comparison mode: draw in the dungeon's native orientation, so the
        -- map can be held directly against the in-game one. aq is the world->
        -- grid conversion and must stay; only the display spin is dropped.
        if ROT_DISABLED then rot = (4 - aq) % 4 end

        -- resolve pending bounding-box hints: a box whose interior is
        -- already substantially covered by confirmed floor is a phantom
        -- generation region (e.g. the reserved start area), not a room -
        -- the game's own table map does not draw those either
        -- With real floor data the bounding-box guesses are pure noise, so
        -- drop them entirely rather than drawing rooms that aren't there.
        -- F3 comparison mode: drop the bounding-box rooms. They are the only
        -- part of the map we GUESS at, so hiding them shows exactly how much
        -- of any mismatch they are responsible for.
        local hintTiles = {}
        -- v68: do NOT blanket-drop the boxes just because some floor arrived.
        -- A box is only redundant once real floor actually covers a decent
        -- share of it; otherwise the box is still the only evidence that room
        -- exists, and dropping it would make rooms disappear from the map -
        -- strictly worse than drawing them coarsely.
        if HINTS_DISABLED then
            occHint = {}
        elseif nFloor > 0 then
            local kept, replaced = {}, 0
            for _, h in ipairs(occHint) do
                local total, cov = 0, 0
                for x = h.gx, h.gx + h.sx - 1 do
                    for y = h.gy, h.gy + h.sy - 1 do
                        total = total + 1
                        if floorTiles[x .. "," .. y] then cov = cov + 1 end
                    end
                end
                if total > 0 and (cov / total) >= FLOOR_BOX_REPLACE then
                    replaced = replaced + 1      -- real floor takes over here
                else
                    kept[#kept + 1] = h          -- keep the coarse box
                end
            end
            occHint = kept
            Log(string.format(
                "prefab boxes: %d replaced by real floor, %d kept (no floor data there)",
                replaced, #kept))
            -- v75: PREFAB INTERIOR RECOVERY. The boxes still standing are
            -- `PF_*` level chunks (PF_IceWorld_HazardRoom_Cave_01 and friends)
            -- built from ORDINARY StaticMeshActors, which is why the instanced
            -- collector cannot see them and why they report parts=0. Scan for
            -- static meshes standing inside those specific boxes and use them
            -- as the room's real footprint.
            -- COST CONTROL, deliberately: this runs ONLY when a box is
            -- unresolved (usually 0-1 per dungeon), uses GetAllActorsOfClass
            -- on StaticMeshActor rather than a FindAllOf over every component
            -- (thousands - full sweeps have frozen this game), filters on
            -- POSITION before touching any name, and is hard-capped. Timing
            -- is logged so a regression is visible rather than felt.
            if PREFAB_MESH_SCAN and #kept > 0 then
                local t0 = os.clock()
                local scanned, hits, newTiles = 0, 0, 0
                local pfTiles = {}
                pcall(function()
                    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
                    local cls = StaticFindObject("/Script/Engine.StaticMeshActor")
                    if not (gs and cls and cls:IsValid()) then return end
                    local out = {}
                    gs:GetAllActorsOfClass(d, cls, out)
                    local n = 0
                    pcall(function() n = #out end)
                    for i = 1, n do
                        if scanned >= PREFAB_SCAN_BUDGET then break end
                        scanned = scanned + 1
                        pcall(function()
                            local a = out[i]
                            if not (a and a:IsValid()) then return end
                            local l = a:K2_GetActorLocation()
                            local gx = (l.X - al.X) / tile
                            local gy = (l.Y - al.Y) / tile
                            gx, gy = RotPoint(aq, gx, gy)
                            local tx, ty = math.floor(gx), math.floor(gy)
                            -- position filter FIRST: only meshes standing in
                            -- one of the unresolved boxes are of any interest
                            for _, h in ipairs(kept) do
                                if tx >= h.gx and tx < h.gx + h.sx
                                   and ty >= h.gy and ty < h.gy + h.sy then
                                    hits = hits + 1
                                    local key = tx .. "," .. ty
                                    if not pfTiles[key] then
                                        pfTiles[key] = true
                                        newTiles = newTiles + 1
                                    end
                                    break
                                end
                            end
                        end)
                    end
                end)
                if newTiles > 0 then
                    for key in pairs(pfTiles) do occ[key] = true end
                    -- a box whose interior we now know per-tile stops being a
                    -- box; anything still unresolved keeps its coarse outline
                    local still = {}
                    for _, h in ipairs(kept) do
                        local total, cov = 0, 0
                        for x = h.gx, h.gx + h.sx - 1 do
                            for y = h.gy, h.gy + h.sy - 1 do
                                total = total + 1
                                if pfTiles[x .. "," .. y] then cov = cov + 1 end
                            end
                        end
                        if not (total > 0 and (cov / total) >= PREFAB_BOX_REPLACE) then
                            still[#still + 1] = h
                        end
                    end
                    occHint = still
                    Log(string.format(
                        "prefab meshes: %d actors scanned, %d inside boxes -> %d tiles; %d of %d boxes resolved (%.0f ms)",
                        scanned, hits, newTiles, #kept - #still, #kept,
                        (os.clock() - t0) * 1000))
                else
                    Log(string.format(
                        "prefab meshes: %d actors scanned, none inside the %d remaining box(es) (%.0f ms) - prefab geometry is not StaticMeshActors",
                        scanned, #kept, (os.clock() - t0) * 1000))
                    -- FALLBACK: the geometry is components on BP actors inside
                    -- the PF_* level chunk, not StaticMeshActors. Sweeping
                    -- every StaticMeshComponent is the thing this game freezes
                    -- on - but the actor pass just measured ~4us per position
                    -- test, so even 15k components is tens of ms, and this
                    -- only runs when a box is unresolved. Guards per the
                    -- known landmine: require bRegistered and a real owner, or
                    -- the results include CDOs and archetypes whose transforms
                    -- are meaningless.
                    local t1 = os.clock()
                    local cScanned, cHits, cNew = 0, 0, 0
                    local cTiles = {}
                    pcall(function()
                        local comps = FindAllOf("StaticMeshComponent") or {}
                        local n = 0
                        pcall(function() n = #comps end)
                        for i = 1, n do
                            if cScanned >= PREFAB_COMP_BUDGET then break end
                            cScanned = cScanned + 1
                            pcall(function()
                                local c = comps[i]
                                if not (c and c:IsValid()) then return end
                                if c.bRegistered ~= true then return end
                                local l = c:K2_GetComponentLocation()
                                local gx = (l.X - al.X) / tile
                                local gy = (l.Y - al.Y) / tile
                                gx, gy = RotPoint(aq, gx, gy)
                                local tx, ty = math.floor(gx), math.floor(gy)
                                for _, h in ipairs(kept) do
                                    if tx >= h.gx and tx < h.gx + h.sx
                                       and ty >= h.gy and ty < h.gy + h.sy then
                                        cHits = cHits + 1
                                        local key = tx .. "," .. ty
                                        if not cTiles[key] then
                                            cTiles[key] = true
                                            cNew = cNew + 1
                                        end
                                        break
                                    end
                                end
                            end)
                        end
                    end)
                    if cNew > 0 then
                        for key in pairs(cTiles) do occ[key] = true end
                        local still = {}
                        for _, h in ipairs(kept) do
                            local total, cov = 0, 0
                            for x = h.gx, h.gx + h.sx - 1 do
                                for y = h.gy, h.gy + h.sy - 1 do
                                    total = total + 1
                                    if cTiles[x .. "," .. y] then cov = cov + 1 end
                                end
                            end
                            if not (total > 0 and (cov / total) >= PREFAB_BOX_REPLACE) then
                                still[#still + 1] = h
                            end
                        end
                        occHint = still
                    end
                    Log(string.format(
                        "prefab components: %d scanned, %d inside boxes -> %d tiles, %d of %d boxes resolved (%.0f ms)",
                        cScanned, cHits, cNew, #kept - #occHint, #kept,
                        (os.clock() - t1) * 1000))
                    -- PHANTOM DROP. A box with NO floor, NO StaticMeshActor
                    -- and NO StaticMeshComponent anywhere inside it is a
                    -- generator reservation that was never built - measured
                    -- 2026-08-18: 0 of 13136 components fell inside, which is
                    -- not "sparse", it is empty. The game's own map does not
                    -- draw these either. Drawing it swallows the real rooms
                    -- underneath, which is the visible bug. Three independent
                    -- sources agreeing on nothing is enough to stop drawing it.
                    if PREFAB_DROP_EMPTY and cHits == 0 and #occHint > 0 then
                        local dropped = #occHint
                        occHint = {}
                        Log(string.format(
                            "prefab boxes: dropped %d empty box(es) - no floor, no actors, no components inside (phantom generation region)",
                            dropped))
                    end
                end
            end
        end
        for _, h in ipairs(occHint) do
            local total, covered = 0, 0
            for x = h.gx, h.gx + h.sx - 1 do
                for y = h.gy, h.gy + h.sy - 1 do
                    total = total + 1
                    if occ[x .. "," .. y] then covered = covered + 1 end
                end
            end
            -- Only throw away a box that is almost entirely covered by real
            -- floor already (the generator's reserved start area). The old
            -- 0.35 cutoff was eating legitimate prefab rooms that merely sat
            -- against a corridor - that was the "missing rooms" bug.
            if total > 0 and covered / total <= 0.85 then
                for x = h.gx, h.gx + h.sx - 1 do
                    for y = h.gy, h.gy + h.sy - 1 do
                        hintTiles[x .. "," .. y] = true
                        if h.special then occSpecial[x .. "," .. y] = true end
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
        local rspecial = Rotate(occSpecial)
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
        local function BuildRuns(set, isHint, isSpecial)
            for y = minY, maxY do
                local runStart
                for x = minX, maxX + 1 do
                    local on = set[x .. "," .. y] and x <= maxX
                    if on and not runStart then
                        runStart = x
                    elseif not on and runStart then
                        if #rects < ROOM_POOL - 1 then
                            rects[#rects + 1] = { gx = runStart, gy = y,
                                sx = x - runStart, sy = 1, hint = isHint, special = isSpecial }
                        else
                            full = true
                        end
                        runStart = nil
                    end
                end
            end
        end
        -- one uniform floor set: bounding-box rooms are real rooms, they just
        -- carry less precision, and they now render identically
        local occAll = {}
        for k in pairs(rocc) do occAll[k] = true end
        for k in pairs(rhint) do occAll[k] = true end
        BuildRuns(occAll, false)
        BuildRuns(rspecial, false, true) -- special rooms shade over the fill

        -- Border pass: a bright edge is drawn wherever a floor tile has no
        -- floor neighbour. Edges must sit ON TOP - the old trick of stacking
        -- an oversized dark rect behind each run only works with opaque
        -- fills, and these fills are translucent now.
        local function Has(x, y) return occAll[x .. "," .. y] end
        local function AddEdge(r)
            if #rects < ROOM_POOL - 1 then rects[#rects + 1] = r else full = true end
        end
        for y = minY, maxY do
            for _, side in ipairs({ "T", "B" }) do
                local dy = (side == "T") and -1 or 1
                local runStart
                for x = minX, maxX + 1 do
                    local on = x <= maxX and Has(x, y) and not Has(x, y + dy)
                    if on and not runStart then
                        runStart = x
                    elseif not on and runStart then
                        AddEdge({ gx = runStart, gy = y, sx = x - runStart, sy = 1,
                                  edge = side })
                        runStart = nil
                    end
                end
            end
        end
        for x = minX, maxX do
            for _, side in ipairs({ "L", "R" }) do
                local dx = (side == "L") and -1 or 1
                local runStart
                for y = minY, maxY + 1 do
                    local on = y <= maxY and Has(x, y) and not Has(x + dx, y)
                    if on and not runStart then
                        runStart = y
                    elseif not on and runStart then
                        AddEdge({ gx = x, gy = runStart, sx = 1, sy = y - runStart,
                                  edge = side })
                        runStart = nil
                    end
                end
            end
        end
        if full then Log("WARNING: pool full - map partially drawn (raise ROOM_POOL)") end
        -- (no spawn square: the elevator reads fine from the layout itself)
        geo = { runId = RunId(d), actX = al.X, actY = al.Y, actZ = al.Z, tile = tile,
                addr = d:GetAddress(),
                name = d:GetFullName(), stats = stats, rot = rot, aq = aq,
                aqActor = aqActor, aqBounds = aqBounds, bnd = bnd,
                ang = ROT_ANGLE[(rot + aq) % 4], yaw = yaw, ext = nExt, occ = rocc }
        -- world rect the game's own map image covers, so it can be laid over
        -- our grid later (it populates late, so this may still be empty here)
        pcall(function()
            local md = d.MapData
            geo.texSize = md.TextureSize
            geo.locMinX, geo.locMinY = md.LocationMin.X, md.LocationMin.Y
            geo.locMaxX, geo.locMaxY = md.LocationMax.X, md.LocationMax.Y
        end)
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
    -- the game map panel is a child of our canvas, so removing the root takes
    -- it with it - but the references must go too, or the next Build() sees a
    -- "valid" widget belonging to a destroyed tree (the orphan-widget trap
    -- that made hot reloads leave untoggleable maps on screen)
    pcall(function()
        if W.gm and W.gm:IsValid() then W.gm:RemoveFromParent() end
    end)
    W.gm, W.gmSlot, W.gmImage, W.gmRT, W.gmMID = nil, nil, nil, nil, nil
    S.gmActive, S.gmReady, S.gmWarned, S.gmLogged, S.gmUVLogged = false, false, false, false, false
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

    -- the game's own map picture, drawn beneath our vector layer
    local tex = StaticConstructObject(imgClass, wt, FName("GRMM_Tex"))
    local texSlot = canvas:AddChildToCanvas(tex)
    tex:SetVisibility(1)


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
    halo:SetVisibility(1) -- retired: the arrow carries the marker now
    local marker = StaticConstructObject(imgClass, wt, FName("GRMM_Marker"))
    local markerSlot = canvas:AddChildToCanvas(marker)
    marker:SetVisibility(1) -- anchor only; the arrow bars below draw it
    local nose = StaticConstructObject(imgClass, wt, FName("GRMM_Nose"))
    local noseSlot = canvas:AddChildToCanvas(nose)
    nose:SetVisibility(1) -- retired with the halo

    -- tapered bars that together form the player arrow
    local tri = {}
    for i = 1, MARKER_TRI_SEGS do
        local img = StaticConstructObject(imgClass, wt, FName("GRMM_Tri" .. i))
        if img and img:IsValid() then
            local slot = canvas:AddChildToCanvas(img)
            img:SetVisibility(1)
            tri[#tri + 1] = { img = img, slot = slot }
        end
    end

    S.anchoredRight = pcall(function()
        local anchors = { Minimum = { X = 1.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 0.0 } }
        bgSlot:SetAnchors(anchors)
        texSlot:SetAnchors(anchors)
        haloSlot:SetAnchors(anchors)
        markerSlot:SetAnchors(anchors)
        noseSlot:SetAnchors(anchors)
        for _, e in ipairs(tri) do e.slot:SetAnchors(anchors) end
        for _, e in ipairs(pool) do e.slot:SetAnchors(anchors) end
        for _, e in ipairs(team) do e.slot:SetAnchors(anchors) end
    end)

    pcall(function()
        bg:SetColorAndOpacity(BG_COLOR)
        halo:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = 0.85 })
        marker:SetColorAndOpacity(MARKER_COLOR)
        nose:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = 0.95 })
    end)

    widget:AddToViewport(50)
    widget:SetVisibility(1)

    W.widget, W.canvas, W.bg, W.marker = widget, canvas, bg, marker
    W.halo, W.haloSlot, W.tri = halo, haloSlot, tri
    W.tex, W.texSlot = tex, texSlot
    W.nose, W.noseSlot = nose, noseSlot
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
    pcall(function()
        if BG_COLOR.A > 0 then
            W.bg:SetVisibility(3)
            W.bgSlot:SetPosition({ X = S.baseX - BG_PAD, Y = S.baseY - BG_PAD })
            W.bgSlot:SetSize({ X = S.size + 2 * BG_PAD, Y = S.size + 2 * BG_PAD })
        else
            W.bg:SetVisibility(1)
        end
    end)
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

        -- fills first, borders last so the bright edges sit on top of the
        -- translucent glass fill
        local draw = {}
        for _, r in ipairs(S.rects) do
            if not r.edge and (SHOW_TRAIL or not r.trail) then
                draw[#draw + 1] = r
            end
        end
        -- CRT scanlines, clipped to the rooms themselves: each fill run gets
        -- bars at globally-aligned screen rows, so the lines march straight
        -- across the layout but never over the empty background
        if SCANLINES then
            local step = SCANLINE_SPACING
            for _, r in ipairs(S.rects) do
                if not r.edge and not r.trail then
                    local px, py = TileToPx(r.gx, r.gy, r.sx, r.sy)
                    local h = r.sy * scale
                    -- Keep bars strictly INSIDE the row. A line landing exactly
                    -- on the seam between two rows was emitted by both, and the
                    -- two translucent bars stacked into one brighter line that
                    -- drifted as the map was resized.
                    local eps = 0.01
                    local first = math.floor((py - S.baseY) / step + 1) * step + S.baseY
                    local y = first
                    while y < py + h - eps do
                        draw[#draw + 1] = { scan = true, pxX = px,
                                            pxY = y, pxW = r.sx * scale }
                        y = y + step
                    end
                end
            end
        end
        for _, r in ipairs(S.rects) do
            if r.edge then draw[#draw + 1] = r end
        end
        for i, e in ipairs(W.pool) do
            local r = draw[i]
            if r and r.scan then
                e.slot:SetPosition({ X = r.pxX, Y = r.pxY })
                e.slot:SetSize({ X = r.pxW, Y = SCANLINE_THICKNESS })
                e.img:SetColorAndOpacity(SCANLINE_COLOR)
                e.img:SetVisibility(3)
            elseif r then
                local px, py = TileToPx(r.gx, r.gy, r.sx, r.sy)
                if r.edge then
                    -- a border bar hugging one side of a run of tiles
                    local w, h = r.sx * scale, r.sy * scale
                    if r.edge == "T" then h = t
                    elseif r.edge == "B" then py = py + r.sy * scale - t; h = t
                    elseif r.edge == "L" then w = t
                    else px = px + r.sx * scale - t; w = t end
                    e.slot:SetPosition({ X = px, Y = py })
                    e.slot:SetSize({ X = w, Y = h })
                    e.img:SetColorAndOpacity(OUTLINE_COLOR)
                else
                    -- FILL_UNMAPPED (v79): walked tiles in areas we have no
                    -- data for are FLOOR, not a tracer dot - draw them exactly
                    -- like a room so the map simply completes itself as you
                    -- explore. Only when SHOW_TRAIL is off; with trails on the
                    -- old route-dot styling still applies.
                    local asFloor = r.trail and FILL_UNMAPPED and not SHOW_TRAIL
                    local ins = (r.trail and not asFloor) and inset or 0
                    e.slot:SetPosition({ X = px + ins, Y = py + ins })
                    e.slot:SetSize({ X = r.sx * scale - 2 * ins, Y = r.sy * scale - 2 * ins })
                    e.img:SetColorAndOpacity(r.start and START_COLOR
                        or (asFloor and ((r.band or 0) == (S.band or 0)
                            and ROOM_COLOR or TRAIL_OTHER_FLOOR))
                        or (r.trail and ((r.band or 0) == (S.band or 0)
                            and TRAIL_COLOR or TRAIL_OTHER_FLOOR))
                        or (r.special and SPECIAL_COLOR)
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
        ApplyMapTexture()
        -- last, so it re-follows a resize and re-hides the vector layer that
        -- this function has just made visible again
        if ApplyGameMap then ApplyGameMap() end
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

-- Look for the game's finished map picture. It is not ready at generation, so
-- this is retried on the normal rebind tick until it turns up. Returns the
-- texture plus the world rect it covers; DRAW ONLY, never read pixels back.
-- Read ONLY the dungeon we are actually in. The game keeps stale dungeon
-- actors from previous runs loaded, so scanning FindAllOf and taking the
-- first one with a texture happily returns the LAST run's map - which is
-- exactly the "completely different map" seen on the second dungeon.
local function FindMapTexture(d)
    if not d then d = GetActiveDungeon() end
    if not d or not d:IsValid() then return nil end
    local tex, bounds
    pcall(function()
        local md = d.MapData
        local n = md.TextureSize
        local t = md.Texture
        if n and n > 0 and t and t:IsValid() then
            tex = t
            bounds = { minX = md.LocationMin.X, minY = md.LocationMin.Y,
                       maxX = md.LocationMax.X, maxY = md.LocationMax.Y,
                       size = n }
            -- where inside the texture the dungeon actually sits. The map
            -- material crops to this region and fills the widget with it, so
            -- the widget must be placed over THIS world rect, not the whole
            -- texture's rect - otherwise the content lands at the wrong scale.
            pcall(function()
                bounds.offU, bounds.offV = md.UVOffset.X, md.UVOffset.Y
                bounds.covU, bounds.covV = md.CoverPercent.X, md.CoverPercent.Y
            end)
            -- which run this picture was actually built for
            pcall(function() bounds.seed = md.Seed end)
        end
    end)
    return tex, bounds
end

-- Place the map picture so the world rect it covers lands exactly on top of
-- the same world rect in our grid layout. Rotations are quarter turns and the
-- covered region is square, so the placement stays axis-aligned and we only
-- have to spin the image about its own centre.
-- The world rect the map image covers, expressed in our grid space.
local function MapImageGridRect(mb, g)
    if not (mb and g) then return nil end
    local loX, hiX = math.min(mb.minX, mb.maxX), math.max(mb.minX, mb.maxX)
    local loY, hiY = math.min(mb.minY, mb.maxY), math.max(mb.minY, mb.maxY)
    local aX, aY, bX, bY
    for _, c in ipairs({ { loX, loY }, { hiX, loY }, { loX, hiY }, { hiX, hiY } }) do
        local gx = (c[1] - g.actX) / g.tile
        local gy = (c[2] - g.actY) / g.tile
        gx, gy = RotPoint(g.aq, gx, gy)
        gx, gy = RotPoint(g.rot, gx, gy)
        aX = (not aX or gx < aX) and gx or aX
        aY = (not aY or gy < aY) and gy or aY
        bX = (not bX or gx > bX) and gx or bX
        bY = (not bY or gy > bY) and gy or bY
    end
    return aX, aY, bX, bY
end

-- The game only builds this picture once a map has been revealed, so until
-- then MapData still holds the PREVIOUS run's map - and we happily drew that
-- (confirmed 2026-08-17: a dungeon showed the old layout until a map was put
-- up). Trust the image only when the area it covers actually contains the
-- rooms we parsed for THIS dungeon.
local function MapImageFits(mb, g)
    if not (mb and g and S.lay) then return false end
    local aX, aY, bX, bY = MapImageGridRect(mb, g)
    if not aX then return false end
    local slack = 2.0
    local rx0, ry0 = S.lay.minX + 1, S.lay.minY + 1
    local rx1 = S.lay.minX + S.lay.w - 1
    local ry1 = S.lay.minY + S.lay.h - 1
    return aX <= rx0 + slack and aY <= ry0 + slack
       and bX >= rx1 - slack and bY >= ry1 - slack
end

-- =================== the game's own map widget (v63) =======================
-- Technique observed in DaMoWang710's Nexus mod and reimplemented from the
-- game's own reflection data - no code taken. He does not draw a map: he
-- instantiates the end screen's map panel and re-hosts it on the HUD, which
-- is why his minimap carries the same shimmering border as "YOUR JOURNEY".
local GM_CLASS_PATH = "/Game/UI/Dungeon/WBP_DungoenEndMapWidget.WBP_DungoenEndMapWidget_C"
local GM_PKG_PATH = "/Game/UI/Dungeon/WBP_DungoenEndMapWidget"

local function FindGameMapClass()
    local cls = StaticFindObject(GM_CLASS_PATH)
    if cls and cls:IsValid() then return cls end
    -- a UI asset is only resident once the screen that uses it has appeared,
    -- so pull it in explicitly rather than waiting for the end screen
    pcall(function() LoadAsset(GM_PKG_PATH) end)
    cls = StaticFindObject(GM_CLASS_PATH)
    if cls and cls:IsValid() then return cls end
    return nil
end

local function EnsureGameMapWidget()
    if not USE_GAME_MAP then return nil end
    if W.gm and W.gm:IsValid() then return W.gm end
    if not (WidgetValid() and C.pc and C.pc:IsValid() and W.canvas) then return nil end
    local cls = FindGameMapClass()
    if not cls then
        if not S.gmWarned then
            S.gmWarned = true
            Log("game map: class not found (" .. GM_CLASS_PATH .. ") - staying on the vector map")
        end
        return nil
    end
    local ok, err = pcall(function()
        local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        local w = wbl:Create(C.pc, cls, C.pc)
        if not (w and w:IsValid()) then error("Create returned nothing") end
        local slot = W.canvas:AddChildToCanvas(w)
        if not (slot and slot:IsValid()) then error("AddChildToCanvas failed") end
        pcall(function()
            slot:SetAnchors({ Minimum = { X = 1.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 0.0 } })
        end)
        -- added last, so by insertion order it would sit ON TOP of the
        -- marker; push it under everything the pool and marker draw
        pcall(function() slot:SetZOrder(-10) end)
        W.gm, W.gmSlot = w, slot
    end)
    if not ok or not (W.gm and W.gm:IsValid()) then
        W.gm, W.gmSlot = nil, nil
        if not S.gmWarned then
            S.gmWarned = true
            Log("game map: could not create/attach widget (" .. tostring(err)
                .. ") - staying on the vector map")
        end
        return nil
    end
    -- the three fields the game wires up for us
    pcall(function() W.gmImage = W.gm.MapImage end)
    pcall(function() W.gmRT = W.gm.PlayerHistoryRT end)
    pcall(function() W.gmMID = W.gm.DynamicMapMaterial end)
    Log(string.format("game map: widget created (MapImage=%s historyRT=%s MID=%s)",
        tostring(W.gmImage ~= nil and W.gmImage:IsValid()),
        tostring(W.gmRT ~= nil and W.gmRT:IsValid()),
        tostring(W.gmMID ~= nil and W.gmMID:IsValid())))
    return W.gm
end

-- Wipe the trail render target. Earlier attempts at this material looked
-- "polluted" with routes from previous runs; a fresh widget owns its own RT,
-- so clearing it once per run is all that is needed to own what is drawn.
local function ClearGameMapHistory()
    if not (GM_CLEAR_TRAIL and W.gmRT and W.gmRT:IsValid()) then return end
    local ok = pcall(function()
        local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
        krl:ClearRenderTarget2D(C.pc, W.gmRT, { R = 0.0, G = 0.0, B = 0.0, A = 0.0 })
    end)
    Log("game map: history RT " .. (ok and "cleared" or "clear FAILED"))
end

ApplyGameMap = function()
    local gm = W.gm
    if not (USE_GAME_MAP and gm and gm:IsValid()) then S.gmActive = false return end
    if not (S.gmReady and S.geo and S.geo.mapTex and S.lay) then
        pcall(function() gm:SetVisibility(1) end)
        S.gmActive = false
        return
    end
    local b = S.geo.mapBounds
    -- material params: the picture, and where the dungeon sits inside it
    local mid = W.gmMID
    if not (mid and mid:IsValid()) and W.gmImage and W.gmImage:IsValid() then
        pcall(function() mid = W.gmImage:GetDynamicMaterial() end)
        W.gmMID = mid
    end
    if mid and mid:IsValid() then
        pcall(function() mid:SetTextureParameterValue(FName("MapTexture"), S.geo.mapTex) end)
        -- v66: leaving UVOffset untouched means the material draws whatever it
        -- natively draws. If that is the full texture, the LocationMin/Max
        -- rect below is an exact mapping with no correction needed.
        if GM_SET_UV_PARAM then pcall(function()
            mid:SetVectorParameterValue(FName(GM_UV_PARAM), {
                R = b and b.offU or 0.0,
                G = b and b.offV or 0.0,
                B = (GM_PACK_COVER and b and b.covU and b.covU > 0) and b.covU or 1.0,
                A = (GM_PACK_COVER and b and b.covV and b.covV > 0) and b.covV or 1.0 })
        end) end
    end
    -- INVERTED APPROACH (v64). Previously the panel filled the map square and
    -- the marker was converted into the panel's space - which meant marker and
    -- image were positioned by two different chains that had to agree, and
    -- they did not (the image span is spun by ROT_ANGLE[(rot+aq)%4] while the
    -- marker used (rot+aq+TEX_QUARTER) quarter turns; those are not the same
    -- amount, so no per-marker flag could ever reconcile them - 8/8 tried).
    -- Now the IMAGE conforms to the grid instead: lay it over exactly the
    -- world rect it represents, expressed in our own grid space, using the
    -- SAME MapImageGridRect maths the rooms use. The marker then goes back to
    -- the plain grid path that was already proven correct on the vector map,
    -- and the two cannot disagree because only one transform exists.
    local placed = false
    -- ============ v67: ANCHOR THE PICTURE TO THE VECTOR MAP ============
    -- Five attempts to derive the placement from LocationMin/Max, CoverPercent
    -- and DungeonBounds each fit one dungeon and broke on the next, because
    -- what those fields actually mean keeps shifting. The vector map, though,
    -- is INDEPENDENTLY VERIFIED correct - the marker sits right on it every
    -- time. So stop deriving and anchor: the texture's content depicts the
    -- same rooms the vector layer draws, so place the content sub-rect
    -- (UVOffset..UVOffset+CoverPercent) exactly onto the rooms' bounding box.
    -- Correctness is then inherited from something already proven, and the
    -- only assumption left is that UVOffset/Cover locate the content.
    -- (User's suggestion 2026-08-18 - the right call.)
    if GM_ANCHOR_TO_ROOMS then
        pcall(function()
            local L = S.lay
            if not (L and L.scale and L.w and L.w > 0 and L.h and L.h > 0) then return end
            local cu = (b and b.covU and b.covU > 0) and b.covU or 1.0
            local cv = (b and b.covV and b.covV > 0) and b.covV or 1.0
            local ou, ov = (b and b.offU) or 0.0, (b and b.offV) or 0.0
            -- an odd display quarter-turn puts the texture's U axis on grid Y
            local angQ = math.floor((((S.geo.ang + 90 * TEX_QUARTER) % 360) + 360) % 360 / 90 + 0.5) % 4
            if (angQ % 2) == 1 then cu, cv, ou, ov = cv, cu, ov, ou end
            local fw, fh, fx, fy
            if GM_CONTENT_FILLS then
                -- the material crops to the content, so the widget IS the box
                fw, fh = L.w, L.h
                fx, fy = L.minX, L.minY
            else
                -- the widget shows the FULL texture; expand so the content
                -- sub-rect lands on the rooms box
                fw, fh = L.w / cu, L.h / cv
                fx = L.minX - ou * fw
                fy = L.minY - ov * fh
            end
            fx = fx + (S.imgOffX or 0)
            fy = fy + (S.imgOffY or 0)
            local sxm, sym = S.imgScaleX or 1.0, S.imgScaleY or 1.0
            local px = L.ox + (fx - L.minX) * L.scale
            local py = L.oy + (fy - L.minY) * L.scale
            local w, h = fw * L.scale * sxm, fh * L.scale * sym
            if sxm ~= 1.0 or sym ~= 1.0 then
                local cx, cy = px + fw * L.scale * 0.5, py + fh * L.scale * 0.5
                px, py = cx - w * 0.5, cy - h * 0.5
            end
            W.gmSlot:SetPosition({ X = px, Y = py })
            W.gmSlot:SetSize({ X = w, Y = h })
            placed = true
            S.gmRect = { aX = fx, aY = fy, bX = fx + fw, bY = fy + fh,
                         lminX = L.minX, lminY = L.minY, lw = L.w, lh = L.h,
                         mode = GM_CONTENT_FILLS and "contentFills" or "fullTexture" }
        end)
    end
    if not placed then pcall(function()
        local aX, aY, bX, bY = MapImageGridRect(b, S.geo)
        local L = S.lay
        if aX and L and L.scale and bX > aX and bY > aY then
            -- live-tunable offset in GRID TILES (Home/End/Del/Ins while the
            -- hosted map is up); F9 prints it so a settled value can become
            -- the permanent default
            aX = aX + (S.imgOffX or 0)
            aY = aY + (S.imgOffY or 0)
            local px = L.ox + (aX - L.minX) * L.scale
            local py = L.oy + (aY - L.minY) * L.scale
            local w = (bX - aX) * L.scale
            local h = (bY - aY) * L.scale
            -- Live scale about the rect's own centre. Screenshot evidence
            -- (2026-08-18) put the marker OUTSIDE the picture on whichever
            -- side it was nearest - left at the left, right at the right,
            -- below at the bottom. An offset moves a thing off one side and
            -- INTO the other; escaping on every side means the picture is
            -- drawn too SMALL. Predicted ~1.125 (DungeonBounds says 36x36
            -- tiles while the texture rect measures 32x32), so if the settled
            -- value lands there, the rect should be sized from the dungeon
            -- extent rather than from TextureSize.
            -- DERIVED SCALE (v65). Calibrated live to 1.200 on a dungeon that
            -- DungeonBounds reports as 36x36 tiles with a 32px texture:
            --     36 / (32 - 2) = 1.200   exactly.
            -- So the picture's content depicts the dungeon's REAL extent while
            -- occupying only TextureSize-2 pixels - a one-pixel empty border -
            -- and LocationMin/Max sizes the rect for the full 32. Compute it
            -- per dungeon; a hardcoded 1.2 would break on any other size.
            local sx = S.imgScaleX or 1.0
            local sy = S.imgScaleY or 1.0
            local bd, ts = S.geo.bnd, b and b.size
            if GM_AUTO_SCALE and bd and ts and ts > 2 * GM_TEX_MARGIN then
                local dtX = (bd.ex * 2) / S.geo.tile
                local dtY = (bd.ey * 2) / S.geo.tile
                -- AXIS TRANSPOSITION (fixed v65.2). The widget is drawn with a
                -- render-transform rotation of `ang + 90*TEX_QUARTER`. When
                -- that is an ODD number of quarter turns the content's X axis
                -- lands on the SLOT's Y axis, so a scale derived from the
                -- dungeon's X extent must be applied to the slot's HEIGHT.
                -- The old test keyed on `aq` alone, which is even (2) on every
                -- dungeon seen, so it never swapped - while the real angle is
                -- 270 (odd). sx and sy were therefore applied to each other's
                -- axes, which is why sizing "couldn't get anywhere close" and
                -- alignment held in one spot but drifted along a corridor
                -- (user report 2026-08-18). Derive it from the ACTUAL angle,
                -- not from a component of it: ROT_ANGLE is not a linear map of
                -- its index (index 3 = +90, not 270), so reconstructing the
                -- turn count from rot/aq/TEX_QUARTER arithmetic is unsafe.
                local angQ = math.floor((((S.geo.ang + 90 * TEX_QUARTER) % 360) + 360) % 360 / 90 + 0.5) % 4
                if (angQ % 2) == 1 then dtX, dtY = dtY, dtX end
                local frac = (ts - 2 * GM_TEX_MARGIN) / ts
                local rw, rh = bX - aX, bY - aY
                if rw > 0 and rh > 0 and frac > 0 and dtX > 0 and dtY > 0 then
                    sx = sx * (dtX / (rw * frac))
                    sy = sy * (dtY / (rh * frac))
                end
            end
            if sx ~= 1.0 or sy ~= 1.0 then
                local cx, cy = px + w * 0.5, py + h * 0.5
                w, h = w * sx, h * sy
                px, py = cx - w * 0.5, cy - h * 0.5
            end
            S.gmScaleUsed = { sx = sx, sy = sy }
            W.gmSlot:SetPosition({ X = px, Y = py })
            W.gmSlot:SetSize({ X = w, Y = h })
            placed = true
            S.gmRect = { aX = aX, aY = aY, bX = bX, bY = bY,
                         lminX = L.minX, lminY = L.minY, lw = L.w, lh = L.h }
        end
    end) end
    if not placed then
        -- no usable rect: fall back to filling the square rather than leaving
        -- the panel at a stale position
        pcall(function()
            W.gmSlot:SetPosition({ X = S.baseX, Y = S.baseY })
            W.gmSlot:SetSize({ X = S.size, Y = S.size })
        end)
    end
    pcall(function()
        gm:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
        gm:SetRenderTransformAngle(S.geo.ang + 90 * TEX_QUARTER)
        gm:SetRenderScale({ X = TEX_MIRROR_X and -1.0 or 1.0,
                            Y = TEX_MIRROR_Y and -1.0 or 1.0 })
    end)
    pcall(function() gm:SetVisibility(3) end) -- HitTestInvisible: never eats input
    S.gmActive = true
    -- one source or the other, never both fighting for the same square
    if GM_EXCLUSIVE and W.pool then
        pcall(function()
            for _, e in ipairs(W.pool) do e.img:SetVisibility(1) end
        end)
    end
    if not S.gmLogged then
        S.gmLogged = true
        Log(string.format("game map: LIVE (uv=%.3f,%.3f cover=%.3f,%.3f, angle=%.0f)",
            b and b.offU or -1, b and b.offV or -1,
            b and b.covU or -1, b and b.covV or -1,
            S.geo.ang + 90 * TEX_QUARTER))
        -- The image rect and the rooms' own layout bounds, in the SAME grid
        -- space. If the picture is offset from the rooms, the discrepancy is
        -- visible right here as numbers - no nudging needed to find it.
        local r = S.gmRect
        if r then
            Log(string.format(
                "game map RECT: image grid X[%.1f..%.1f] Y[%.1f..%.1f] (%.1fx%.1f tiles) | rooms layout minX=%.1f minY=%.1f w=%.1f h=%.1f | imgOff=(%.2f, %.2f)",
                r.aX, r.bX, r.aY, r.bY, r.bX - r.aX, r.bY - r.aY,
                r.lminX, r.lminY, r.lw, r.lh, S.imgOffX or 0, S.imgOffY or 0))
            local sc = S.gmScaleUsed
            if sc then
                Log(string.format(
                    "game map SCALE: applied sx=%.3f sy=%.3f (auto=%s, manual x%.3f, dungeon=%.1fx%.1f tiles, tex=%s px, margin=%d)",
                    sc.sx, sc.sy, tostring(GM_AUTO_SCALE), S.imgScaleX or 1.0,
                    S.geo.bnd and (S.geo.bnd.ex * 2 / S.geo.tile) or -1,
                    S.geo.bnd and (S.geo.bnd.ey * 2 / S.geo.tile) or -1,
                    tostring(b and b.size), GM_TEX_MARGIN))
            end
        end
    end
end

ApplyMapTexture = function()
    if not (SHOW_MAP_TEXTURE and W.tex and S.lay and S.geo and S.geo.mapTex) then
        pcall(function() if W.tex then W.tex:SetVisibility(1) end end)
        return
    end
    pcall(function()
        local b = S.geo.mapBounds
        local g = S.geo
        local loX, hiX = math.min(b.minX, b.maxX), math.max(b.minX, b.maxX)
        local loY, hiY = math.min(b.minY, b.maxY), math.max(b.minY, b.maxY)
        -- narrow to the region the material actually shows (UVOffset/Cover)
        if MAP_TEX_USE_UVCROP and b.covU and b.covU > 0 and b.covV and b.covV > 0 then
            local spanX, spanY = hiX - loX, hiY - loY
            local u0, v0 = b.offU or 0, b.offV or 0
            local nLoX = loX + u0 * spanX
            local nHiX = loX + (u0 + b.covU) * spanX
            local nLoY = loY + v0 * spanY
            local nHiY = loY + (v0 + b.covV) * spanY
            loX, hiX, loY, hiY = nLoX, nHiX, nLoY, nHiY
        end
        local minGX, minGY, maxGX, maxGY
        for _, c in ipairs({ { loX, loY }, { hiX, loY }, { loX, hiY }, { hiX, hiY } }) do
            local gx = (c[1] - g.actX) / g.tile
            local gy = (c[2] - g.actY) / g.tile
            gx, gy = RotPoint(g.aq, gx, gy)
            gx, gy = RotPoint(g.rot, gx, gy)
            minGX = (not minGX or gx < minGX) and gx or minGX
            minGY = (not minGY or gy < minGY) and gy or minGY
            maxGX = (not maxGX or gx > maxGX) and gx or maxGX
            maxGY = (not maxGY or gy > maxGY) and gy or maxGY
        end
        local L = S.lay
        local px = L.ox + (minGX - L.minX) * L.scale
        local py = L.oy + (minGY - L.minY) * L.scale
        local w = (maxGX - minGX) * L.scale
        local h = (maxGY - minGY) * L.scale
        W.texSlot:SetPosition({ X = px, Y = py })
        W.texSlot:SetSize({ X = w, Y = h })
        -- Exclusive mode: the image simply fills the map square. No attempt to
        -- reconcile it with our rectangles - the marker is placed in the
        -- image's own space below, so the two agree by construction.
        if MAP_IMAGE_EXCLUSIVE then
            W.texSlot:SetPosition({ X = S.baseX, Y = S.baseY })
            W.texSlot:SetSize({ X = S.size, Y = S.size })
            W.tex:SetColorAndOpacity(MAP_TEX_TINT)
            W.tex:SetRenderTransformAngle(g.ang + 90 * TEX_QUARTER)
            pcall(function()
                W.tex:SetRenderScale({ X = TEX_MIRROR_X and -1.0 or 1.0,
                                       Y = TEX_MIRROR_Y and -1.0 or 1.0 })
            end)
            W.tex:SetVisibility(3)
            -- hide the vector layer; the image is the map now
            pcall(function()
                for _, e in ipairs(W.pool) do e.img:SetVisibility(1) end
            end)
            return
        end
        W.tex:SetColorAndOpacity(MAP_TEX_TINT)
        W.tex:SetRenderTransformAngle(g.ang + 90 * TEX_QUARTER)
        pcall(function()
            W.tex:SetRenderScale({ X = TEX_MIRROR_X and -1.0 or 1.0,
                                   Y = TEX_MIRROR_Y and -1.0 or 1.0 })
        end)
        W.tex:SetVisibility(3)
    end)
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
            -- RE-KEY, DO NOT DISCARD (v80). Walked tiles used to be cosmetic
            -- dots, so wiping them on a late rotation correction was free.
            -- With FILL_UNMAPPED they are the ONLY record of geometry no data
            -- source describes - the ice cave - and a correction that arrives
            -- after you have explored it would erase that work (seen live
            -- 2026-08-18: 229 runs -> 202 when rot went 1 -> 2). The keys are
            -- in DISPLAY space, so undo the old spin and apply the new one.
            S.visited = RekeyVisited(S.visited, S.geo.rot, rot)
        end
    end
    -- DungeonBounds populates LATE, exactly like MapData: a run can build its
    -- map while the box still holds the PREVIOUS dungeon's values (observed
    -- 2026-08-17, run 4059 built at 22:46:22 off run 8287's box, corrected at
    -- 22:47:31). So re-read it every rebind. Only a change in the implied
    -- quarter-turn forces a rebuild - centre/extents do not feed the grid, so
    -- refreshing those in place costs nothing and keeps the freshest box
    -- available for anything that needs the world rect later.
    if addr == S.dungAddr and S.rects and S.geo then
        local nb = ReadDungeonBounds(d)
        if nb then
            local moved = BoundsDiffer(nb, S.geo.bnd)
            local newAq = BoundsQuarter(nb)
            S.geo.bnd = nb
            if USE_BOUNDS_ROT and newAq and newAq ~= S.geo.aq then
                Log(string.format(
                    "dungeon bounds caught up: aq %d -> %d - rebuilding map",
                    S.geo.aq, newAq))
                S.dungSig = nil    -- force the re-parse below
                -- aq changed: the whole grid frame moved, so walked tiles
                -- cannot be re-keyed by display rotation alone. This is rare
                -- (aq has never varied in testing) and losing them here is
                -- the safe option; a wrong-frame tile is worse than none.
                S.visited = {}
            elseif moved then
                Log(string.format(
                    "dungeon bounds updated (now %.0fx%.0f tiles, aq unchanged at %d)",
                    nb.ex * 2 / (S.geo.tile or 200), nb.ey * 2 / (S.geo.tile or 200),
                    S.geo.aq))
            end
        end
    end
    if addr == S.dungAddr and S.rects and sig == S.dungSig then
        -- dungeon geometry can stream in after generation, so re-read the floor
        -- a few times early in a run and rebuild the map if it grew
        -- Rescan counters live on S, not on geo: a rebuild replaces geo, so
        -- storing them there made every scan look like the first one and
        -- retriggered a rebuild forever (that was the flickering map).
        if USE_FLOOR_MESHES and S.geo and not S.floorRejected
           and (S.floorScans or 0) < FLOOR_RESCANS then
            local now = os.clock()
            if now - (S.floorScanAt or 0) > FLOOR_RESCAN_SECS then
                S.floorScanAt = now
                S.floorScans = (S.floorScans or 0) + 1
                local pts = CollectFloorWorldPoints(d)
                if #pts > 0 and #pts ~= (S.floorPts or -1) then
                    Log(string.format("floor grew: %d -> %d instances, rebuilding",
                        S.floorPts or 0, #pts))
                    S.floorPts = #pts
                    S.dungSig = nil -- force a rebuild that folds in the new floor
                end
            end
        end
        -- the map picture arrives well after generation; keep watching for it
        -- The picture arrives well after generation, and because the dungeon
        -- actor is reused between runs its texture gets swapped in place - so
        -- re-bind whenever the texture object itself changes, not just once.
        if (SHOW_MAP_TEXTURE or USE_GAME_MAP) and S.geo then
            -- Creation can fail the first time (the map widget is a UI asset
            -- that may not be resident yet), so keep retrying on the rebind
            -- tick rather than giving up after one attempt. Cheap: it returns
            -- immediately once the widget exists.
            if USE_GAME_MAP and S.gmReady and not (W.gm and W.gm:IsValid()) then
                if EnsureGameMapWidget() then
                    ClearGameMapHistory()
                    ApplyGameMap()
                end
            end
            local mt, mb = FindMapTexture(d)
            -- Exact staleness test. MapData.Seed is the run the picture was
            -- built for; the actor is reused between runs and keeps the old
            -- map until a new one is revealed. This replaces guessing from
            -- the covered rect, which passed a wrong map through on run 3.
            local seedOK, seedProven = true, false
            if SEED_GUARD and mb then
                local rs = RunSeed(d)
                if rs and mb.seed then
                    if rs == mb.seed then
                        seedProven = true      -- exact, positive confirmation
                    else
                        seedOK = false
                        if S.mapSeedWarned ~= mb.seed then
                            S.mapSeedWarned = mb.seed
                            Log(string.format(
                                "map image held back: built for seed %s, this run is %s",
                                tostring(mb.seed), tostring(rs)))
                        end
                    end
                end
            end
            -- MapImageFits was the OLD staleness heuristic: does the covered
            -- rect contain the rooms we parsed? It runs LocationMin/Max
            -- through our own grid maths, so any error in that maths rejects
            -- a perfectly good picture - and on 2026-08-17 23:10 it did
            -- exactly that, with run and map seeds matching at 28588 and the
            -- hosted widget still never coming up. An exact seed match is a
            -- strictly better test than a geometric guess, so when we have
            -- one, trust it; keep the heuristic only for when we do not.
            local fits = mt and seedOK and (seedProven or MapImageFits(mb, S.geo))
            -- Say WHY the hosted map is not up. Without this the feature is
            -- indistinguishable from broken: F5 toggles a flag, nothing
            -- changes on screen, and nothing explains it (hit exactly that
            -- 2026-08-17 23:08). Deduped on the reason string.
            if USE_GAME_MAP and not fits then
                local why
                if not mt then
                    why = "the game has not built this run's map picture yet"
                elseif mb and mb.seed == -1 then
                    why = "this run has no map picture yet - reveal/place a map in the dungeon"
                elseif not seedOK then
                    why = "the only picture available belongs to a previous run"
                else
                    why = "the picture failed the geometry check (seed could not be compared)"
                end
                if why ~= S.gmWhy then
                    S.gmWhy = why
                    Log("game map waiting: " .. why .. " - vector map is showing")
                end
            elseif fits then
                S.gmWhy = nil
            end
            local addrNow
            if mt then pcall(function() addrNow = mt:GetAddress() end) end
            if fits and addrNow ~= S.geo.mapTexAddr then
                S.geo.mapTex, S.geo.mapBounds, S.geo.mapTexAddr = mt, mb, addrNow
                -- v63: the picture for THIS run is confirmed present and
                -- seed-matched, so the game's own map panel can go live.
                if USE_GAME_MAP then
                    S.gmReady, S.gmLogged = true, false
                    if EnsureGameMapWidget() then
                        ClearGameMapHistory()
                        ApplyGameMap()
                    end
                end
                -- Render THROUGH the game's own map material, the way the
                -- game does. MapData.Texture looks like data rather than a
                -- finished picture, so drawing it raw shows the wrong thing;
                -- the material is what turns it into the map you see in game.
                local how = "none"
                if MAP_TEX_USE_MATERIAL then
                    local okMat = pcall(function()
                        local mat = StaticFindObject(MAP_TEX_MATERIAL)
                        if not (mat and mat:IsValid()) then error("material not found") end
                        W.tex:SetBrushFromMaterial(mat)
                        local mid = W.tex:GetDynamicMaterial()
                        if not (mid and mid:IsValid()) then error("no dynamic material") end
                        mid:SetTextureParameterValue(FName(MAP_TEX_PARAM), mt)
                        S.geo.mapMID = mid
                    end)
                    how = okMat and "material" or "material FAILED"
                end
                if how ~= "material" then
                    local okTex = pcall(function() W.tex:SetBrushFromTexture(mt, false) end)
                    how = how .. (okTex and " -> raw texture" or " -> raw FAILED")
                end
                Log(string.format("game map image bound (%dpx, via %s) uv=(%.3f,%.3f) cover=(%.3f,%.3f)",
                    mb.size, how, mb.offU or -1, mb.offV or -1, mb.covU or -1, mb.covV or -1))
                ApplyMapTexture()
            elseif S.geo.mapTex and not fits then
                -- what we are showing belongs to a different dungeon
                S.geo.mapTex, S.geo.mapBounds, S.geo.mapTexAddr = nil, nil, nil
                -- picture belongs to another dungeon: drop back to the vector
                -- map rather than showing a confidently wrong layout
                S.gmReady = false
                if ApplyGameMap then ApplyGameMap() end
                Log("map image no longer matches this dungeon - hidden until it regenerates")
                ApplyMapTexture()
            end
        end
        return true
    end
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
    Log(string.format("map built: %d runs, floor tiles=%d, rot=%d aq=%d (elev yaw=%s), ext=%d",
        #rects, (geo.stats and geo.stats.floorTiles) or 0,
        geo.rot, geo.aq, tostring(geo.yaw), geo.ext))
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
    -- TRUE tile position, before the display nudge. calX/calY are a SCREEN
    -- offset for the arrow, not a correction to where you are - feeding them
    -- into the walked-tile capture records every tile half a tile off, which
    -- near a room edge lands OUTSIDE the room and paints a phantom stub on
    -- the map (user-annotated screenshots, 2026-08-18: small nubs hanging off
    -- the layout in places that are not reachable).
    local trueGX, trueGY = gx, gy
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
    -- describes adds it to the map. Uses the TRUE position, not the
    -- display-nudged one - see the note where calX/calY are applied.
    local tx, ty = math.floor(trueGX), math.floor(trueGY)
    local tkey = tx .. "," .. ty
    if (SHOW_TRAIL or FILL_UNMAPPED) and tkey ~= S.lastTileKey then
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
    -- When the game's image IS the map, place the marker inside the image's
    -- own world rect instead of our grid, so marker and map share one source.
    -- v64: when the hosted panel is up it is now laid over its own world rect
    -- in GRID space, so the marker keeps the plain grid placement above (the
    -- one the vector map proved correct) and no image-space conversion runs
    -- at all. MAP_IMAGE_EXCLUSIVE is the retired raw-texture path.
    if (not S.gmActive) and MAP_IMAGE_EXCLUSIVE and S.geo.mapTex and S.geo.mapBounds then
        local b = S.geo.mapBounds
        local loX, hiX = math.min(b.minX, b.maxX), math.max(b.minX, b.maxX)
        local loY, hiY = math.min(b.minY, b.maxY), math.max(b.minY, b.maxY)
        if hiX > loX and hiY > loY then
            local u = (loc.X - loX) / (hiX - loX)
            local v = (loc.Y - loY) / (hiY - loY)
            -- u,v here is the position normalised inside LocationMin/Max.
            -- Turning that into a PANEL coordinate depends on what the panel
            -- shows. The documented relation is
            --     textureUV = UVOffset + normalised * CoverPercent
            -- so if the panel draws the FULL texture the marker must be
            -- pushed into that sub-rect; if the material crops to the dungeon
            -- then the panel IS the sub-rect and u,v already fit.
            -- v63.3: my first attempt did (u - off)/cover, which is neither -
            -- it drove u negative and clamped the marker to the left edge,
            -- exactly as seen on screen 2026-08-17 23:1x.
            if S.gmActive and not GM_MARKER_CROPPED then
                u = (b.offU or 0) + u * ((b.covU and b.covU > 0) and b.covU or 1.0)
                v = (b.offV or 0) + v * ((b.covV and b.covV > 0) and b.covV or 1.0)
            end
            -- world->texture-UV convention correction, MARKER ONLY. Applied
            -- before the shared display rotation below, so it changes how the
            -- marker sits ON the map rather than spinning both together.
            if S.gmActive then
                if MK_SWAP_UV then u, v = v, u end
                if MK_FLIP_U then u = 1 - u end
                if MK_FLIP_V then v = 1 - v end
            end
            if S.gmActive and not S.gmUVLogged then
                S.gmUVLogged = true
                -- Every one of the 8 conventions produced a uv within
                -- 0.42..0.58 (2026-08-17 23:47), i.e. all of them sat near
                -- the middle of the map. Swapping/flipping values that are
                -- already ~0.5 cannot move a marker to the edge, so the fault
                -- is upstream in this normalisation, not in the convention.
                -- Dump the raw inputs so the transform can be DERIVED rather
                -- than guessed: the grid position below is known-good (the
                -- vector map places the marker correctly from it), so grid
                -- and uv together pin down the right mapping.
                Log(string.format(
                    "MARKER SOLVE: world=(%.0f, %.0f) grid=(%.2f, %.2f) | texRect X[%.0f..%.0f] Y[%.0f..%.0f] span=(%.0f, %.0f)",
                    loc.X, loc.Y, gx, gy, loX, hiX, loY, hiY, hiX - loX, hiY - loY))
                Log(string.format(
                    "MARKER SOLVE: raw uv=(%.3f, %.3f) -> final uv=(%.3f, %.3f) | off=(%.3f, %.3f) cover=(%.3f, %.3f) | actor=(%.0f, %.0f) tile=%.0f",
                    (loc.X - loX) / (hiX - loX), (loc.Y - loY) / (hiY - loY), u, v,
                    b.offU or -1, b.offV or -1, b.covU or -1, b.covV or -1,
                    S.geo.actX, S.geo.actY, S.geo.tile))
            end
            -- same quarter turns the image itself receives, about its centre
            local q = ((S.geo.rot + S.geo.aq + TEX_QUARTER) % 4)
            for _ = 1, q do
                u, v = 1 - v, u
            end
            if TEX_MIRROR_X then u = 1 - u end
            if TEX_MIRROR_Y then v = 1 - v end
            px = S.baseX + u * S.size
            py = S.baseY + v * S.size
        end
    end
    if not px then return end
    local lo, hi = S.baseX, S.baseX + S.size
    if px < lo then px = lo elseif px > hi then px = hi end
    if py < S.baseY then py = S.baseY elseif py > S.baseY + S.size then py = S.baseY + S.size end
    local m = MARKER_PX * (S.size / MAP_SIZE)
    local yaw = 0
    pcall(function() yaw = C.pc:GetControlRotation().Yaw end)
    local ang = yaw + S.geo.ang
    if MIRROR_X then ang = 180 - ang end
    -- Player arrow: UMG has no triangle brush, so the shape is built from a
    -- stack of bars that taper from tip to tail. Each bar is placed by
    -- rotating its local offset into screen space and is itself rotated by
    -- the same angle, so the whole thing reads as one solid triangle.
    pcall(function()
        W.markerSlot:SetPosition({ X = px - m / 2, Y = py - m / 2 })
        W.markerSlot:SetSize({ X = 0, Y = 0 })
        local rad = math.rad(ang)
        local cs, sn = math.cos(rad), math.sin(rad)
        local L = m * MARKER_LEN    -- tip-to-tail length
        local Wd = m * MARKER_WIDTH -- width at the tail
        -- hollow outline triangle: three thin bars along its edges. Corners in
        -- local space (+x forward): tip ahead, two tail corners behind.
        local corners = {
            { L * 0.5, 0 },
            { -L * 0.5, -Wd * 0.5 },
            { -L * 0.5, Wd * 0.5 },
        }
        local th = math.max(1.0, m * MARKER_STROKE)
        for i, seg in ipairs(W.tri) do
            if i <= 3 then
                local a = corners[i]
                local b = corners[(i % 3) + 1]
                local mx, my = (a[1] + b[1]) / 2, (a[2] + b[2]) / 2
                local dx, dy = b[1] - a[1], b[2] - a[2]
                local len = math.sqrt(dx * dx + dy * dy) + th * 0.5
                local edgeAng = math.deg(math.atan(dy, dx))
                -- rotate the edge midpoint into screen space
                local sx = px + mx * cs - my * sn
                local sy = py + mx * sn + my * cs
                seg.slot:SetPosition({ X = sx - len / 2, Y = sy - th / 2 })
                seg.slot:SetSize({ X = len, Y = th })
                seg.img:SetColorAndOpacity(MARKER_COLOR)
                seg.img:SetRenderTransformAngle(ang + edgeAng)
                seg.img:SetVisibility(3)
            else
                seg.img:SetVisibility(1)
            end
        end
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

-- resize on numpad +/- AND the main-row -/= keys left of Backspace
-- (player feedback: tenkeyless keyboards have no numpad)
do
    local function BindResize(names, delta)
        for _, name in ipairs(names) do
            local key = Key[name]
            if key then
                local ok = pcall(function()
                    RegisterKeyBind(key, function()
                        ExecuteInGameThread(function() pcall(Resize, delta) end)
                    end)
                end)
                if ok then return end
            end
        end
    end
    BindResize({ "ADD" }, SIZE_STEP)
    BindResize({ "SUBTRACT" }, -SIZE_STEP)
    BindResize({ "OEM_PLUS", "EQUALS" }, SIZE_STEP)
    BindResize({ "OEM_MINUS", "MINUS" }, -SIZE_STEP)
end

-- live calibration: nudge marker+trail in quarter-tile steps on screen.
-- Home = up, End = down, Delete = left, Insert = right. Read values with F9.
local function Nudge(dx, dy)
    -- Four before/after screenshot pairs (2026-08-18) showed the marker
    -- sitting ON rooms in the vector map but in black space on the hosted
    -- image - same marker, same canvas position in both. So the MARKER is
    -- right and the IMAGE rect is offset. Nudging calX/calY would "fix" the
    -- image by breaking the vector map, so while the hosted map is up these
    -- keys move the IMAGE instead. Measuring the offset also diagnoses it:
    -- land on a half tile and it is a pixel-centre convention, land on a
    -- whole tile and the rect origin is off by a tile.
    if S.gmActive then
        S.imgOffX = (S.imgOffX or 0) + dx
        S.imgOffY = (S.imgOffY or 0) + dy
        Log(string.format("image offset: (%.2f, %.2f) grid tiles", S.imgOffX, S.imgOffY))
        if ApplyGameMap then pcall(ApplyGameMap) end
        return
    end
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

-- F7 STATE-TEXTURE PROBE REMOVED (2026-08-17): DungeonStateTexture is
-- 256x256 and ReadRenderTargetPixel does a synchronous GPU readback PER
-- CALL - ~2700 of them in one frame crashed the game. Every sample also
-- came back black, so the state RT is not the room layout. Never bulk-read
-- render targets from Lua. (F7 also collides with GripAndFlip's debug key.)

-- F7: READ-ONLY probe of the dungeon's instanced meshes. The generator builds
-- the dungeon out of instanced static meshes, so their per-instance positions
-- are ground truth for what floor actually exists - including the prefab
-- rooms we only have bounding boxes for. This only counts and logs; it never
-- draws, writes, or reads a texture back. If the tiles it reports line up
-- with real floor, it can replace our dependence on the game's map picture.
RegisterKeyBind(Key.F7, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local d = GetActiveDungeon()
            if not d or not d:IsValid() then Log("F7: no active dungeon") return end
            local dAddr = d:GetAddress()
            local g = S.geo
            if not g then Log("F7: no geometry parsed yet") return end
            -- v74: the ice/snow caves never reach the map because the
            -- collector only accepts components OWNED BY THE DUNGEON ACTOR,
            -- and static level geometry belongs to the level or another actor.
            -- The data proved it: of ~82 stray tiles, 75 were wall bleed and
            -- only ~7 survived - nowhere near a room. List EVERY instanced
            -- mesh component whose instances sit inside DungeonBounds no
            -- matter who owns it, so the real owner and mesh name are known
            -- instead of guessed at.
            pcall(function()
                local g = S.geo
                local b = g and g.bnd
                if not b then Log("  (no DungeonBounds - skipping foreign scan)") return end
                local seen, listed = {}, 0
                for _, cls in ipairs({ "InstancedStaticMeshComponent",
                                       "HierarchicalInstancedStaticMeshComponent" }) do
                    local found = FindAllOf(cls) or {}
                    for _, c in ipairs(found) do
                        pcall(function()
                            if not c:IsValid() then return end
                            local owner = c:GetOwner()
                            if not (owner and owner:IsValid()) then return end
                            local oname = owner:GetFullName() or "?"
                            -- inside the dungeon's own oriented box (padded)?
                            local cl = c:K2_GetComponentLocation()
                            if math.abs(cl.X - b.cx) > b.ex + 2000
                               or math.abs(cl.Y - b.cy) > b.ey + 2000 then return end
                            local mname = "?"
                            pcall(function() mname = c.StaticMesh:GetFullName() end)
                            local short = mname:match("[^%.]+$") or mname
                            local key = short .. "|" .. (oname:match("[^%.]+$") or oname)
                            if seen[key] then return end
                            seen[key] = true
                            local n = 0
                            pcall(function() n = #c.PerInstanceSMData end)
                            if listed < 40 then
                                listed = listed + 1
                                Log(string.format("  near-dungeon mesh: %-46s x%-5d owner=%s",
                                    short, n, oname:match("[^%.]+$") or oname))
                            end
                        end)
                    end
                end
                Log("  (^ anything here NOT owned by the dungeon actor is invisible to the floor collector)")
            end)
            Log("=== instanced mesh probe ===")
            local comps = {}
            for _, cls in ipairs({ "InstancedStaticMeshComponent",
                                   "HierarchicalInstancedStaticMeshComponent" }) do
                pcall(function()
                    local found = FindAllOf(cls)
                    if not found then return end
                    for _, c in ipairs(found) do
                        pcall(function()
                            if not c:IsValid() then return end
                            local owner
                            pcall(function() owner = c:GetOwner() end)
                            if owner and owner:IsValid() and owner:GetAddress() == dAddr then
                                comps[#comps + 1] = c
                            end
                        end)
                    end
                end)
            end
            Log("components owned by this dungeon: " .. #comps)
            if #comps == 0 then
                Log("  (none - the dungeon is not built from instanced meshes)")
                return
            end
            local BUDGET = 6000
            local read, failed = 0, 0
            local tiles = {}
            for ci, c in ipairs(comps) do
                if read >= BUDGET then break end
                local n, meshName = 0, "?"
                pcall(function() n = c:GetInstanceCount() end)
                -- no GetStaticMesh() in this build; read the property instead
                pcall(function() meshName = c.StaticMesh:GetFullName() end)
                if ci <= 12 then
                    Log(string.format("  comp %d: %d instances  %s", ci, n, meshName))
                end
                -- PerInstanceSMData is a reflected array of {Transform=FMatrix};
                -- reading it avoids GetInstanceTransform's FTransform out-param,
                -- which UE4SS could not marshal (every call failed).
                local arr
                pcall(function() arr = c.PerInstanceSMData end)
                local arrN = 0
                if arr then pcall(function() arrN = #arr end) end
                if ci <= 3 then
                    Log(string.format("    PerInstanceSMData readable=%s len=%d",
                        tostring(arr ~= nil), arrN))
                end
                for i = 1, arrN do
                    if read >= BUDGET then break end
                    local wx, wy
                    local okT = pcall(function()
                        local m = arr[i].Transform
                        -- FMatrix translation lives in the last row
                        wx = m.WPlane and m.WPlane.X or m.M[3][0]
                        wy = m.WPlane and m.WPlane.Y or m.M[3][1]
                    end)
                    if okT and wx and wy then
                        read = read + 1
                        pcall(function()
                            local gx = (wx - g.actX) / g.tile
                            local gy = (wy - g.actY) / g.tile
                            gx, gy = RotPoint(g.aq, gx, gy)
                            gx, gy = RotPoint(g.rot, gx, gy)
                            tiles[math.floor(gx) .. "," .. math.floor(gy)] = true
                        end)
                    else
                        failed = failed + 1
                        if failed == 1 then
                            pcall(function()
                                local m = arr[i].Transform
                                local keys = {}
                                for k, _ in pairs(m) do keys[#keys + 1] = tostring(k) end
                                Log("    matrix fields seen: " .. table.concat(keys, ","))
                            end)
                        end
                    end
                end
            end
            local nTiles, newTiles = 0, 0
            for k in pairs(tiles) do
                nTiles = nTiles + 1
                if g.occ and not g.occ[k] then newTiles = newTiles + 1 end
            end
            Log(string.format("instances read=%d failed=%d -> %d distinct tiles, %d NOT in our map",
                read, failed, nTiles, newTiles))
            Log("  (a healthy result: many tiles, and the extras land in the prefab rooms)")
        end)
        -- report the probe's own failures; a bare pcall here hid a nil-compare
        -- and made a broken probe look like an empty result
        local pok, perr = pcall(ProbeNavAndOverlap)
        if not pok then Log("nav/overlap probe FAILED: " .. tostring(perr)) end
        if not ok then Log("F7 ERROR: " .. tostring(err)) end
    end)
end)

-- ===================== NAVMESH + OVERLAP PROBE (v82) =======================
-- Two INDEPENDENT sources of "is this tile real space", neither of which cares
-- how the geometry was authored - which is the whole point, since four
-- asset-enumeration routes all missed the ice cave and the elevator.
--   NAVMESH: the game must path enemies through those rooms, so the nav data
--            knows they are walkable. K2_ProjectPointToNavigation returns a
--            bool and an FVector out-param - NOT an FHitResult, so it dodges
--            the trace crash landmine.
--   OVERLAP: you can stand on that floor, so it has collision.
--            SphereOverlapActors returns an array, also FHitResult-free.
-- Read-only and manual (F7). Nothing here feeds the map yet - this run is to
-- find out which source is worth building on, with numbers instead of theory.
function ProbeNavAndOverlap()
    local g, L = S.geo, S.lay
    if not (g and L) then Log("nav/overlap probe: no map yet"); return end
    local navSys = StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1")
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local pc = C.pc
    local pz = 0
    pcall(function() pz = C.pawn:K2_GetActorLocation().Z end)
    Log(string.format("=== nav/overlap probe (navSys=%s kismet=%s, z=%.0f) ===",
        tostring(navSys ~= nil), tostring(ksl ~= nil), pz))

    local t0 = os.clock()
    local nNav, nOvl, nOcc, nNavOnly, nOvlOnly, tested = 0, 0, 0, 0, 0, 0
    local navSet, ovlSet = {}, {}
    local undoRot, undoAq = (4 - (g.rot or 0)) % 4, (4 - (g.aq or 0)) % 4
    for y = L.minY, L.minY + L.h - 1 do
        for x = L.minX, L.minX + L.w - 1 do
            if tested >= NAV_PROBE_BUDGET then break end
            tested = tested + 1
            -- rotated display tile -> raw generator grid -> world centre
            local ux, uy = RotTile(undoRot, x, y)
            local rx, ry = RotTile(undoAq, ux, uy)
            local wx = g.actX + (rx + 0.5) * g.tile
            local wy = g.actY + (ry + 0.5) * g.tile
            local key = x .. "," .. y
            local occHere = g.occ and g.occ[key] and true or false
            if occHere then nOcc = nOcc + 1 end

            local onNav = false
            if navSys then
                pcall(function()
                    local out = {}
                    local ok = navSys:K2_ProjectPointToNavigation(pc,
                        { X = wx, Y = wy, Z = pz }, out, nil, nil,
                        { X = g.tile * 0.5, Y = g.tile * 0.5, Z = 500.0 })
                    if ok == true then onNav = true end
                end)
            end
            local onOvl = false
            if ksl then
                pcall(function()
                    local hits = {}
                    local ok = ksl:SphereOverlapActors(pc,
                        { X = wx, Y = wy, Z = pz }, g.tile * 0.45,
                        { 0 }, nil, {}, hits)
                    if ok == true then onOvl = true end
                end)
            end
            if onNav then nNav = nNav + 1; navSet[key] = true
                if not occHere then nNavOnly = nNavOnly + 1 end end
            if onOvl then nOvl = nOvl + 1; ovlSet[key] = true
                if not occHere then nOvlOnly = nOvlOnly + 1 end end
        end
    end
    Log(string.format(
        "nav/overlap: %d tiles tested | our map %d | navmesh %d (%d we lack) | overlap %d (%d we lack) | %.0f ms",
        tested, nOcc, nNav, nNavOnly, nOvl, nOvlOnly, (os.clock() - t0) * 1000))
    if nNav == 0 and nOvl == 0 then
        Log("nav/overlap: BOTH returned nothing - the calls are not resolving, not evidence about the map")
        return
    end
    -- side-by-side picture: # ours, N navmesh only, O overlap only, B both
    Log("nav/overlap legend: '#' ours  'N' navmesh-only  'O' overlap-only  'B' both-but-not-ours  '.' nothing")
    for y = L.minY, L.minY + L.h - 1 do
        local row = {}
        for x = L.minX, L.minX + L.w - 1 do
            local key = x .. "," .. y
            local o = g.occ and g.occ[key]
            local n, v = navSet[key], ovlSet[key]
            row[#row + 1] = o and "#" or (n and v and "B") or (n and "N")
                or (v and "O") or "."
        end
        Log("| " .. table.concat(row))
    end
end

-- F3: hide the bounding-box (guessed) rooms, leaving only geometry we know
-- per-tile. Whatever still fails to match the in-game map after this is a
-- real problem in our reconstruction, not a guess.
pcall(function()
    RegisterKeyBind(Key.F3, function()
        ExecuteInGameThread(function()
            pcall(function()
                HINTS_DISABLED = not HINTS_DISABLED
                S.dungSig = nil
                Log("guessed bounding-box rooms " ..
                    (HINTS_DISABLED and "HIDDEN (only per-tile geometry)" or "shown"))
            end)
        end)
    end)
end)

-- F4: temporarily drop the auto-rotation so the map is drawn in the dungeon's
-- NATIVE orientation - the same way the table map and the end-screen "YOUR
-- JOURNEY" draw it. Purely for comparing the two side by side; the shipped
-- behaviour is rotated so the spawn elevator faces up.
pcall(function()
    RegisterKeyBind(Key.F4, function()
        ExecuteInGameThread(function()
            pcall(function()
                ROT_DISABLED = not ROT_DISABLED
                S.dungSig = nil -- force a rebuild in the new orientation
                Log("auto-rotation " .. (ROT_DISABLED and "OFF (native orientation, matches the in-game map)"
                                                      or "ON (elevator faces up)"))
            end)
        end)
    end)
end)

-- F11 / F12: shrink / grow the hosted map picture about its centre. The
-- settled value is the diagnosis: ~1.125 means the rect must be sized from
-- the dungeon's real extent (36 tiles) rather than TextureSize (32).
-- The derived scale was verified on a cover=(1,1) dungeon but is wrong on a
-- cover<1 one, and the error differs per axis - so X and Y need dialling
-- INDEPENDENTLY. F2 picks which axis F11/F12 drive (both -> X -> Y); two
-- settled numbers from a cover<1 dungeon are enough to solve the real law.
local function ScaleStep(d)
    local m = S.scaleAxis or "both"
    if m ~= "y" then S.imgScaleX = (S.imgScaleX or 1.0) + d end
    if m ~= "x" then S.imgScaleY = (S.imgScaleY or 1.0) + d end
    Log(string.format("image scale: x=%.3f y=%.3f (adjusting %s)",
        S.imgScaleX or 1.0, S.imgScaleY or 1.0, m))
    if ApplyGameMap then ApplyGameMap() end
end
pcall(function()
    RegisterKeyBind(Key.F11, function()
        ExecuteInGameThread(function() pcall(ScaleStep, -0.02) end)
    end)
end)
pcall(function()
    RegisterKeyBind(Key.F12, function()
        ExecuteInGameThread(function() pcall(ScaleStep, 0.02) end)
    end)
end)

-- F2: flip how the marker maps into the hosted panel (cropped sub-rect vs
-- full texture). Only two possibilities and the wrong one is obvious on
-- screen, so a live toggle settles it in seconds instead of a restart each.
pcall(function()
    RegisterKeyBind(Key.F2, function()
        ExecuteInGameThread(function()
            pcall(function()
                -- REPURPOSED: the 8 marker conventions are dead since v64 put
                -- the marker back on the grid path. F2 now selects which axis
                -- F11/F12 scale, which is what actually needs tuning.
                -- v67: F2 flips the one remaining unknown - does the panel
                -- show only the dungeon content, or the whole texture?
                -- v85: REPURPOSED again. The image path is parked, so the
                -- anchor toggle is dead weight - whereas FOUR floor sources
                -- now stack (rooms, floor meshes, navmesh, walked tiles) and
                -- nothing could tell them apart on screen. Cycle them so the
                -- source responsible for any wrong tile is visible directly
                -- instead of inferred from a screenshot.
                local m = ((S.srcMode or 1) + 1) % 4
                S.srcMode = m
                USE_FLOOR_MESHES = m >= 1
                NAVMESH_FILL     = m >= 2
                FILL_UNMAPPED    = m >= 3
                local names = { [0] = "rooms only",
                                [1] = "rooms + floor meshes (default)",
                                [2] = "rooms + floor + navmesh",
                                [3] = "rooms + floor + navmesh + walked" }
                Log("floor sources " .. m .. "/3: " .. names[m])
                S.dungSig = nil     -- force a re-parse with the new set
                S.floorRejected = nil
            end)
        end)
    end)
end)

-- F5: game map <-> vector map, live. This is the A/B switch AND the escape
-- hatch: if the hosted widget renders wrong, one key gets the working vector
-- map back without a restart. F5 was free (F3/F4/F6/F8/F9 are this mod's,
-- F7 is GripAndFlip's, F10 toggles the UE4SS console).
pcall(function()
    RegisterKeyBind(Key.F5, function()
        ExecuteInGameThread(function()
            pcall(function()
                USE_GAME_MAP = not USE_GAME_MAP
                if not USE_GAME_MAP then
                    S.gmActive = false
                    pcall(function()
                        if W.gm and W.gm:IsValid() then W.gm:SetVisibility(1) end
                    end)
                else
                    S.gmLogged = false
                end
                Log("game map " .. (USE_GAME_MAP and "ON" or "OFF (vector map)"))
                ApplyLayout()   -- re-shows the vector layer, then re-applies
            end)
        end)
    end)
end)

-- F6: cycle the 8 possible orientations of the game map image
pcall(function()
    RegisterKeyBind(Key.F6, function()
        ExecuteInGameThread(function()
            pcall(function()
                local n = (TEX_QUARTER
                    + (TEX_MIRROR_X and 4 or 0)
                    + (TEX_MIRROR_Y and 8 or 0) + 1) % 16
                -- walk the 8 valid combos: quarter 0-3 x mirrorX x mirrorY
                TEX_QUARTER = n % 4
                TEX_MIRROR_X = (n % 8) >= 4
                TEX_MIRROR_Y = n >= 8
                Log(string.format("map image orientation: quarter=%d mirrorX=%s mirrorY=%s",
                    TEX_QUARTER, tostring(TEX_MIRROR_X), tostring(TEX_MIRROR_Y)))
                ApplyMapTexture()
                -- MUST re-apply to the hosted widget too. Without this F6
                -- only moved the MARKER (which reads TEX_QUARTER every frame)
                -- while the map itself never rotated - so cycling all 16
                -- combinations showed nothing but a wandering triangle
                -- (observed 2026-08-17 23:40-23:41).
                if ApplyGameMap then ApplyGameMap() end
            end)
        end)
    end)
end)

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
                Log(string.format("aq source: actor=%s bounds=%s (USE_BOUNDS_ROT=%s)",
                    tostring(S.geo.aqActor), tostring(S.geo.aqBounds),
                    tostring(USE_BOUNDS_ROT)))
                local b = S.geo.bnd
                if b then
                    Log(string.format(
                        "DungeonBounds: centre (%.0f, %.0f, %.0f) extents (%.0f, %.0f, %.0f) yaw=%s",
                        b.cx, b.cy, b.cz, b.ex, b.ey, b.ez, tostring(b.yaw)))
                else
                    Log("DungeonBounds: UNREADABLE (falling back to actor yaw)")
                end
            end
            Log(string.format("CALIBRATION: calX=%.2f calY=%.2f imgOff=(%.2f, %.2f) (report these!)",
                S.calX, S.calY, S.imgOffX or 0, S.imgOffY or 0) .. string.format(" imgScale x=%.3f y=%.3f", S.imgScaleX or 1.0, S.imgScaleY or 1.0))
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
            -- map-image alignment: compare the world rect the texture claims
            -- to cover against the rooms' own grid extent. If the two grid
            -- rects disagree, that difference IS the offset to correct.
            pcall(function()
                local mt, mb = FindMapTexture(d)
                if not mb then Log("  map image: not available yet") return end
                Log(string.format("  map image: %dpx  world X %.0f..%.0f  Y %.0f..%.0f",
                    mb.size, mb.minX, mb.maxX, mb.minY, mb.maxY))
                Log(string.format("  dungeon actor world (%.0f, %.0f) tile=%.0f rot=%d aq=%d",
                    geo.actX, geo.actY, geo.tile, geo.rot, geo.aq))
                local loX, hiX = math.min(mb.minX, mb.maxX), math.max(mb.minX, mb.maxX)
                local loY, hiY = math.min(mb.minY, mb.maxY), math.max(mb.minY, mb.maxY)
                local aX, aY, bX, bY
                for _, c in ipairs({ { loX, loY }, { hiX, loY }, { loX, hiY }, { hiX, hiY } }) do
                    local gx = (c[1] - geo.actX) / geo.tile
                    local gy = (c[2] - geo.actY) / geo.tile
                    gx, gy = RotPoint(geo.aq, gx, gy)
                    gx, gy = RotPoint(geo.rot, gx, gy)
                    aX = (not aX or gx < aX) and gx or aX
                    aY = (not aY or gy < aY) and gy or aY
                    bX = (not bX or gx > bX) and gx or bX
                    bY = (not bY or gy > bY) and gy or bY
                end
                Log(string.format("  map image grid rect: (%.1f, %.1f)..(%.1f, %.1f)", aX, aY, bX, bY))
                if S.lay then
                    Log(string.format("  rooms grid rect:     (%.1f, %.1f)..(%.1f, %.1f)",
                        S.lay.minX, S.lay.minY, S.lay.minX + S.lay.w, S.lay.minY + S.lay.h))
                end
            end)
            -- where does the game keep the finished map art? The end-screen
            -- "YOUR JOURNEY" image knows the true prefab-room shapes we only
            -- have bounding boxes for, so find which object actually carries
            -- a populated MapData/render target while a run is live.
            pcall(function()
                local das = FindAllOf("HeldenDungeonActor")
                if das then
                    for i, da in ipairs(das) do
                        pcall(function()
                            if da:IsValid() then
                                local md = da.MapData
                                Log(string.format("  dungeonActor[%d] texSize=%s hist=%s %s",
                                    i, tostring(md.TextureSize),
                                    tostring(#md.PlayerMapHistory), da:GetFullName()))
                            end
                        end)
                    end
                end
                local maps = FindAllOf("HeldenDungeonMap")
                if maps then
                    for i, mp in ipairs(maps) do
                        pcall(function()
                            if mp:IsValid() then
                                local st = mp.DungeonStateTexture
                                Log(string.format("  dungeonMap[%d] stateRT=%s mapDataTex=%s",
                                    i, tostring(st and st:IsValid()),
                                    tostring(mp.MapData.TextureSize)))
                            end
                        end)
                    end
                else
                    Log("  no HeldenDungeonMap actors loaded")
                end
            end)
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

Log("v86 loaded (default = rooms + floor meshes, the combination you judged best), F11/F12 = size, F4 = native orientation, F5 = game map on/off, F9 = debug, F8 = dump.")
