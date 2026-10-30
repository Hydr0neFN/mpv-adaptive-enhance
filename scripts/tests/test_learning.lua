-- Pure-logic tests for adaptive-enhance.lua. Runs inside mpv with no config and no playback:
--   mpv --no-config --idle=once --script=<path>/tests/test_learning.lua
-- mpv gives every script its own Lua state, so we loadfile() the main script with the
-- ADAPTIVE_PURE sentinel set and get its pure functions back instead of its mpv hooks.
-- Nothing here touches the real adaptive-cache.json or E:\Movies\_av1.

-- this file's own directory, so the test works wherever the repo is checked out
local src = debug.getinfo(1, "S").source:gsub("^@", "")
local dir = src:match("^(.*)[/\\][^/\\]*$") or "."
_G.ADAPTIVE_PURE = true
local M = assert(loadfile(dir .. "/../adaptive-enhance.lua"))()
_G.ADAPTIVE_PURE = nil

local n, pass, fails = 0, 0, {}
local function eq(got, want, label)
    n = n + 1
    if got == want then pass = pass + 1
    else fails[#fails + 1] = string.format("%s: got %s want %s", label, tostring(got), tostring(want)) end
end
local function ok(cond, label)
    n = n + 1
    if cond then pass = pass + 1 else fails[#fails + 1] = label end
end
-- rungs are ordered heaviest first, like the real ladder
local function ladder(...)
    local L = {}
    for _, nm in ipairs({ ... }) do L[#L + 1] = { name = nm } end
    return L
end

------------------------------------------------------------------ res buckets
eq(M.res_bucket(1920, 1080), M.res_bucket(1920, 1088), "1088 coded height keeps the 1080 bucket")
eq(M.res_bucket(1080, 1080), "1080", "long edge 1080 -> 1080")
eq(M.res_bucket(1088, 1088), "1440", "long edge 1088 -> 1440 (just over the edge)")
eq(M.res_bucket(1080, 1920), "2160", "portrait 1080x1920 uses its long edge")
eq(M.res_bucket(3840, 2160), "4096", "4K flat 3840x2160")
eq(M.res_bucket(3840, 1920), "vr4096", "VR 2:1 at 3840 is its own bucket")
eq(M.res_bucket(7680, 3840), "vr4096+", "VR 2:1 at 7680")

------------------------------------------------------------------ fps buckets
eq(M.fps_bucket(24), "25", "24 fps")
eq(M.fps_bucket(25), "25", "25 fps")
eq(M.fps_bucket(29.97), "31", "29.97 fps shares the 31 bucket")
eq(M.fps_bucket(30), "31", "30 fps")
eq(M.fps_bucket(31), "31", "31 fps")
eq(M.fps_bucket(32), "50", "32 fps -> 50")
eq(M.fps_bucket(130), "121+", "130 fps -> 121+")

------------------------------------------------------------------ load state (injected)
eq(M.load_state({ paused = true, pid_files = { "driver_1.pid" } }), "idle", "PAUSE_PC present -> idle")
eq(M.load_state({ paused = false, pid_files = {} }), "idle", "no driver pid -> idle")
eq(M.load_state({ paused = false, pid_files = { "driver_7.pid" },
                  pid_of = function() return 4242 end,
                  alive = function(p) return p == 4242 end }), "busy", "live driver pid -> busy")
eq(M.load_state({ paused = false, pid_files = { "driver_7.pid" },
                  pid_of = function() return 4242 end,
                  alive = function() return false end }), "idle", "dead driver pid -> idle")
eq(M.load_state({ dir = "Z:/no/such/dir", paused = false }), "idle", "missing path -> idle")
-- the injected alive() decides, regardless of dir / pid_of (a missing dir must not force busy)
eq(M.load_state({ dir = "nowhere", paused = false, pid_files = { "driver_1.pid" },
                  pid_of = function() return 1234 end,
                  alive = function() return false end }), "idle", "injected dead pid -> idle")
eq(M.load_state({ dir = "nowhere", paused = false, pid_files = { "driver_1.pid" },
                  pid_of = function() return 1234 end,
                  alive = function() return true end }), "busy", "injected live pid -> busy")

------------------------------------------------------------------ keys
eq(M.exact_key(1920, 1080, 30, 2560, 1440, 180, "auto"),
   "v2|1920x1080@30>2560x1440@180|auto", "exact key shape")
eq(M.class_key(1920, 1080, 30, 2560, 1440, 180, "auto", "idle"),
   "c1|2160|31|2560x1440@180|auto|idle", "class key shape")

------------------------------------------------------------------ start rung selection
local L = ladder("full", "light", "chroma", "none")

-- exact-key held beats class-key bad (spec 5)
local lv, reason, held = M.pick_start(L, { held = "light", held_n = 1 }, { bad = "full" }, 0)
eq(L[lv].name, "light", "exact held beats class bad")
eq(reason, "exact held", "start reason exact held")

-- class held gives the start rung for a new exact size (spec 3)
lv, reason = M.pick_start(L, nil, { held = "chroma", held_n = 1 }, 0)
eq(L[lv].name, "chroma", "class held starts a new size")
eq(reason, "class held", "start reason class held")

-- only bad known: highest rung ranked below the failure (today's rule)
lv, reason = M.pick_start(L, { bad = "light" }, nil, 0)
eq(L[lv].name, "chroma", "bad-only starts below the failure")
eq(reason, "bad-only", "start reason bad-only")

-- no knowledge at all
lv, reason = M.pick_start(L, nil, nil, 0)
eq(L[lv].name, "full", "no knowledge starts at the top")
eq(reason, "none", "start reason none")

-- probe after 3 clean plays, not after 2 (spec 4)
lv, reason = M.pick_start(L, { held = "light", held_n = 2 }, nil, 0)
eq(L[lv].name, "light", "held_n 2 does not probe")
eq(reason, "exact held", "held_n 2 keeps the held rung")
lv, reason = M.pick_start(L, { held = "light", held_n = 3 }, nil, 0)
eq(L[lv].name, "full", "held_n 3 probes one rung up")
eq(reason, "probe", "held_n 3 start reason probe")

-- never probe into a rung already known bad
lv, reason = M.pick_start(L, { held = "light", held_n = 5, bad = "full" }, nil, 0)
eq(L[lv].name, "light", "no probe into a known-bad rung")
eq(reason, "exact held", "known-bad rung keeps held")

-- spread: failures are written under both keys, class first is not needed for selection
local exact = { held = "light", held_n = 3 }
M.note_fail(exact, "full", "GPU 12.0 ms vs 5.6 ms per refresh")
eq(exact.bad, "full", "failure recorded")
eq(exact.held, "light", "failure keeps the held rung")

-- a failed probe records bad and resets held_n (spec 4)
M.probe_failed(exact)
eq(exact.held_n, 0, "failed probe resets held_n")
eq(exact.bad, "full", "failed probe keeps the recorded bad")

-- a held rung that later fails in the same file must not stay held (spec 5)
local held_same = { held = "light", held_n = 2 }
held_same = M.note_fail(held_same, "light", "GPU 12.0 ms vs 5.6 ms per refresh", 1)
eq(held_same.held, nil, "same-rung failure clears held")
eq(held_same.held_n, 0, "same-rung failure resets held_n")
lv, reason, held = M.pick_start(L, held_same, nil, 0)
eq(L[lv].name, "chroma", "cleared held starts below the failure")
eq(reason, "bad-only", "cleared held -> bad-only")
eq(held, nil, "cleared held reports no held rung")

-- a class failure must not clear an exact-key held rung (cross-key rule)
local ex_held = { held = "light", held_n = 1 }
local cls = {}
M.note_fail(cls, "light", "class fail", 1)
eq(ex_held.held, "light", "class failure keeps the exact held")
eq(cls.held, nil, "class entry got only the bad")
lv, reason = M.pick_start(L, ex_held, cls, 0)
eq(L[lv].name, "light", "exact held survives a class failure")
eq(reason, "exact held", "exact held reason after class failure")

-- a held rung not strictly lighter than the learned bad is not used as the start
local ex_bad = { bad = "chroma", held = "light" }
lv, reason = M.pick_start(L, ex_bad, nil, 0)
eq(reason, "bad-only", "held not below the bad -> bad-only")
eq(L[lv].name, "none", "bad-only starts below the failure")

------------------------------------------------------------------ expiry (spec 7)
local now = os.time()
ok(M.expired({ t = now - 15 * 86400 }, now), "15-day entry expires")
ok(not M.expired({ t = now - 13 * 86400 }, now), "13-day entry stays")
ok(M.expired(nil, now), "missing entry is dead")

------------------------------------------------------------------ merge-on-write (concurrency)
-- A stale write must not clobber a key another player wrote in between: merge_write re-reads
-- right before writing.
local store = { other = { bad = "full" } }
local function read() local t = {}; for k, v in pairs(store) do t[k] = v end; return t end
local function write(c) store = c end
M.merge_write(read, write, "mine", { held = "light" })
ok(store.other ~= nil, "concurrently written key kept")
ok(store.mine ~= nil and store.mine.held == "light", "our key written")
M.merge_write(read, write, "mine", function(e) e.held_n = (e.held_n or 0) + 1; return e end)
eq(store.mine.held_n, 1, "merge_write accepts an updater")

------------------------------------------------------------------
-- io.stdout, not print: mpv routes print() through its log, which --msg-level=all=warn hides,
-- and the check greps the raw log for a line that starts with PASS/FAIL.
local function say(s) io.stdout:write(s .. "\n"); io.stdout:flush() end
if #fails == 0 then
    say(string.format("PASS %d/%d", pass, n))
else
    for _, f in ipairs(fails) do say("FAIL " .. f) end
    say(string.format("FAIL %d/%d", pass, n))
end
-- defer the quit: an immediate quit at script-load time can race mpv's own start-up and be lost
-- (the script then never exits). By the first timer tick mpv is idle and the quit sticks.
mp.add_timeout(0.2, function() mp.command("quit") end)
