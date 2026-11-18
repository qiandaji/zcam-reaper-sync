-- zcam_record_sync.lua  (v8)
-- Reaper recording <-> ZCam E2 recording sync + ZCam status window.
--
-- How to use:
--   1. In Reaper: Actions > Show action list > New action... > Load ReaScript... > pick this file.
--   2. Run it. A dialog asks for the camera IP (last-used IP is prefilled).
--   3. It stays in the background. Close the small "ZCam E2" status window
--      (or press Esc in it) to stop the script.
--
-- Behavior:
--   - Reaper starts recording  -> ZCam starts recording
--   - Reaper stops recording   -> ZCam stops recording
--   - Reaper pauses while recording -> ZCam keeps rolling (record bit stays set)
--   - A small floating window shows the ZCam recording state (polled via /ctrl/mode)
--     and the remaining recordable time in HH:MM (polled via /ctrl/rec?action=remain).

local SHOW_STATUS_WINDOW = true        -- false = only sync recording, no status window

-- The camera IP is asked on every start (last-used IP is prefilled and saved).
local EXT_SECTION = "zcam_record_sync"
local EXT_KEY_IP = "camera_ip"

local function ask_ip()
  local last = reaper.GetExtState(EXT_SECTION, EXT_KEY_IP)
  if last == "" then last = "192.168.1.100" end
  local ok, val = reaper.GetUserInputs("ZCam E2", 1,
    "相机IP,extrawidth=120", last, 64)
  if not ok then return nil end
  val = (val or ""):match("^%s*(.-)%s*$")
  if val == "" then val = last end
  reaper.SetExtState(EXT_SECTION, EXT_KEY_IP, val, true)  -- remember for next time
  return val
end

local ZCAM_IP = ask_ip()
if not ZCAM_IP then
  reaper.ShowConsoleMsg("ZCam sync: 未输入 IP，脚本未启动\n")
  return
end

local BASE = "http://" .. ZCAM_IP

local function is_windows()
  local os_name = reaper.GetOS() or ""
  return os_name:match("Win") ~= nil
end

local function curl_exe()
  return is_windows() and "curl.exe" or "/usr/bin/curl"
end

-- Fire-and-forget command (used for start/stop/occupy/quit).
local function zcam_send(path)
  local cmd = curl_exe() .. ' -s --noproxy "*" --max-time 5 "' .. BASE .. path .. '"'
  -- timeoutmsec -1 = no wait. (0 would wait forever)
  reaper.ExecProcess(cmd, -1)
end

-- Blocking query that captures output (used for status polling).
local function zcam_query(path)
  local cmd = curl_exe() .. ' -s --noproxy "*" --connect-timeout 0.4 --max-time 1.2 "' .. BASE .. path .. '"'
  local retval = reaper.ExecProcess(cmd, 1500)
  return retval or ""
end

-- Blocking session occupy. Control of /ctrl/* is exclusive: only one
-- client can own the session at a time.
local last_occupy_raw = ""

local function zcam_occupy()
  last_occupy_raw = zcam_query("/ctrl/session?action=occupy")
end

local function zcam_rec(action) -- "start" | "stop"
  zcam_occupy()   -- re-assert session ownership before every rec command
  zcam_send("/ctrl/rec?action=" .. action)
end

-- Returns the camera working mode string, e.g. "rec", "rec_ing", "rec_paused",
-- "pb", or nil when the camera is unreachable.
local last_reoccupy = 0
local last_raw = ""

local function zcam_mode()
  local out = zcam_query("/ctrl/mode?action=query")
  last_raw = out
  local mode = out:match('"msg"%s*:%s*"([^"]*)"')
  if not mode then
    -- Another client may have taken the session. Re-occupy and retry once,
    -- at most every 10 seconds.
    local now = reaper.time_precise()
    if now - last_reoccupy > 10 then
      last_reoccupy = now
      zcam_occupy()
      out = zcam_query("/ctrl/mode?action=query")
      last_raw = out
      mode = out:match('"msg"%s*:%s*"([^"]*)"')
    end
  end
  return mode
end

-- Remaining recordable time in minutes (number) or nil.
local function zcam_remain()
  local out = zcam_query("/ctrl/rec?action=remain")
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

local function status_style(mode)
  -- returns color r,g,b and label
  if not mode then
    if last_raw:find("409", 1, true) then
      return 1.0, 0.45, 0.20, "BUSY 会话被占用"
    elseif last_raw:match("%S") == nil then
      return 0.45, 0.45, 0.45, "NO RESP curl失败"
    else
      return 0.45, 0.45, 0.45, "ERR " .. last_raw:gsub("%s+", " "):sub(1, 12)
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
    return 0.55, 0.55, 0.55, mode:upper()
  end
end

local was_recording = false
local last_mode = nil
local last_poll = 0
local last_remain = nil
local last_remain_poll = 0
local FONT = is_windows() and "Arial" or "Helvetica"

local function draw_status()
  local c = gfx.getchar()
  if c == -1 or c == 27 then
    -- window closed by user, or Esc pressed -> stop the whole script
    gfx.quit()
    return false
  end

  local now = reaper.time_precise()
  local interval = last_mode and 0.7 or 4.0   -- slower when camera offline
  if now - last_poll >= interval then
    last_poll = now
    last_mode = zcam_mode()
  end
  if now - last_remain_poll >= 5 then
    last_remain_poll = now
    last_remain = zcam_remain()
  end

  local r, g, b, label = status_style(last_mode)

  gfx.set(0.08, 0.08, 0.09, 1)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)

  gfx.set(r, g, b, 1)
  gfx.circle(20, 18, 9, 1)

  gfx.set(1, 1, 1, 1)
  gfx.setfont(1, FONT, 20, 'b')
  gfx.x = 40
  gfx.y = 6
  gfx.drawstr(label)

  gfx.set(0.55, 0.55, 0.55, 1)
  gfx.setfont(1, FONT, 11)
  gfx.x = 40
  gfx.y = 32
  gfx.drawstr(ZCAM_IP)

  gfx.set(0.75, 0.75, 0.78, 1)
  gfx.setfont(1, FONT, 13)
  gfx.x = 40
  gfx.y = 50
  gfx.drawstr("剩余可录 " .. fmt_hhmm(last_remain))

  gfx.update()
  return true
end

local function tick()
  local recording = (reaper.GetPlayState() & 4) == 4
  if recording ~= was_recording then
    if recording then
      zcam_rec("start")
    else
      zcam_rec("stop")
    end
    was_recording = recording
  end

  if SHOW_STATUS_WINDOW and not draw_status() then
    return -- window closed: end script (atexit releases the camera session)
  end

  reaper.defer(tick)
end

-- Take ownership of the camera control session (blocking, so it is done before
-- we start monitoring), and release it on script exit.
zcam_occupy()
reaper.atexit(function()
  zcam_send("/ctrl/session?action=quit")
end)

if SHOW_STATUS_WINDOW then
  gfx.init("ZCam E2", 240, 72, 0, 100, 100)
end

tick()
