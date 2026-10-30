-- adaptive-enhance.lua - pick the heaviest enhancement this file can sustain, live.
--
-- Replaces the fixed rules ("RIFE only <=1080p30", static ratio profiles). Those were
-- measured at <=60fps on the old 1080p144 panel; on the 2560x1440@180 panel the same
-- "free" ArtCNN chain dropped 52 frames/s on 1080p180 and 123/s on 1440p180 files,
-- i.e. the 180fps library was being shown at ~60fps. Cost scales with pixels x fps,
-- so no single resolution/fps limit is right. Instead:
--
--   1. Build a ladder for this file, heaviest first:
--        rife180+chroma -> rife180+none -> rife90+... -> rife60+... -> rife30+...
--          -> mv<target>flow/block (same targets) -> full -> light -> chroma -> none
--      (RIFE and MV targets = refresh / 1, 2, 3, 6; interpolation rungs carry no CNN chain)
--      (rife rungs only when 2 x source fps fits under the display refresh)
--   2. Start at the highest rung not already known to fail for this exact
--      source/display combination (learned cache, expires after EXPIRE_DAYS).
--   3. Measure dropped / delayed frames and the filter output rate every WINDOW s.
--      BAD_WINDOWS bad windows in a row -> step down one rung and remember it.
--
-- Shader chain per render scale s = min(display_w / w, display_h / h):
--   s > 1.30 up     : full = Krig + ArtCNN (gate open)   light = Krig + CAS-scaled
--   0.95..1.30 1:1  : full = Krig + ArtCNN forced         light = Krig + CAS
--   s < 0.95 down   : full = Krig + adaptive-sharpen      light = (same as krig)
-- Content override (Alt+a/l/g) swaps the "full" chain; Alt+u returns to auto.
-- Any glsl-shaders change made by someone else (Alt+0..8) puts the file in manual mode.

local mp    = require 'mp'
local utils = require 'mp.utils'
local msg   = require 'mp.msg'

local ROOT     = (os.getenv("APPDATA") or ""):gsub("\\", "/") .. "/mpv"
local SH       = ROOT .. "/shaders/"
local MV_VF    = "@aemv:vapoursynth=file=[" .. ROOT .. "/vs/mvfps.vpy]:concurrent-frames=8:buffered-frames=16"
local RIFE_VF  = "@aerife:vapoursynth=file=[" .. ROOT .. "/vs/rife.vpy]:concurrent-frames=2:buffered-frames=4"
local CACHE    = ROOT .. "/adaptive-cache.json"

-- LOAD_DIR holds the AV1 transcode batch driver (av1drv.py); its driver_*.pid and PAUSE_PC
-- files are what compete with playback for load (spec 1).
local LOAD_DIR = "E:\\Movies\\_av1"

local EXPIRE_DAYS = 14
local WINDOW      = 2      -- seconds of playback per measurement window
local BAD_WINDOWS = 2      -- consecutive bad windows before stepping down (~4 s)
local WARM_SHADER = 3      -- seconds ignored after a shader change
local WARM_VF     = 7      -- seconds ignored after adding/removing RIFE (VapourSynth spin-up)

-- Chains, chosen 2026-10-06 from measurements on this machine (2560x1440@180, RX 9070 XT).
-- Render cost = libplacebo "fresh" passes per frame, 1080p source; quality = PSNR of a
-- paused frame vs a 1440p reference downscaled from a 4K master (dither and deband off),
-- three contents: 3D render / 2D anime / live action.
--
--   chain                 render   1080p->1440p (3d/2d/live)   720p->1440p (3d/2d/live)
--   none                  0.84ms   32.49 / 45.91 / 46.31       31.70 / 39.54 / 43.93
--   Krig + ArtCNN C4F32  10.9 ms   32.74 / 45.92 / 46.53       32.29 / 42.20 / 43.94
--   Krig + ArtCNN C4F16   4.5 ms   32.80 / 45.50 / 46.43       32.32 / 42.16 / 43.80
--   CfL  + ArtCNN C4F16   4.5 ms   32.79 / 45.63 / 46.49       32.31 / 42.27 / 43.85
--   CfL  + ravu-zoom-r3   1.8 ms   32.71 / 46.86 / 46.64       32.06 / 42.07 / 44.13
--   Krig + CAS-scaled     1.3 ms   32.69 / 45.21 / 46.10       31.79 / 39.13 / 43.59
--
-- * C4F32 (the old default) needs 10.9 ms per fresh frame, twice the 5.55 ms a 180 Hz
--   refresh allows: vsync jitter 0.36-0.39 vs 0.04 without it, even on 30/60fps sources
--   where no frame is dropped. That was the "bad frametime". C4F16 is the same quality.
-- * At 1.33x (1080p on this panel, the common case) ravu-zoom-ar-r3 beats both CNNs on
--   2D and live action and ties on 3D, at 40% of C4F16's cost. CNNs only pay off at 2x.
-- * CfL_Prediction >= KrigBilateral everywhere and is no more expensive.
-- * A 1:1 CNN (forced) at 1440p cannot fit a 180 Hz frame at any source fps; native
--   sources get chroma + CAS instead.
local CFL   = SH .. "CfL_Prediction.glsl"
local CFLL  = SH .. "CfL_Prediction_Lite.glsl"
local KRIG  = SH .. "KrigBilateral.glsl"
local RAVUZ = SH .. "ravu-zoom-ar-r3.hook"

-- full chain by content and scale class ("up2" = upscale >= 1.6x, "up" = 1.3-1.6x)
local FULL = {
    auto   = { up2 = { CFL, SH .. "ArtCNN_C4F16.glsl" },    up = { CFL, RAVUZ },
               native = { CFL, SH .. "CAS.glsl" },          down = { KRIG, SH .. "adaptive-sharpen.glsl" } },
    anime  = { up2 = { CFL, SH .. "ArtCNN_C4F16.glsl" },    up = { CFL, SH .. "ArtCNN_C4F16.glsl" },
               native = { CFL, SH .. "CAS.glsl" },          down = { KRIG, SH .. "adaptive-sharpen.glsl" } },
    live   = { up2 = { CFL, RAVUZ },                        up = { CFL, RAVUZ },
               native = { CFL },                            down = { KRIG, SH .. "adaptive-sharpen.glsl" } },
    grainy = { up2 = { CFL, SH .. "ArtCNN_C4F16_DN.glsl" }, up = { CFL, SH .. "ArtCNN_C4F16_DN.glsl" },
               native = { CFL },                            down = { KRIG } },
}
local LIGHT = {
    up2 = { CFLL, SH .. "CAS-scaled.glsl" }, up = { CFLL, SH .. "CAS-scaled.glsl" },
    native = { CFLL, SH .. "CAS.glsl" },     down = nil,
}
local CONTENT = { anime = true, live = true, grainy = true }
-- global rank, so a failure recorded on one ladder shape applies to another
local RANK = { full = 4, light = 3, chroma = 2, none = 1 }
-- RIFE rungs are named "rife<target fps>+chroma" / "rife<target>+none"; they rank above every
-- plain rung, higher target first. (Old caches may still hold "rife+full"/"rife+chroma".)
local function rank_of(name)
    if not name then return 1e9 end
    if RANK[name] then return RANK[name] end
    local mt, mk = name:match("^mv(%d+)(%a+)$")
    if mt then return 10 + tonumber(mt) / 10 + (mk == "flow" and 0.05 or 0) end
    local t, kind = name:match("^rife([%d%.]*)%+(%a+)$")
    if not kind then return 1e9 end
    t = tonumber(t) or 1000
    return 100 + t * 2 + (kind == "full" and 1.5 or kind == "chroma" and 1 or 0)
