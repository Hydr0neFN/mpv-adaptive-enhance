-- ytdl-adaptive.lua - pick the YouTube/stream resolution the connection can actually feed.
--
-- 2026-10-05: with other downloads sharing the line, the 4K vp9 stream (17 Mbps)
-- arrived at 568 KiB/s (~4.6 Mbps, 0.23x realtime) and mpv sat in "buffering" every few
-- seconds - it looked like YouTube "not working". A fixed 4K/1080p choice cannot be
-- right when bandwidth changes minute to minute, so:
--
--   * the format is chosen in an on_load hook that runs before ytdl_hook (priority 9 < 10)
--   * start height = the last height that played cleanly in the past 30 min, else 2160
--   * a stall (paused-for-cache) longer than STALL_S, or 2 stalls within 60 s,
--     or the cache draining below LOW_S while the download rate is under the video
--     bitrate -> reload one rung lower at the same position
--   * a full cache for UP_AFTER seconds with no stalls -> try one rung higher;
--     a rung that stalled for this URL is never retried
--
-- Ctrl+1 = quality mode (auto, up to 2160). Ctrl+2 = motion mode (<=1080p, <=30fps,
-- so adaptive-enhance can add RIFE x2). Both reload at the current position.

local mp    = require 'mp'
local utils = require 'mp.utils'
local msg   = require 'mp.msg'

local HEIGHTS  = { 2160, 1440, 1080, 720, 480, 360 }
local STATE    = (os.getenv("APPDATA") or ""):gsub("\\", "/") .. "/mpv/ytdl-adaptive.json"
local REMEMBER = 30 * 60
-- STALL_S > cache-pause-wait (3 s): a single refill at adequate bandwidth is not a reason
local STALL_S, LOW_S, UP_AFTER, UP_GAP = 4.0, 4, 60, 120
-- script-opts: ytdl_adaptive-reload=no disables mid-playback reloads (for an mpv
-- instance driven by another app: a reload blanks time-pos for seconds)
-- ytdl_adaptive-fallback_clients: YouTube player clients tried in turn when the stream
-- fails to open (2026-10-06: for one test video `default` worked and `web_embedded`
-- 403'd, while on 2026-08-29 it was the other way round - which client works changes
-- per video and per yt-dlp release, so no single setting is right)
-- (separate with '+' when set via --script-opts, whose own separator is ',')
local opts = { reload = true, fallback_clients = "web_embedded+tv+mweb" }
require("mp.options").read_options(opts, "ytdl_adaptive")

local mode = "quality"             -- quality | motion  (session-wide)
local per_url = {}                 -- url -> { idx, failed = {idx=true}, last_up }
local cur                          -- state for the playing stream

local function is_stream(p) return p and p:match("^https?://") ~= nil end

local function load_state()
    local f = io.open(STATE, "r"); if not f then return {} end
    local t = utils.parse_json(f:read("*a") or "") or {}; f:close(); return t
end
local last_saved
local function save_state(t)
    if last_saved and last_saved.h == t.h and t.t - last_saved.t < 300 then return end
    -- write-then-rename, so another player never reads a half-written file
    local tmp = STATE .. ".tmp" .. tostring(mp.get_property_number("pid") or 0)
    local f = io.open(tmp, "w")
    if not f then return end
    f:write(utils.format_json(t)); f:close()
    os.remove(STATE); os.rename(tmp, STATE)
    last_saved = t
end

local function fmt(h)
    local fps = mode == "motion" and "[fps<=?30]" or ""
    return string.format(
        "bestvideo[height<=?%d]%s[vcodec^=vp9]+bestaudio/bestvideo[height<=?%d]%s+bestaudio/best[height<=?%d]/best",
        h, fps, h, fps, h)
end

local function top_idx() return mode == "motion" and 3 or 1 end

local function start_idx()
    local s = load_state()
    local idx = top_idx()
    if s.h and s.t and os.time() - s.t < REMEMBER then
        for i, h in ipairs(HEIGHTS) do if h == s.h then idx = math.max(i, top_idx()) end end
    end
    return idx
end

mp.add_hook("on_load", 9, function()
    local path = mp.get_property("path")
    if not is_stream(path) then cur = nil; return end
    local u = per_url[path]
    if not u then u = { idx = start_idx(), failed = {} }; per_url[path] = u end
    cur = { url = path, u = u, stalls = {}, full_since = nil, stall_start = nil, started = false }
    mp.set_property("file-local-options/ytdl-format", fmt(HEIGHTS[u.idx]))
    if u.client then
        mp.set_property("file-local-options/ytdl-raw-options",
            "extractor-args=youtube:player_client=" .. u.client)
    end
    msg.info("ytdl-adaptive: " .. mode .. " -> <=" .. HEIGHTS[u.idx] .. "p" ..
             (u.client and (" via player_client=" .. u.client) or ""))
end)

