-- speaker_client.lua

local PROTOCOL_ANNOUNCE = "music_announce"
local PROTOCOL_AUDIO    = "music_audio"
local PROTOCOL_CTRL     = "music_ctrl"

-- ============================================================
-- MODEM SETUP
-- ============================================================
local modem_name = nil
for _, name in ipairs(peripheral.getNames()) do
	if peripheral.getType(name) == "modem" then
		modem_name = name break
	end
end
if not modem_name then
	error("No modem found! Attach an Ender Modem.", 0)
end
rednet.open(modem_name)

-- ============================================================
-- MULTI-SPEAKER MANAGER
-- ============================================================
local speakers = {}

local function refreshSpeakers()
	speakers = {}
	for _, name in ipairs(peripheral.getNames()) do
		if peripheral.getType(name) == "speaker" then
			table.insert(speakers, { obj = peripheral.wrap(name), name = name })
		end
	end
end

refreshSpeakers()

if #speakers == 0 then
	error("No speakers found! Attach at least one.", 0)
end

local label = os.getComputerLabel() or ("PC#"..os.getComputerID())
local stop_requested = false
local current_title = "None"
local current_artist = ""
local is_playing_audio = false
local current_volume = 1.5

-- ============================================================
-- INTERFACE
-- ============================================================
local function drawInterface(status_msg, color)
	term.clear()
	term.setCursorPos(1,1)
	term.setTextColor(colors.white)
	print("=== Multi-Speaker Client ===")
	print("Label:    "..label)
	print("ID:       "..os.getComputerID())
	print("Modem:    "..modem_name)
	print("Speakers: "..#speakers)
	print("----------------------------")
	term.setTextColor(colors.cyan)
	print("Now Playing: " .. current_title)
	term.setTextColor(colors.lightGray)
	print("Volume:      " .. math.floor(100*(current_volume/3)+0.5) .. "%")
	print("----------------------------")
	term.setCursorPos(1,11)
	term.setTextColor(color or colors.orange)
	term.write(status_msg or "Waiting for server...    ")
end

drawInterface("Waiting for server...", colors.orange)

-- ============================================================
-- LOOPS
-- ============================================================

local function announceLoop()
	while true do
		rednet.broadcast({cmd="hello", label=label}, PROTOCOL_ANNOUNCE)
		sleep(5)
	end
end

local function audioLoop()
	while true do
		local sender, msg = rednet.receive(PROTOCOL_AUDIO, 15)
		if msg then
			local vol = msg.vol or 1.5
			local needs_redraw = not is_playing_audio or (vol ~= current_volume)

			is_playing_audio = true
			stop_requested = false
			current_volume = vol

			if needs_redraw then
				drawInterface("Synchronized & Playing", colors.lime)
			end

			local fn = {}
			for i, sp in ipairs(speakers) do
				fn[i] = function()
					while not sp.obj.playAudio(msg.data or msg, vol) do
						parallel.waitForAny(
							function() repeat until select(2, os.pullEvent("speaker_audio_empty")) == sp.name end,
							function() repeat until stop_requested sleep(0.1) end
						)
						if stop_requested then return end
					end
				end
			end

			if #fn > 0 then
				pcall(parallel.waitForAll, table.unpack(fn))
			end
		else
			if is_playing_audio then
				is_playing_audio = false
				current_title = "None"
				current_artist = ""
				drawInterface("Waiting for server...", colors.orange)
			end
		end
	end
end

local function ctrlLoop()
	while true do
		local sender, msg = rednet.receive(PROTOCOL_CTRL)
		if msg and type(msg) == "table" then
			if msg.cmd == "stop" then
				stop_requested = true
				for _, sp in ipairs(speakers) do sp.obj.stop() end
				current_title = "None"
				current_artist = ""
				is_playing_audio = false
				drawInterface("Stopped by server.", colors.orange)

			elseif msg.cmd == "track_info" then
				current_title = msg.name or "Unknown Track"
				current_artist = msg.artist or "Unknown Artist"
				if msg.vol then current_volume = msg.vol end
				drawInterface("Synchronized & Playing", colors.lime)
			end
		end
	end
end

local function statusLoop()
	local spin = {"|", "/", "-", "\\"}
	local i = 1
	while true do
		term.setCursorPos(25, 11)
		if is_playing_audio then
			term.setTextColor(colors.lime)
			term.write(spin[i])
		else
			term.setTextColor(colors.orange)
			term.write(" ")
		end
		i = i % 4 + 1
		sleep(0.2)
	end
end

parallel.waitForAny(announceLoop, audioLoop, ctrlLoop, statusLoop)