end

-- script-opts: adaptive_enhance-rife=auto|on|off, adaptive_enhance-content=auto|anime|live|grainy,
-- adaptive_enhance-resync_seek=yes (default no): for mpv driven by a device player (MultiFunPlayer-style)
-- that resyncs only on a seek event: after any mid-playback rung change (step-down, pin,
-- menu / key changes), issue an exact zero-length seek 1.5 s later, once the new shaders
-- have compiled. adaptive_enhance-skip_top=N (default 0): never use the N heaviest rungs
-- (for a machine where they have never held); clamped so the last rung always stays.
-- (the MultiFunPlayer instance starts with rife=off: a VapourSynth spin-up mid-file is a
-- 1.5 s hitch the device would follow)
-- RIFE defaults to OFF (2026-10-06): a rapid-seek test with RIFE active ended in a GPU
-- WATCHDOG live dump (driver reset), and the plugin freezes mpv.net. Opt in per session
-- from the Tab menu / Ctrl+r, or permanently with adaptive_enhance-rife=auto.
-- mv = MVTools motion interpolation (cheap, CPU block matching), ON by default since
-- 2026-10-07; RIFE (neural, GPU, much heavier) stays opt-in and ranks above it when on.
-- 2026-10-30, owner: RIFE default auto (startup hitch accepted, frame rate is the priority).
local opts = { rife = "auto", content = "auto", mv = "auto", resync_seek = false, skip_top = 0 }
require("mp.options").read_options(opts, "adaptive_enhance")
local skip_top = math.max(0, math.floor(tonumber(opts.skip_top) or 0))
local function skip_n(ladder) return math.min(skip_top, math.max(#ladder - 1, 0)) end   -- rungs never used
local rife_mode = (opts.rife == "on" or opts.rife == "auto") and opts.rife or "off"   -- auto | on | off   (session-wide, Ctrl+r / Tab menu)
local mv_mode = (opts.mv == "off") and "off" or "auto"   -- auto | off (Tab menu)
local session_content = CONTENT[opts.content] and opts.content or "auto"   -- auto | anime | live | grainy (session-wide, Alt+a/l/g/u / Tab menu)
local st                   -- per-file state

------------------------------------------------------------------ pure logic (testable without playback)
-- Kept free of mp.* so tests/test_learning.lua can load this file in its own Lua state and
-- call these directly (mpv gives every script a separate state, so a guarded export is the
-- only way to reach them; see the sentinel check just below).
local function res_bucket(w, h)
    -- long edge = the larger dimension; 2026-10-30 (spec 1). 1088 coded heights (H.264 pads
    -- 1080 to 1088) land in the same bucket as their display 1080, which is what we want.
    local long = math.max(w or 0, h or 0)
    local b
    if long <= 720 then b = "720"
    elseif long <= 1080 then b = "1080"
    elseif long <= 1440 then b = "1440"
    elseif long <= 2160 then b = "2160"
    elseif long <= 4096 then b = "4096"
    else b = "4096+" end
    -- VR side-by-side is wide (2:1) or square (1:1) and big; its own bucket so a headset file
    -- never shares a rung with a flat one.
    local r = (h or 0) > 0 and (w or 0) / h or 0
    if (w or 0) >= 3840 and (math.abs(r - 2.0) < 0.05 or math.abs(r - 1.0) < 0.05) then
        return "vr" .. b
    end
    return b
end

-- 29.97 / 30 / 31 share a bucket so NTSC pulldown variants keep one learned rung (spec 1).
local function fps_bucket(fps)
    fps = fps or 0
    if fps <= 25 then return "25"
    elseif fps <= 31 then return "31"
    elseif fps <= 50 then return "50"
    elseif fps <= 61 then return "61"
    elseif fps <= 121 then return "121"
    else return "121+" end
end

-- Real liveness check for a driver pid: a stale pid file after a reboot must not look busy
-- forever (pids get reused). Ask tasklist for that pid; it counts as live only when the call
-- succeeds, prints the quoted pid and an image whose first CSV field starts with "python".
local function default_alive(pid)
    local ok, res = pcall(mp.command_native, { name = "subprocess",
        args = { "tasklist", "/FI", "PID eq " .. tostring(pid), "/NH", "/FO", "CSV" },
        capture_stdout = true, playback_only = false })
    if not ok or type(res) ~= "table" then return false end
    local out = res.stdout
    if (res.status ~= 0 and not out) or type(out) ~= "string" then return false end
    if not out:find('"' .. tostring(pid) .. '"', 1, true) then return false end
    for line in out:gmatch("[^\r\n]+") do
        local first = line:match('^"%s*([^"]*)"') or line:match("^([^,]+)")
        if first and first:lower():match("^python") then return true end
    end
    return false
end

-- busy when a driver_*.pid names a live process and PAUSE_PC is absent, else idle; anything
-- missing or unreadable counts as idle. inj lets tests avoid E:\Movies (spec 1: once per file).
local function load_state(inj)
    inj = inj or {}
    local dir = inj.dir or LOAD_DIR
    local paused = inj.paused
    if paused == nil then
        local f = io.open(dir .. "/PAUSE_PC", "r")
        paused = f ~= nil
        if f then f:close() end
    end
    if paused then return "idle" end
    local names = inj.pid_files
    if not names then
        local ok, list = pcall(utils.readdir, dir)
        if not ok or type(list) ~= "table" then return "idle" end
        names = {}
        for _, n in ipairs(list) do
            if n:match("^driver_.*%.pid$") then names[#names + 1] = n end
        end
    end
    local alive = inj.alive or default_alive
    for _, n in ipairs(names) do
        local pid
        if inj.pid_of then
            pid = inj.pid_of(n)
        else
            local f = io.open(dir .. "/" .. n, "r")
            if f then pid = tonumber((f:read("*a") or ""):match("%d+")); f:close() end
        end
        if pid and alive(pid) then return "busy" end
    end
    return "idle"
end

local function exact_key(w, h, fps, dw, dh, dfps, content)
    return string.format("v2|%dx%d@%d>%dx%d@%d|%s", w, h, math.floor((fps or 0) + 0.5),
                         dw, dh, math.floor((dfps or 0) + 0.5), content)
end

local function class_key(w, h, fps, dw, dh, dfps, content, load)
    return string.format("c1|%s|%s|%dx%d@%d|%s|%s", res_bucket(w, h), fps_bucket(fps),
                         dw, dh, math.floor((dfps or 0) + 0.5), content, load or "idle")
end

local function level_of(ladder, name)
    if not name then return nil end
    for i, r in ipairs(ladder) do if r.name == name then return i end end
    return nil
end

-- A cache entry is dead after EXPIRE_DAYS (spec 7); a table without a timestamp is dead too.
local function expired(e, now, days)
    return not (type(e) == "table" and e.t and now - e.t < (days or EXPIRE_DAYS) * 86400)
end

-- Re-read right before writing and merge only this key, so a second player writing another key
-- concurrently is never clobbered (spec: concurrency). read/write are injected so tests can
-- drive it without touching the real cache file.
local function merge_write(read, write, key, update)
    local c = read()
    c[key] = type(update) == "function" and update(c[key]) or update
    write(c)
    return c[key]
end

-- Record a failure under one entry: keep the LIGHTER failing rung we have seen (the lower
-- rank_of, the conservative rule), so the learned limit never rises on a new failure (spec 5).
local function note_fail(e, rung, reason, now)
    e = e or {}
    if not e.bad or rank_of(e.bad) > rank_of(rung) then
        e.bad, e.why, e.t = rung, reason, now or os.time()
    end
    -- A rung that held on this entry is unsafe once a rung no lighter than it fails:
    -- rank_of(rung) <= rank_of(e.held) means the held rung is not below the failure.
    if e.held and rank_of(rung) <= rank_of(e.held) then e.held, e.held_n = nil, 0 end
    return e
end

-- A failed probe starts the clean-play count over (spec 4).
local function probe_failed(e)
    e = e or {}
    e.held_n = 0
    return e
end

-- Start rung (spec 3/4): exact-key knowledge first, then class, then today's top rung.
-- Returns level, reason, held rung, source ("exact"/"class"/nil).
local function pick_start(ladder, exact, cls, skip)
    skip = skip or 0
    local e, src
    if exact and (exact.held or exact.bad) then e, src = exact, "exact"
    elseif cls and (cls.held or cls.bad) then e, src = cls, "class" end
    local bad_r = (e and e.bad) and rank_of(e.bad) or 1e9
    if e and e.held then
        local lv = level_of(ladder, e.held)
        -- Trust the held rung only when it is strictly lighter than the learned bad rung;
        -- otherwise it is not a safe start and we fall through to the bad-only branch.
        if lv and lv > skip and rank_of(e.held) < bad_r then
            local up = lv - 1   -- one rung heavier
            if (e.held_n or 0) >= 3 and up > skip and rank_of(ladder[up].name) < bad_r then
                return up, "probe", e.held, src
            end
            return lv, src == "exact" and "exact held" or "class held", e.held, src
        end
    end
    if e and e.bad then
        for i = skip + 1, #ladder do
            if rank_of(ladder[i].name) < bad_r then return i, "bad-only", nil, src end
        end
        return #ladder, "bad-only", nil, src
    end
    return skip + 1, "none", nil, nil
end

local ADAPTIVE_PURE = {
    res_bucket = res_bucket, fps_bucket = fps_bucket, load_state = load_state,
    exact_key = exact_key, class_key = class_key, rank_of = rank_of, level_of = level_of,
    expired = expired, merge_write = merge_write, note_fail = note_fail,
    probe_failed = probe_failed, pick_start = pick_start,
}
-- Tests set the sentinel and loadfile() this script to get the table above without pressing play.
if _G.ADAPTIVE_PURE then return ADAPTIVE_PURE end

------------------------------------------------------------------ cache
local function cache_load()
    local f = io.open(CACHE, "r")
    if not f then return {} end
    local t = utils.parse_json(f:read("*a") or "") or {}
    f:close()
    local now, out = os.time(), {}
    for k, v in pairs(t) do
        if not expired(v, now) then out[k] = v end
    end
    return out
end

local function cache_save(c)
    -- write-then-rename so a second player (mpv.net, MultiFunPlayer's mpv) never reads a
    -- truncated file
    local tmp = CACHE .. ".tmp" .. tostring(mp.get_property_number("pid") or 0)
    local f = io.open(tmp, "w")
    if not f then return end
    f:write(utils.format_json(c)); f:close()
    os.remove(CACHE); os.rename(tmp, CACHE)
end

------------------------------------------------------------------ helpers
local function num(p) return mp.get_property_number(p) end

local function short(list)
    if not list or #list == 0 then return "none" end
    local n = {}
    for _, p in ipairs(list) do n[#n + 1] = (p:match("([^/]+)%.%w+$") or p) end
    return table.concat(n, "+")
end

local function publish()
    if not st then return end
    local r = st.ladder and st.ladder[st.level]
    local s = string.format(
        "enhance: %s%s [%s]  rung %d/%d%s  scale %.2f (%s)  content %s\n" ..
        "MV %s%s  RIFE %s%s  last window: drop %.1f/s delayed %.1f/s vf %.1ffps\n" ..
        "key %s\nclass %s  start %s  held_n %d  learned fail: %s",
        r and r.name or "?", st.manual and " (MANUAL)" or "", r and short(r.shaders) or "",
        st.level or 0, st.ladder and #st.ladder or 0,
        (skip_top > 0 and st.ladder) and string.format(" (top %d skipped)", skip_n(st.ladder)) or "", st.scale or 0, st.class or "?",
        st.content, mv_mode, st.mv_note or "", rife_mode, st.rife_note or "",
        st.last_drop or 0, st.last_delay or 0, st.last_vf or 0,
        st.key or "?", st.class_key or "?", st.start_reason or "-", st.held_n or 0, st.bad_name or "-")
    mp.set_property_native("user-data/adaptive/status", s)
end

local function osd(text, sec) mp.osd_message(text, sec or 2.5) end

------------------------------------------------------------------ ladder
-- Learned RIFE capacity in source pixels/s (stored in the cache file, same expiry).
-- Seed 55 Mpx/s from 2026-10-06 measurements: 1080p24 (50) holds, 1080p30 (62) is
-- borderline, 1080p60 (124) plays at 68% speed, 4K30 (249) at 30%.
-- 2026-10-07: budget is now in OUTPUT pixels/s (w x h x target fps), because RIFE can aim at
-- any target (180/90/60/30 for a 180 Hz panel) and its cost follows the frames it generates.
-- Seed 105 Mpx/s: 1080p24 -> 48 (99.5) held, 1080p30 -> 60 (124) was borderline.
local RIFE_SEED = 105e6
-- Per-class budget (spec 6) wins over the global one when this class has learned its own,
-- so a class that fails RIFE does not drag the whole machine down.
local function rife_budget()
    local c = cache_load()
    local ce = st and st.class_key and c[st.class_key]
    if ce and ce.rife_budget then return ce.rife_budget end
    local e = c["rife_budget_out"]
    return (e and e.rate) or RIFE_SEED
end
local function set_rife_budget(rate, why)
    local c = cache_load()
    c["rife_budget_out"] = { rate = rate, t = os.time(), why = why }
    cache_save(c)
    if st and st.class_key then
        merge_write(cache_load, cache_save, st.class_key, function(e)
            e = e or {}; e.rife_budget = rate; e.t = os.time(); return e
        end)
    end
    msg.info(string.format("RIFE budget -> %.0f Mpx/s (%s)", rate / 1e6, why))
end

local function build_ladder()
    local full  = FULL[st.content][st.class]
    local light = LIGHT[st.class]
    local chroma = { st.class == "down" and KRIG or CFLL }
    -- At scale <= 0.5 the 4:2:0 chroma plane is already at least as large as the output,
    -- so chroma reconstruction adds nothing and costs a lot (Krig at 8K: an 8K60 VR file
    -- needed 6.2 ms on a 165 Hz / 6.1 ms frame). Drop it from every rung.
    if st.scale <= 0.5 then
        local function strip(list)
            local o = {}
            for _, x in ipairs(list) do if x ~= KRIG and x ~= CFL and x ~= CFLL then o[#o + 1] = x end end
            return o
        end
        full = strip(full); chroma = {}
        if light then light = strip(light) end
    end

    -- RIFE targets: the refresh rate divided by 1, 2, 3, 6 (180 -> 180/90/60/30, 165 ->
    -- 165/82.5/55/27.5), so the output cadence divides the display evenly. Only targets at
    -- least 15% above the source fps are worth it. Heaviest first; each step-down falls to
    -- the next lower target, and finally to no RIFE.
    local fps, dfps = st.fps, st.dfps
    local px = st.src_rate / math.max(fps, 1)
    local targets, skipped = {}, nil
    if rife_mode == "off" then
        st.rife_note = " (off)"
    elseif fps <= 0 or dfps <= 0 then
        st.rife_note = " (fps unknown)"
    else
        for _, k in ipairs({ 1, 2, 3, 6 }) do
            local t = dfps / k
            if t >= fps * 1.15 then
                -- "on" skips only the learned budget, never the refresh-rate alignment
                if rife_mode == "on" or px * t <= rife_budget() * 1.15 then
                    targets[#targets + 1] = t
                else
                    skipped = skipped or t
                end
            end
        end
        if #targets > 0 then
            local o = {}
            for i, t in ipairs(targets) do o[i] = string.format("%.0f", t) end
            st.rife_note = " (targets " .. table.concat(o, "/") .. ")"
        elseif skipped then
            -- learned, not fixed: the largest output pixel rate RIFE has held here
            st.rife_note = string.format(" (%.0f Mpx/s for %.0f fps > learned %.0f)",
                px * skipped / 1e6, skipped, rife_budget() / 1e6)
        else
            st.rife_note = string.format(" (%.0f fps: nothing to add on %.0f Hz)", fps, dfps)
        end
    end

    -- 2026-10-30, owner: frame rate first, image quality second. Interpolation rungs carry
    -- only chroma reconstruction (or nothing), so the GPU goes to RIFE instead of the CNN /
    -- sharpen chain; "full" shaders are used only once no interpolation rung holds.
    local L = {}
    for _, t in ipairs(targets) do
        local tag = string.format("rife%.0f", t)
        L[#L + 1] = { name = tag .. "+chroma", shaders = chroma, rife = true, target = t }
        if #chroma > 0 then L[#L + 1] = { name = tag .. "+none", shaders = {}, rife = true, target = t } end
    end
    -- MVTools rungs, same refresh-aligned targets, each as pixel-wise "flow" then the
    -- cheaper "block". Measured 2026-10-07 at 180 Hz (Ryzen 7 7700): 1080p30/60 -> block 180
    -- and flow 90 hold, flow 180 does not; 4K (interpolated at 1440p inside mvfps.vpy) ->
    -- block 90 holds, 180 does not.
    st.mv_note = ""
    if mv_mode == "off" then
        st.mv_note = " (off)"
    elseif fps > 0 and dfps > 0 then
        local n = 0
        for _, k in ipairs({ 1, 2, 3, 6 }) do
            local t = dfps / k
            if t >= fps * 1.15 then
                local tag = string.format("mv%.0f", t)
                L[#L + 1] = { name = tag .. "flow", shaders = chroma, mv = "flow", target = t }
                L[#L + 1] = { name = tag .. "block", shaders = chroma, mv = "block", target = t }
                n = n + 1
            end
        end
        if n == 0 then st.mv_note = string.format(" (%.0f fps: nothing to add on %.0f Hz)", fps, dfps) end
    end
    L[#L + 1] = { name = "full", shaders = full, rife = false }
    if light then L[#L + 1] = { name = "light", shaders = light, rife = false } end
    if #chroma > 0 then L[#L + 1] = { name = "chroma", shaders = chroma, rife = false } end
    L[#L + 1] = { name = "none", shaders = {}, rife = false }
    return L
end

local function vf_has(label)
    for _, f in ipairs(mp.get_property_native("vf") or {}) do
        if f.label == label then return true end
    end
    return false
end
local function rife_active() return vf_has("aerife") end

local function write_target(fname, text)
    local f = io.open(string.format("%s/vs/%s_%d.txt", ROOT, fname,
                                    mp.get_property_number("pid") or 0), "w")
    if f then f:write(text); f:close() end
end

-- resync_seek: a seek event is the only thing that snaps a device player back to mpv's
-- clock. Wait for the new shaders / filters to compile so the resync lands after the hitch.
-- seek -> rearm() only restarts the warm-up; it never calls apply(), so this cannot loop.
local function resync_later()
    if not opts.resync_seek then return end
    local s = st
    if s.resync_timer then s.resync_timer:kill() end
    s.resync_timer = mp.add_timeout(1.5, function()
        if st ~= s or mp.get_property_bool("pause") then return end
        mp.commandv("seek", "0", "relative+exact")
    end)
end

-- quiet: the initial setup of a file (nothing is playing yet, no resync wanted)
local function apply(level, why, quiet)
    st.level = level
    local r = st.ladder[level]
    st.setting = true
    mp.set_property_native("glsl-shaders", r.shaders)
    st.applied = mp.get_property("glsl-shaders")
    st.setting = false
    -- vf is a global option: @aerife survives loadfile and re-initialises for the new
    -- file, so any RIFE rung needs the long warm-up, not only when it is newly added
    local warm = (r.rife or r.mv) and WARM_VF or WARM_SHADER
    -- MVTools filter: present only on mv rungs; re-added when target or mode changes
    local has_mv = vf_has("aemv")
    local mv_key = r.mv and string.format("%.3f %s", r.target, r.mv) or nil
    if has_mv and st.mv_key ~= mv_key then
        mp.command_native({ "vf", "remove", "@aemv" }); warm = WARM_VF; has_mv = false
    end
    if r.mv and not has_mv then
        write_target("mv_target", mv_key)
        mp.command_native({ "vf", "add", MV_VF }); warm = WARM_VF
    end
    st.mv_key = r.mv and mv_key or nil
    local has = rife_active()
    if r.rife and (not has or st.rife_target ~= r.target) then
        -- rife.vpy reads its target fps from a per-process file (mpv cannot pass arguments
        -- to a .vpy); re-adding the filter re-runs the script with the new target
        local f = io.open(string.format("%s/vs/rife_target_%d.txt", ROOT,
                                        mp.get_property_number("pid") or 0), "w")
        if f then f:write(string.format("%.3f", r.target)); f:close() end
        if has then mp.command_native({ "vf", "remove", "@aerife" }) end
        mp.command_native({ "vf", "add", RIFE_VF }); warm = WARM_VF
        st.rife_target = r.target
    elseif not r.rife and has then
        mp.command_native({ "vf", "remove", "@aerife" }); warm = WARM_VF
        st.rife_target = nil
    end
    st.warm_until = mp.get_time() + warm
    st.bad_count, st.win, st.ok_count = 0, nil, 0
    msg.info(string.format("rung %d %s (%s) %s", level, r.name, short(r.shaders), why or ""))
    publish()
    if not quiet then resync_later() end
end

local function start_level()
    local cache = cache_load()
    local exact = cache[st.key]
    local cls = st.class_key and cache[st.class_key]
    st.bad_name = (exact and exact.bad) or (cls and cls.bad) or nil
    local level, reason, _, src = pick_start(st.ladder, exact, cls, skip_n(st.ladder))
    local ce = src == "class" and cls or exact
    st.start_reason = reason
    st.start_key = src == "class" and st.class_key or st.key
    st.held_n = (ce and ce.held_n) or 0
    st.probing, st.probe_level = reason == "probe", (reason == "probe" and level or nil)
    return level
end

local function setup(why, quiet)
    st.ladder = build_ladder()
    apply(start_level(), why, quiet)
end

------------------------------------------------------------------ init per file
local function try_init()
    if not st or st.ready then return end
    local vp = mp.get_property_native("video-params")
    local dw, dh = num("display-width"), num("display-height")
    if not vp or not vp.w or vp.w == 0 or not dw or not dh then return end
    local w, h = vp.dw or vp.w, vp.dh or vp.h
    if vp.rotate == 90 or vp.rotate == 270 then w, h = h, w end
    st.fps  = num("container-fps") or num("estimated-vf-fps") or 0
    st.src_rate = w * h * st.fps
    st.dfps = num("display-fps") or 0
    st.scale = math.min(dw / w, dh / h)
    st.class = st.scale >= 1.6 and "up2" or (st.scale > 1.30 and "up")
               or (st.scale >= 0.95 and "native" or "down")
    st.w, st.h, st.dw, st.dh = w, h, dw, dh
    st.key = exact_key(w, h, st.fps, dw, dh, st.dfps, st.content)
    -- load is read once per file load (spec 1): it is a process scan, not a per-window cost
    st.load = load_state()
    st.class_key = class_key(w, h, st.fps, dw, dh, st.dfps, st.content, st.load)
    st.ready = true
    setup("start", true)
end

-- remember: this rung (and anything heavier) fails for this key. Written under the exact key
-- and the class key (spec 5); a class failure never hides an exact held because pick_start
-- consults the exact key first.
local function remember_failure(r, reason)
    if not r then return end
    local now = os.time()
    for _, k in ipairs({ st.key, st.class_key }) do
        if k then
            merge_write(cache_load, cache_save, k, function(e)
                return note_fail(e, r.name, reason, now)
            end)
        end
    end
    if not st.bad_name or rank_of(r.name) > rank_of(st.bad_name) then st.bad_name = r.name end
end

-- Persist learned successes (spec 2): the heaviest rung that held >= 30 s, and how many
-- consecutive files this key has held it. Written on step-down and at file end.
local function write_progress()
    if not st or not st.ready or not st.held_name then return end
    local now = os.time()
    for _, k in ipairs({ st.key, st.class_key }) do
        if k then
            merge_write(cache_load, cache_save, k, function(e)
                e = e or {}
                if e.held == st.held_name then
                    if not st.held_counted then e.held_n = (e.held_n or 0) + 1 end
                else
                    e.held, e.held_n = st.held_name, 1
                end
                e.t = now
                return e
            end)
        end
    end
    st.held_counted = true
end

local function step_down(reason)
    local r = st.ladder[st.level]
    if st.level >= #st.ladder then return end
    -- a RIFE failure (not a shader one) lowers the learned RIFE budget
    local out_rate = r.rife and (st.src_rate / math.max(st.fps, 1)) * r.target or 0
    -- (the ladder admits targets up to 1.15 x budget, so a failure must land below out_rate / 1.15,
    -- or the same target is tried again on every new source; 2026-10-30)
    local shader_light = r.rife and (st.last_ms or 0) < 0.25 * 1000 / math.max(st.dfps or 0, 1)
    if r.rife and (#r.shaders == 0 or shader_light or reason:match("^playing") or reason:match("^RIFE")) then
        set_rife_budget(math.min(rife_budget(), out_rate * 0.8), "fail " .. reason)
    end
    remember_failure(r, reason)
    -- A held rung that later fails in the same file must not stay held: H is only safe below
    -- the failing rung, so drop it when rank_of(r.name) <= rank_of(st.held_name) (which covers
    -- r.name == st.held_name). Done before write_progress() so the held value is not re-written.
    if st.held_name and rank_of(r.name) <= rank_of(st.held_name) then st.held_name = nil end
    -- A failed probe (spec 4): the rung above held did not hold. Remember it (done above) and
    -- start the clean-play count over so the next files do not probe again immediately.
    if st.probing and st.level == st.probe_level then
        st.probing = false
        merge_write(cache_load, cache_save, st.start_key, function(e)
            e = probe_failed(e); e.t = os.time(); return e
        end)
        st.held_counted = true
    end
    write_progress()
    -- When RIFE itself is the bottleneck (playback below realtime), lighter shaders at the
    -- same target cannot help: skip straight to the next lower target. Measured 2026-10-07,
    -- 1080p24 with rife=on: 180 -> 90 -> 60 -> 30 took 70 s with the +chroma siblings, every
    -- one of which failed the same way.
    local nxt = st.level + 1
    local slow_cut = r.mv and 0.6 or 0.8
    -- 2026-10-30: a RIFE rung whose shader chain is nearly free (CfL-Lite ~0.5 ms against a
    -- 6.9 ms refresh) fails because of RIFE, not the shaders, so its "+none" sibling would
    -- fail the same way and cost another ~11 s of stutter.
    if (r.rife or r.mv) and ((st.last_rate or 1) < slow_cut or shader_light) then
        while st.ladder[nxt] and ((r.rife and st.ladder[nxt].rife) or (r.mv and st.ladder[nxt].mv))
              and st.ladder[nxt].target == r.target do
            nxt = nxt + 1
        end
        nxt = math.min(nxt, #st.ladder)
        -- the skipped siblings failed with it: remember the lowest of them, or the next
        -- playback would start on one of them and fail all over again
        if nxt - 1 > st.level then remember_failure(st.ladder[nxt - 1], reason) end
    end
    -- After a rung that lagged or dropped, mpv spends the next seconds catching up (dropping /
    -- mistiming frames), and the new rung got blamed for it: 2026-10-07 rife30 "failed" at
    -- 25 mistimed/s right after rife60 had played at 66% speed; 2026-10-30 mv144flow was
    -- blamed for the catch-up after rife48 (81-85% speed, above the old 0.8 cut). A zero-length
    -- exact seek resynchronises audio and video at once; playback-restart then re-arms the
    -- warm-up. (with resync_seek, apply() has already scheduled the delayed seek, which covers this)
    local was_slow = (st.last_rate or 1) < 0.97 or (st.last_drop or 0) > 1
    apply(nxt, reason)
    if was_slow and not opts.resync_seek then mp.commandv("seek", "0", "relative+exact") end
    osd("enhance: " .. r.name .. " can't keep up (" .. reason .. ") -> " .. st.ladder[st.level].name)
end

------------------------------------------------------------------ measurement
-- Average GPU time of one freshly rendered frame (sum of libplacebo's "fresh" passes).
local function fresh_ms()
    local p = mp.get_property_native("vo-passes")
    if not p or not p.fresh then return nil end
    local sum = 0
    for _, pass in ipairs(p.fresh) do sum = sum + (pass.avg or 0) end
    return sum / 1e6
end

local function sample()
    if not st or not st.ready or st.manual then return end
    local now = mp.get_time()
    -- st.dirty is set by the observers below whenever the window cannot be trusted
    -- (pause, seek, cache stall, speed change); polling those flags once a second
    -- misses short events.
    if now < (st.warm_until or 0) or st.dirty
       or mp.get_property_bool("pause") or mp.get_property_bool("paused-for-cache")
       or mp.get_property_bool("seeking") or (num("speed") or 1) ~= 1 then
        st.dirty = false
        st.win = nil
        return
    end
    local drop, delay = num("frame-drop-count") or 0, num("vo-delayed-frame-count") or 0
    local mist = num("mistimed-frame-count") or 0
    -- a starving demuxer (stream about to stall) slows playback without being the GPU's fault
    local cdur = num("demuxer-cache-duration")
    if cdur and cdur < 1 and not mp.get_property_bool("eof-reached") then st.win = nil; return end
    local pos = num("time-pos") or 0
    local w = st.win
    -- counters reset when the filter chain reinitialises: start a fresh window
    if not w or drop < w.drop or delay < w.delay or mist < w.mist or pos < w.pos then
        st.win = { t = now, pos = pos, drop = drop, delay = delay, mist = mist }; return
    end
    local dt = now - w.t
    if dt < WINDOW then return end
    local played = pos - w.pos
    st.win = { t = now, pos = pos, drop = drop, delay = delay, mist = mist }

    local r = st.ladder[st.level]
    local per = math.max(dt, 0.1)   -- wall time: a stall must not inflate the rate
    local dr = (drop - w.drop) / per
    local lr = (delay - w.delay) / per
    local vf = num("estimated-vf-fps") or 0
    local rate = played / dt
    st.last_drop, st.last_delay, st.last_vf, st.last_rate = dr, lr, vf, rate

    -- Overload shows up three ways. Measured 2026-10-05: RIFE on 1080p60 did NOT raise
    -- the drop rate much per media-second - playback itself slowed to ~66% of realtime,
    -- which the first version of this script mistook for a cache stall and ignored.
    local out_fps = (r.rife or r.mv) and r.target or st.fps
    -- Frame-time budget. With interpolation / display-resample every refresh is
    -- presented, so a fresh frame that takes longer than ~80% of one refresh makes the
    -- next vsync late even when nothing is counted as dropped. Measured: ArtCNN C4F32 at
    -- 10.9 ms on the 5.55 ms (180 Hz) budget -> vsync jitter 0.37 with 0 drops.
    local ms = fresh_ms()
    local budget = (st.dfps or 0) > 0 and 1000 / st.dfps or nil
    st.last_ms = ms
    local reason
    -- Render time alone is a proxy (agy + DeepSeek review, 2026-10-06): a low-fps source
    -- has several refreshes of slack. Measured anchors: C4F32 10.9 ms on 5.55 ms -> jitter
    -- 0.37; C4F16 4.5 ms -> 0.08-0.12; none -> 0.04. So over 80% of a refresh only counts
    -- when vsync-jitter confirms it (> 0.2), and over 150% counts on its own.
    local jit = num("vsync-jitter") or 0
    local mr = (mist - w.mist) / per
    if ms and budget and #r.shaders > 0 and (ms > budget * 1.5 or (ms > budget * 0.8 and jit > 0.2)) then
        reason = string.format("GPU %.1f ms/frame vs %.1f ms per refresh (%.0f Hz), jitter %.2f",
            ms, budget, st.dfps, jit)
    elseif mr > math.max(1.0, out_fps * 0.01) then reason = string.format("%.1f mistimed/s", mr)
    elseif rate < 0.92 then reason = string.format("playing at %.0f%% speed", rate * 100)
    elseif dr > math.max(1.0, out_fps * 0.01) then reason = string.format("%.1f drops/s", dr)
    elseif lr > 4 then reason = string.format("%.0f delayed/s", lr)
    elseif (r.rife or r.mv) and vf > 0 and vf < out_fps * 0.9 then
        reason = string.format("%s %.0f/%.0ffps", r.rife and "RIFE" or "MV", vf, out_fps)
    end
    msg.debug(string.format("window rung=%s rate=%.2f drop=%.1f delayed=%.1f vf=%.1f ms=%.2f -> %s",
        r.name, rate, dr, lr, vf, ms or -1, reason or "ok"))
    if reason then
        st.bad_count = st.bad_count + 1
        if st.bad_count >= BAD_WINDOWS then step_down(reason) end
    else
        st.bad_count = 0
        st.ok_count = (st.ok_count or 0) + 1
        -- 15 x WINDOW = 30 s clean: this rung holds for this file. Keep the heaviest that did
        -- (we only ever step down, so the first 30 s is the highest rung that held; spec 2).
        if st.ok_count >= 15 and (not st.held_name or rank_of(r.name) > rank_of(st.held_name)) then
            st.held_name = r.name
        end
        local out_rate = r.rife and (st.src_rate / math.max(st.fps, 1)) * r.target or 0
        if r.rife and st.ok_count >= 15 and not st.budget_raised and out_rate > rife_budget() then
            st.budget_raised = true
            set_rife_budget(out_rate, "held 30 s")
        end
    end
    publish()
end

-- A seek restarts decoding (and RIFE's frame queue); the first seconds after it are not
-- representative. Measured 2026-10-06: 50 seeks in 7 s produced "playing at 0% speed"
-- windows and a false RIFE step-down. Every seek therefore re-arms the full warm-up.
local function rearm()
    if not st or not st.ready then return end
    local r = st.ladder and st.ladder[st.level]
    st.warm_until = mp.get_time() + ((r and (r.rife or r.mv)) and WARM_VF or WARM_SHADER)
    st.win, st.bad_count = nil, 0
end
mp.register_event("seek", rearm)
mp.register_event("playback-restart", rearm)
-- Window resize / fullscreen toggle: the render target changes size, every shader pass is
-- re-allocated and frames drop while the user drags the border. Reported 2026-10-14: dragging
-- the window edge stepped the ladder down and the cache remembered it. Each size change pushes
-- the warm-up forward, so measuring resumes only once the size has been stable for WARM_SHADER.
mp.observe_property("osd-dimensions", "native", function(_, d)
    if not st or not st.ready or not d then return end
    local sz = string.format("%dx%d", d.w or 0, d.h or 0)
    if st.osd_size and st.osd_size ~= sz then
        st.warm_until = math.max(st.warm_until or 0, mp.get_time() + WARM_SHADER)
        st.win, st.bad_count, st.dirty = nil, 0, true
    end
    st.osd_size = sz
end)

for _, p in ipairs({ "pause", "paused-for-cache", "seeking", "speed" }) do
    mp.observe_property(p, "native", function() if st then st.dirty = true end end)
end

------------------------------------------------------------------ events
mp.register_event("start-file", function()
    st = { content = session_content, bad_count = 0 }
end)
-- file end / unload: this is when a clean play counts toward held_n (spec 2)
mp.register_event("end-file", function() write_progress() end)
mp.register_event("file-loaded", function() try_init() end)
mp.observe_property("video-params", "native", function() try_init() end)
-- refresh-rate change (165 <-> 180 Hz, monitor replug): budgets and the cache key depend on it
mp.observe_property("display-fps", "number", function(_, v)
    if st and st.ready and v and v > 0 and math.abs(v - (st.dfps or 0)) > 1 then
        msg.info(string.format("display-fps %.0f -> %.0f: re-initialising", st.dfps or 0, v))
        st.ready = false; try_init()
    end
end)
mp.add_periodic_timer(1, sample)

mp.observe_property("glsl-shaders", "string", function(_, v)
    if not st or not st.ready or st.setting or st.manual then return end
    if v ~= st.applied then
        st.manual = true
        msg.info("glsl-shaders changed externally -> manual for this file")
        publish()
    end
end)

------------------------------------------------------------------ key bindings (input.conf)
mp.register_script_message("adaptive-content", function(mode)
    if not st or not st.ready then return end
    st.content = CONTENT[mode] and mode or "auto"
    session_content = st.content
    st.manual = false
    st.key = st.key:gsub("|[^|]*$", "|" .. st.content)
    st.class_key = class_key(st.w, st.h, st.fps, st.dw, st.dh, st.dfps, st.content, st.load)
    setup("content " .. st.content)
    osd("content: " .. st.content .. " -> " .. st.ladder[st.level].name .. " (" .. short(st.ladder[st.level].shaders) .. ")")
end)

mp.register_script_message("adaptive-rife", function()
    rife_mode = ({ auto = "on", on = "off", off = "auto" })[rife_mode]
    if st and st.ready then st.manual = false; setup("rife " .. rife_mode) end
    local r = st and st.ladder and st.ladder[st.level]
    osd("RIFE: " .. rife_mode .. (st and st.rife_note or "") .. (r and ("  -> " .. r.name) or ""))
end)

mp.register_script_message("adaptive-toggle", function()
    if not st or not st.ready then return end
    if st.manual then
        st.manual = false; setup("auto again")
        osd("enhance: AUTO -> " .. st.ladder[st.level].name)
    else
        apply(#st.ladder, "user off"); st.manual = true; publish()
        osd("enhance: OFF (Ctrl+s again for auto)")
    end
end)

mp.register_script_message("adaptive-reset", function()
    if not st or not st.ready then return end
    local cache = cache_load(); cache[st.key] = nil; cache_save(cache)
    st.manual = false; st.bad_name = nil
    setup("cache reset")
    osd("enhance: forgot learned limit for this source -> " .. st.ladder[st.level].name)
end)

mp.register_script_message("adaptive-pin", function(name)
    if not st or not st.ready then return end
    for i, r in ipairs(st.ladder) do
        if r.name == name and i > skip_n(st.ladder) then
            apply(i, "pinned by user"); st.manual = true; publish()
            osd("enhance: pinned " .. name .. " (" .. short(r.shaders) .. ") - auto stepping off")
            return
        end
    end
    osd("enhance: rung " .. tostring(name) .. " not available for this file")
end)

------------------------------------------------------------------ live stats overlay
-- Frame time = sum of libplacebo's "fresh" render passes (vo-passes) against the budget
-- one display refresh allows. That is what decides whether a shader chain fits.
local overlay = mp.create_osd_overlay("ass-events")
local overlay_on = false

local function render_ms()
    local p = mp.get_property_native("vo-passes")
    if not p or not p.fresh then return nil end
    local sum = 0
    for _, pass in ipairs(p.fresh) do sum = sum + (pass.avg or 0) end
    return sum / 1e6
end

local function esc(s) return (tostring(s):gsub("[{}\\]", "")) end

local function draw_overlay()
    if not overlay_on then overlay:remove(); return end
    local r = st and st.ladder and st.ladder[st.level]
    local ms = render_ms()
    local dfps = num("display-fps") or 0
    local budget = dfps > 0 and 1000 / dfps or 0
    local function bar(v, max)
        local n = math.max(0, math.min(20, math.floor(v / max * 20 + 0.5)))
        return string.rep("|", n) .. string.rep(".", 20 - n)
    end
    local lines = {
        string.format("%s%s   content %s   RIFE %s%s",
            r and r.name or "?", (st and st.manual) and " (pinned/manual)" or " (auto)",
            st and st.content or "?", rife_mode, st and st.rife_note or ""),
        "shaders  " .. (r and short(r.shaders) or "?"),
        string.format("source   %sx%s @ %.2f fps -> out %.1f fps on %.0f Hz   scale %.2f (%s)",
            mp.get_property("width") or "?", mp.get_property("height") or "?",
            num("container-fps") or 0, num("estimated-vf-fps") or 0, dfps,
            st and st.scale or 0, st and st.class or "?"),
        ms and string.format("render   %5.2f ms of %5.2f ms budget [%s]%s", ms, budget,
            bar(ms, budget > 0 and budget or 1), (budget > 0 and ms > budget * 0.85) and " !" or "")
            or "render   n/a",
        string.format("window   drop %.1f/s  delayed %.1f/s  speed %.0f%%   totals: drop %d delayed %d mistimed %d",
            st and st.last_drop or 0, st and st.last_delay or 0, (st and st.last_rate or 1) * 100,
            num("frame-drop-count") or 0, num("vo-delayed-frame-count") or 0, num("mistimed-frame-count") or 0),
        string.format("vsync    jitter %.3f   ratio %s   hwdec %s",
            num("vsync-jitter") or 0, mp.get_property("vsync-ratio") or "?", mp.get_property("hwdec-current") or "?"),
        "learned  fails at: " .. (st and st.bad_name or "-") .. "   key " .. (st and st.key or "?"),
    }
    local ys = mp.get_property("user-data/ytdl-adaptive/status")
    if ys and ys ~= "" then lines[#lines + 1] = "stream   " .. ys end
    for i, l in ipairs(lines) do lines[i] = esc(l) end
    overlay.data = "{\\an7\\fs20\\bord2\\fnConsolas}" .. table.concat(lines, "\\N")
    overlay:update()
end
mp.add_periodic_timer(0.5, function() if overlay_on then draw_overlay() end end)

local function toggle_overlay()
    overlay_on = not overlay_on
    draw_overlay()
end
mp.register_script_message("adaptive-overlay", toggle_overlay)

------------------------------------------------------------------ in-player menu (Tab)
local ok_input, input = pcall(require, "mp.input")

local function choose(prompt, items, cb)
    if not ok_input then osd("menu needs mp.input (mpv >= 0.39)"); return end
    local labels = {}
    for i, it in ipairs(items) do labels[i] = it[1] end
    -- The console closes itself right after `submit` returns. Opening the next menu (or
    -- anything that redraws the console) inside the callback gets closed with it, which made
    -- every sub-menu look unselectable (2026-10-07). Defer the action past the close.
    input.select({ prompt = prompt, items = labels,
                   submit = function(i)
                       if items[i] then
                           local v = items[i][2]
                           mp.add_timeout(0.15, function() cb(v) end)
                       end
                   end })
end

local function mark(cur, v, label) return (cur == v and "[x] " or "[ ] ") .. label end

local stream_mode = "quality"
mp.register_script_message("ytdl-mode", function(m) stream_mode = m end)

local function menu()
    local path = mp.get_property("path") or ""
    local is_stream = path:match("^https?://") ~= nil
    local cur_rung = st and st.ladder and st.ladder[st.level] and st.ladder[st.level].name
    local main = {
        { "Video type:  " .. (st and st.content or session_content), "content" },
        { "Enhancement: " .. (cur_rung or "?") .. ((st and st.manual) and " (pinned)" or " (auto)"), "rung" },
        { "Motion interpolation (MVTools, cheap): " .. mv_mode, "mv" },
        { "RIFE frame interpolation (AI, heavy): " .. rife_mode, "rife" },
        is_stream and { "Stream quality: " .. stream_mode, "stream" } or nil,
        { (overlay_on and "Hide" or "Show") .. " live stats overlay", "overlay" },
        { "mpv stats: frame timing graphs (page 2)", "stats" },
        { "Forget learned limit for this source", "reset" },
    }
    local compact = {}
    for i = 1, 8 do if main[i] then compact[#compact + 1] = main[i] end end
    main = compact
    choose("mpv enhancement  (arrows + Enter, or click; Esc closes)", main, function(k)
        if k == "content" then
            local c = st and st.content or session_content
            choose("Video type (kept for the following files)", {
                { mark(c, "auto",   "Auto - chosen from render scale"), "auto" },
                { mark(c, "anime",  "Anime / 3D render - ArtCNN forced"), "anime" },
                { mark(c, "live",   "Real / live action - adaptive-sharpen, no CNN"), "live" },
                { mark(c, "grainy", "Grainy / low bitrate - ArtCNN denoise + sharpen"), "grainy" },
            }, function(v) mp.commandv("script-message", "adaptive-content", v) end)
        elseif k == "rung" then
            if not st or not st.ladder then return end
            local items = { { (st.manual and "[ ] " or "[x] ") .. "Auto - step down when frames drop", "@auto" } }
            for i, r in ipairs(st.ladder) do
                if i > skip_n(st.ladder) then
                    items[#items + 1] = { mark(st.manual and cur_rung, r.name,
                        r.name .. "   " .. short(r.shaders) .. (r.rife and string.format(" + RIFE -> %.0f fps", r.target) or "") .. (r.mv and string.format(" + MV %s -> %.0f fps", r.mv, r.target) or "")), r.name }
                end
            end
            choose("Enhancement level", items, function(v)
                if v == "@auto" then
                    st.manual = false; setup("auto")
                    osd("enhance: AUTO -> " .. st.ladder[st.level].name)
                else
                    mp.commandv("script-message", "adaptive-pin", v)
                end
            end)
        elseif k == "mv" then
            choose("Motion interpolation (MVTools)", {
                { mark(mv_mode, "auto", "Auto - highest refresh-aligned fps that plays smoothly"), "auto" },
                { mark(mv_mode, "off",  "Off"), "off" },
            }, function(v)
                mv_mode = v
                if st and st.ready then st.manual = false; setup("mv " .. v) end
                osd("Motion interpolation: " .. v)
            end)
        elseif k == "rife" then
            choose("RIFE", {
                { mark(rife_mode, "auto", "Auto - x2 when 2 x fps fits the display, dropped if it stutters"), "auto" },
                { mark(rife_mode, "on",   "On - offer x2 even when it does not fit the refresh rate"), "on" },
                { mark(rife_mode, "off",  "Off"), "off" },
            }, function(v)
                rife_mode = v
                if st and st.ready then st.manual = false; setup("rife " .. v) end
                osd("RIFE: " .. v .. (st and st.rife_note or ""))
            end)
        elseif k == "stream" then
            choose("Stream quality", {
                { "Quality - auto resolution up to 4K, follows bandwidth", "quality" },
                { "Motion - <=1080p30 so RIFE x2 can run", "motion" },
            }, function(v) mp.commandv("script-message", "ytdl-mode", v) end)
        elseif k == "overlay" then toggle_overlay()
        elseif k == "stats" then mp.commandv("script-binding", "stats/display-page-2-toggle")
        elseif k == "reset" then mp.commandv("script-message", "adaptive-reset")
        end
    end)
end
mp.register_script_message("adaptive-menu", menu)
mp.add_key_binding("TAB", "adaptive-menu", menu)
mp.add_key_binding("`", "adaptive-overlay", toggle_overlay)