-- Stream failed to open (typically HTTP 403 on the format URLs): queue the same URL again
-- right after this entry with the next player client. Inserting keeps the playlist
-- non-empty, so mpv moves on to the retry instead of quitting.
mp.add_hook("on_load_fail", 50, function()
    local path = mp.get_property("path")
    local u = path and per_url[path]
    if not u then return end
    u.tried = (u.tried or 0) + 1
    local list = {}
    for c in opts.fallback_clients:gmatch("[^,+%s]+") do list[#list + 1] = c end
    local nxt = list[u.tried]
    if not nxt then
        mp.osd_message("stream failed with every YouTube client - try updating yt-dlp", 5)
        return
    end
    u.client = nxt
    msg.warn("stream failed to open; retrying with player_client=" .. nxt)
    mp.osd_message("stream failed - retrying (player_client=" .. nxt .. ")", 3)
    mp.commandv("loadfile", path, "insert-next")
end)

local pending_remove   -- playlist index of the entry a reload replaced

local function publish()
    if not cur then return end
    mp.set_property_native("user-data/ytdl-adaptive/status", string.format(
        "<=%dp  mode %s  stalls %d  cache %.0fs  dl %.1f Mbps",
        HEIGHTS[cur.u.idx], mode, #cur.stalls,
        mp.get_property_number("demuxer-cache-duration") or 0,
        (mp.get_property_number("cache-speed") or 0) * 8 / 1e6))
end

local function reload(new_idx, why)
    local u = cur.u
    u.idx = new_idx
    if not opts.reload then
        msg.info("ytdl-adaptive: reload disabled, next load uses " .. HEIGHTS[new_idx]); return
    end
    local pos = mp.get_property_number("time-pos") or 0
    local paused = mp.get_property_bool("pause")
    mp.osd_message(string.format("stream: %s -> %dp", why, HEIGHTS[new_idx]), 3)
    msg.info("ytdl-adaptive reload: " .. why .. " -> " .. HEIGHTS[new_idx])
    -- insert the reloaded copy right after the current entry and drop the old one once
    -- the copy is loaded, so the rest of the playlist survives (replace would clear it)
    -- (insert-next-play only starts it when nothing is playing, hence the explicit jump)
    local here = mp.get_property_number("playlist-pos") or 0
    pending_remove = here
    mp.command_native({ name = "loadfile", url = cur.url, flags = "insert-next",
                        options = { start = string.format("%.2f", pos), pause = paused and "yes" or "no" } })
    mp.commandv("playlist-play-index", tostring(here + 1))
end

mp.register_event("file-loaded", function()
    if pending_remove then
        local i = pending_remove; pending_remove = nil
        if i ~= mp.get_property_number("playlist-pos") then mp.commandv("playlist-remove", tostring(i)) end
    end
end)

-- only quality mode says anything about bandwidth; motion mode caps resolution on purpose
local function remember_ok()
    if cur and mode == "quality" then save_state({ h = HEIGHTS[cur.u.idx], t = os.time() }) end
end

local function step_down(why)
    local u = cur.u
    u.failed[u.idx] = true
    if u.idx < #HEIGHTS then
        if mode == "quality" then save_state({ h = HEIGHTS[u.idx + 1], t = os.time() }) end
        reload(u.idx + 1, why)
    end
end

mp.observe_property("paused-for-cache", "bool", function(_, v)
    if not cur or not cur.started then return end
    local now = mp.get_time()
    if v then
        cur.stall_start = now
        cur.full_since = nil
    elseif cur.stall_start then
        local len = now - cur.stall_start
        cur.stall_start = nil
        cur.stalls[#cur.stalls + 1] = now
        if #cur.stalls >= 2 and now - cur.stalls[#cur.stalls - 1] < 60 then
            step_down("2 stalls in 60s")
        elseif len > STALL_S then
            step_down(string.format("stalled %.1fs", len))
        end
    end
end)

mp.register_event("playback-restart", function()
    if cur and not cur.started then
        -- ignore the initial fill; start judging once playback is running
        mp.add_timeout(3, function() if cur then cur.started = true end end)
    end
end)

mp.add_periodic_timer(2, function()
    if not cur or not cur.started or mp.get_property_bool("pause") then return end
    local now = mp.get_time()
    -- a stall in progress that is already long: don't wait for it to end
    if cur.stall_start and now - cur.stall_start > STALL_S * 2 then
        cur.stall_start = nil; step_down("stalled"); return
    end
    local dur   = mp.get_property_number("demuxer-cache-duration") or 0
    local speed = (mp.get_property_number("cache-speed") or 0) * 8     -- bit/s
    local vbr   = (mp.get_property_number("video-bitrate") or 0) + (mp.get_property_number("audio-bitrate") or 0)
    local ahead = mp.get_property_number("demuxer-readahead-secs") or 20
    local idle  = mp.get_property_bool("demuxer-cache-idle")

    if dur < LOW_S and not idle and vbr > 0 and speed > 0 and speed < vbr * 0.9 then
        step_down(string.format("%.1f/%.1f Mbps", speed / 1e6, vbr / 1e6)); return
    end

    publish()
    if dur >= ahead * 0.9 or (idle and dur >= LOW_S) then
        cur.full_since = cur.full_since or now
        remember_ok()
        local u = cur.u
        local up = u.idx - 1
        if up >= top_idx() and not u.failed[up] and now - cur.full_since > UP_AFTER
           and (not u.last_up or now - u.last_up > UP_GAP) then
            u.last_up = now
            reload(up, "bandwidth headroom")
        end
    else
        cur.full_since = nil
    end
end)

local function set_mode(m)
    mode = m
    if cur then
        cur.u.idx = start_idx(); cur.u.failed = {}
        if mode == "quality" then cur.u.idx = top_idx() end
        reload(cur.u.idx, m == "motion" and "motion mode (<=1080p30, RIFE-able)" or "quality mode (auto up to 4K)")
    else
        mp.osd_message("stream mode: " .. m, 2)
    end
end
mp.register_script_message("ytdl-mode", set_mode)
