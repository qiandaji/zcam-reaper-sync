-- zcam_record_sync.lua  (v9)
-- Reaper recording <-> ZCam E2 recording sync (multi-camera) + status window.
--
-- How to use:
--   1. In Reaper: Actions > Show action list > New action... > Load ReaScript... > pick this file.
--   2. Run it. A dialog asks for the camera IP(s) (comma-separated, last used prefilled).
--   3. It stays in the background. Close the small "ZCam E2" status window
--      (or press Esc in it) to stop the script.
--
-- Behavior:
--   - Reaper starts recording  -> every ZCam starts recording
--   - Reaper stops recording   -> every ZCam stops recording
--   - Reaper pauses while recording -> ZCams keep rolling (record bit stays set)
--   - A small floating window shows one line per camera: status + IP + remaining
--     recordable time (HH:MM, polled via /ctrl/rec?action=remain).

local SHOW_STATUS_WINDOW = true        -- false = only sync recording, no status window

-- Camera IPs are asked on every start (last-used list is prefilled and saved).
local EXT_SECTION = "zcam_record_sync"
local EXT_KEY_IPS = "camera_ips"
local EXT_KEY_IP = "camera_ip"

local function ask_ips()
  local last = reaper.GetExtState(EXT_SECTION, EXT_KEY_IPS)
  if last == "" then last = reaper.GetExtState(EXT_SECTION, EXT_KEY_IP) end
  if last == "" then last = "192.168.1.100" end
  local ok, val = reaper.GetUserInputs("ZCam E2", 1,
    "相机IP，多台用逗号分隔,extrawidth=220", last, 256)
  if not ok then return nil end
  val = (val or ""):match("^%s*(.-)%s*$")
  if val == "" then val = last end
  local ips, seen = {}, {}
  for ip in val:gmatch("[^,，;；%s]+") do
    if ip:match("^%d+%.%d+%.%d+%.%d+$") and not seen[ip] then
      seen[ip] = true
      ips[#ips + 1] = ip
    end
  end
  if #ips == 0 then return nil end
  reaper.SetExtState(EXT_SECTION, EXT_KEY_IPS, table.concat(ips, ","), true)
  reaper.SetExtState(EXT_SECTION, EXT_KEY_IP, ips[1], true)
  return ips
end

local IPS = ask_ips()
if not IPS then
  reaper.ShowConsoleMsg("ZCam sync: 未输入有效 IP，脚本未启动\n")
  return
end

local function is_windows()
  local os_name = reaper.GetOS() or ""
  return os_name:match("Win") ~= nil
end

local function curl_exe()
  return is_windows() and "curl.exe" or "/usr/bin/curl"
end

-- Fire-and-forget command (used for start/stop/quit).
local function zcam_send(cam, path)
  local cmd = curl_exe() .. ' -s --noproxy "*" --max-time 5 "' .. cam.base .. path .. '"'
  -- timeoutmsec -1 = no wait. (0 would wait forever)
  reaper.ExecProcess(cmd, -1)
end

-- Blocking query that captures output (used for status polling).
local function zcam_query(cam, path)
  local cmd = curl_exe() .. ' -s --noproxy "*" --connect-timeout 0.4 --max-time 1.2 "' .. cam.base .. path .. '"'
  local retval = reaper.ExecProcess(cmd, 1500)
  return retval or ""
end

-- Blocking session occupy. Control of /ctrl/* is exclusive per camera: only
-- one client can own each camera's session at a time.
local function zcam_occupy(cam)
  cam.last_occupy_raw = zcam_query(cam, "/ctrl/session?action=occupy")
end

local function zcam_rec(cam, action) -- "start" | "stop"
  zcam_occupy(cam)   -- re-assert session ownership before every rec command
  zcam_send(cam, "/ctrl/rec?action=" .. action)
end

-- Returns the camera working mode string, e.g. "rec", "rec_ing", "rec_paused",
-- "pb", or nil when the camera is unreachable.
local function zcam_mode(cam)
  local out = zcam_query(cam, "/ctrl/mode?action=query")
  cam.last_raw = out
  local mode = out:match('"msg"%s*:%s*"([^"]*)"')
  if not mode then
    -- Another client may have taken the session. Re-occupy and retry once,
    -- at most every 10 seconds per camera.
    local now = reaper.time_precise()
    if now - cam.last_reoccupy > 10 then
      cam.last_reoccupy = now
      zcam_occupy(cam)
      out = zcam_query(cam, "/ctrl/mode?action=query")
      cam.last_raw = out
      mode = out:match('"msg"%s*:%s*"([^"]*)"')
    end
  end
  return mode
end

-- Remaining recordable time in minutes (number) or nil.
local function zcam_remain(cam)
  local out = zcam_query(cam, "/ctrl/rec?action=remain")
  if not out then return nil end
  local n = out:match('"msg"%s*:%s*"?(%-?%d+%.?%d*)"?') or out:match('"remain"%s*:%s*"?(%-?%d+%.?%d*)"?')
  return n and tonumber(n) or nil
end

-- Formats minutes as HH:MM (e.g. 83 -> "01:23"). nil -> "--:--".
local function fmt_hhmm(minutes)
  if not minutes then return "--:--" end
  local total = math.floor(minutes + 0.5)
  local h = math.floor(total / 60)
  local m = total % 60
  return string.format("%02d:%02d", h, m)
end

local CAMS = {}
for _, ip in ipairs(IPS) do
  CAMS[#CAMS + 1] = {
    ip = ip,
    base = "http://" .. ip,
    last_mode = nil,
    last_raw = "",
    last_occupy_raw = "",
    last_reoccupy = 0,
    last_poll = 0,
    last_remain = nil,
    last_remain_poll = 0,
  }
end

local function status_style(cam)
  -- returns color r,g,b and short label
  local mode = cam.last_mode
  if not mode then
    if cam.last_raw:find("409", 1, true) then
      return 1.0, 0.45, 0.20, "BUSY"
    elseif cam.last_raw:match("%S") == nil then
      return 0.45, 0.45, 0.45, "NO RESP"
    else
      return 0.45, 0.45, 0.45, "ERR"
    end
  elseif mode == "rec_ing" then
    return 1.0, 0.16, 0.16, "REC"
  elseif mode == "rec_paused" then
    return 1.0, 0.75, 0.20, "REC PAUSED"
  elseif mode == "rec" then
    return 0.25, 0.85, 0.45, "STANDBY"
  elseif mode:match("^pb") then
    return 0.35, 0.55, 1.0, "PLAYBACK"
  else
    return 0.55, 0.55, 0.55, mode:upper():sub(1, 10)
  end
end

local was_recording = false
local FONT = is_windows() and "Arial" or "Helvetica"

-- Poll at most one camera per defer tick (round-robin), so a slow/unreachable
-- camera cannot freeze the whole loop for all cameras.
local poll_cursor = 0

local function poll_one(now)
  if #CAMS == 0 then return end
  local cam = CAMS[(poll_cursor % #CAMS) + 1]
  poll_cursor = poll_cursor + 1
  local interval = cam.last_mode and 0.7 or 4.0   -- slower when camera offline
  if now - cam.last_poll >= interval then
    cam.last_poll = now
    cam.last_mode = zcam_mode(cam)
    if now - cam.last_remain_poll >= 5 then
      cam.last_remain_poll = now
      cam.last_remain = zcam_remain(cam)
    end
  end
end

local ROW_H = 24

local function draw_status()
  local c = gfx.getchar()
  if c == -1 or c == 27 then
    -- window closed by user, or Esc pressed -> stop the whole script
    gfx.quit()
    return false
  end

  local now = reaper.time_precise()
  poll_one(now)

  gfx.set(0.08, 0.08, 0.09, 1)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)

  local y = 6
  for _, cam in ipairs(CAMS) do
    local r, g, b, label = status_style(cam)

    gfx.set(r, g, b, 1)
    gfx.circle(16, y + 7, 6, 1)

    gfx.set(1, 1, 1, 1)
    gfx.setfont(1, FONT, 14, 'b')
    gfx.x = 28
    gfx.y = y
    gfx.drawstr(label)

    gfx.set(0.62, 0.62, 0.65, 1)
    gfx.setfont(1, FONT, 12)
    gfx.x = 126
    gfx.y = y + 1
    gfx.drawstr(cam.ip)

    gfx.set(0.75, 0.75, 0.78, 1)
    gfx.setfont(1, FONT, 12)
    gfx.x = 236
    gfx.y = y + 1
    gfx.drawstr("剩" .. fmt_hhmm(cam.last_remain))

    y = y + ROW_H
  end

  gfx.update()
  return true
end

local function tick()
  local recording = (reaper.GetPlayState() & 4) == 4
  if recording ~= was_recording then
    for _, cam in ipairs(CAMS) do
      if recording then zcam_rec(cam, "start") else zcam_rec(cam, "stop") end
    end
    was_recording = recording
  end

  if SHOW_STATUS_WINDOW and not draw_status() then
    return -- window closed: end script (atexit releases the camera sessions)
  end

  reaper.defer(tick)
end

-- Take ownership of every camera's control session (blocking, so it is done
-- before we start monitoring), and release them all on script exit.
for _, cam in ipairs(CAMS) do zcam_occupy(cam) end
reaper.atexit(function()
  for _, cam in ipairs(CAMS) do zcam_send(cam, "/ctrl/session?action=quit") end
end)

if SHOW_STATUS_WINDOW then
  gfx.init("ZCam E2", 320, 14 + #CAMS * ROW_H, 0, 100, 100)
end

tick()
