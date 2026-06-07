local api_base_url = "https://ipod-2to6magyna-uc.a.run.app/"
local version = "2.1"

local width, height = term.getSize()
local tab = 1

local waiting_for_input = false
local last_search = nil
local last_search_url = nil
local search_results = nil
local search_error = false
local in_search_result = false
local clicked_result = nil

local playing = false
local queue = {}
local now_playing = nil
local looping = 0
local volume = 1.5

local playing_id = nil
local last_download_url = nil
local playing_status = 0
local is_loading = false
local is_error = false

local player_handle = nil
local start_bytes = nil
local size = nil
local decoder = require "cc.audio.dfpwm".make_decoder()
local needs_next_chunk = 0
local buffer

-- ============================================================
-- MODEM SETUP
-- ============================================================
local modem = nil
local modem_name = nil
for _, name in ipairs(peripheral.getNames()) do
	if peripheral.getType(name) == "modem" then
		modem = peripheral.wrap(name)
		modem_name = name
		break
	end
end
if modem then
	rednet.open(modem_name)
end

local PROTOCOL_ANNOUNCE = "music_announce"
local PROTOCOL_AUDIO    = "music_audio"
local PROTOCOL_CTRL     = "music_ctrl"

-- ============================================================
-- SPEAKERS
-- Local speakers (wired/direct) + remote clients (Ender Modem)
-- speaker_list: { name, label, enabled, is_remote, obj?, client_id? }
-- ============================================================
local speaker_list = {}
local remote_clients = {} -- { id, label, last_seen }

local function refreshLocalSpeakers()
	-- keep existing enabled states
	local prev = {}
	for _, sp in ipairs(speaker_list) do
		prev[sp.name] = sp.enabled
	end
	-- rebuild: keep remotes, replace locals
	local new_list = {}
	for _, sp in ipairs(speaker_list) do
		if sp.is_remote then table.insert(new_list, sp) end
	end
	for _, name in ipairs(peripheral.getNames()) do
		if peripheral.getType(name) == "speaker" then
			local en = prev[name]
			if en == nil then en = true end
			table.insert(new_list, {
				name = name, label = name,
				enabled = en, is_remote = false,
				obj = peripheral.wrap(name)
			})
		end
	end
	speaker_list = new_list
end

local function registerClient(id, label)
	-- update or add remote client
	for _, c in ipairs(remote_clients) do
		if c.id == id then c.label = label; c.last_seen = os.clock(); return end
	end
	table.insert(remote_clients, { id = id, label = label, last_seen = os.clock() })
	-- add to speaker_list
	local key = "remote_"..id
	for _, sp in ipairs(speaker_list) do
		if sp.name == key then return end
	end
	table.insert(speaker_list, {
		name = key,
		label = "Remote: "..(label ~= "" and label or "PC#"..id),
		enabled = true,
		is_remote = true,
		client_id = id
	})
	os.queueEvent("redraw_screen")
end

local function getLocalSpeakers()
	local out = {}
	for _, sp in ipairs(speaker_list) do
		if not sp.is_remote and sp.enabled then table.insert(out, sp.obj) end
	end
	return out
end

local function getRemoteIds()
	local out = {}
	for _, sp in ipairs(speaker_list) do
		if sp.is_remote and sp.enabled then table.insert(out, sp.client_id) end
	end
	return out
end

local function stopAll()
	for _, sp in ipairs(speaker_list) do
		if not sp.is_remote and sp.enabled then sp.obj.stop() end
	end
	if modem then
		for _, sp in ipairs(speaker_list) do
			if sp.is_remote and sp.enabled then
				rednet.send(sp.client_id, {cmd="stop"}, PROTOCOL_CTRL)
			end
		end
	end
	os.queueEvent("playback_stopped")
end

refreshLocalSpeakers()

-- ============================================================
-- DRAW
-- ============================================================
function redrawScreen()
	if waiting_for_input then return end
	term.setCursorBlink(false)
	term.setBackgroundColor(colors.black)
	term.clear()

	term.setCursorPos(1,1)
	term.setBackgroundColor(colors.gray)
	term.clearLine()
	local tabs = {" Playing ", " Search ", " Speakers "}
	for i=1,#tabs do
		if tab == i then
			term.setTextColor(colors.black)
			term.setBackgroundColor(colors.white)
		else
			term.setTextColor(colors.white)
			term.setBackgroundColor(colors.gray)
		end
		term.setCursorPos((math.floor((width/#tabs)*(i-0.5)))-math.ceil(#tabs[i]/2)+1, 1)
		term.write(tabs[i])
	end

	if     tab == 1 then drawNowPlaying()
	elseif tab == 2 then drawSearch()
	elseif tab == 3 then drawSpeakers()
	end
end

function drawNowPlaying()
	term.setBackgroundColor(colors.black)
	if now_playing then
		term.setTextColor(colors.white)
		term.setCursorPos(2,3) term.write(now_playing.name)
		term.setTextColor(colors.lightGray)
		term.setCursorPos(2,4) term.write(now_playing.artist)
	else
		term.setTextColor(colors.lightGray)
		term.setCursorPos(2,3) term.write("Not playing")
	end

	term.setCursorPos(2,5)
	if is_loading then
		term.setTextColor(colors.gray) term.write("Loading...")
	elseif is_error then
		term.setTextColor(colors.red) term.write("Network error")
	else
		term.write("                ")
	end

	term.setBackgroundColor(colors.gray)
	if playing then
		term.setTextColor(colors.white)
	else
		term.setTextColor((now_playing or #queue>0) and colors.white or colors.lightGray)
	end
	term.setCursorPos(2,6) term.write(playing and " Stop " or " Play ")

	term.setTextColor((now_playing or #queue>0) and colors.white or colors.lightGray)
	term.setCursorPos(9,6) term.write(" Skip ")

	if looping ~= 0 then
		term.setTextColor(colors.black) term.setBackgroundColor(colors.white)
	else
		term.setTextColor(colors.white) term.setBackgroundColor(colors.gray)
	end
	term.setCursorPos(16,6)
	if     looping==0 then term.write(" Loop Off   ")
	elseif looping==1 then term.write(" Loop Queue ")
	else                   term.write(" Loop Song  ") end

	paintutils.drawBox(2,8,25,8,colors.gray)
	local vw = math.floor(24*(volume/3)+0.5)-1
	if vw >= 0 then paintutils.drawBox(2,8,2+vw,8,colors.white) end
	if volume < 0.6 then
		term.setCursorPos(2+vw+2,8) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white)
	else
		term.setCursorPos(2+vw-3-(volume==3 and 1 or 0),8)
		term.setBackgroundColor(colors.white) term.setTextColor(colors.black)
	end
	term.write(math.floor(100*(volume/3)+0.5).."%")

	if #queue > 0 then
		term.setBackgroundColor(colors.black)
		for i=1,math.min(#queue,4) do
			term.setTextColor(colors.white)
			term.setCursorPos(2,10+(i-1)*2) term.write(queue[i].name)
			term.setTextColor(colors.lightGray)
			term.setCursorPos(2,11+(i-1)*2) term.write(queue[i].artist)
		end
	end
end

function drawSearch()
	paintutils.drawFilledBox(2,3,width-1,5,colors.lightGray)
	term.setBackgroundColor(colors.lightGray)
	term.setCursorPos(3,4) term.setTextColor(colors.black)
	term.write(last_search or "Search...")

	if search_results then
		term.setBackgroundColor(colors.black)
		for i=1,#search_results do
			term.setTextColor(colors.white)
			term.setCursorPos(2,7+(i-1)*2) term.write(search_results[i].name)
			term.setTextColor(colors.lightGray)
			term.setCursorPos(2,8+(i-1)*2) term.write(search_results[i].artist)
		end
	else
		term.setCursorPos(2,7) term.setBackgroundColor(colors.black)
		if search_error then
			term.setTextColor(colors.red) term.write("Network error")
		elseif last_search_url then
			term.setTextColor(colors.lightGray) term.write("Searching...")
		else
			term.setCursorPos(1,7) term.setTextColor(colors.lightGray)
			print("Tip: You can paste YouTube video or playlist links.")
		end
	end

	if in_search_result then
		term.setBackgroundColor(colors.black) term.clear()
		term.setTextColor(colors.white)
		term.setCursorPos(2,2) term.write(search_results[clicked_result].name)
		term.setTextColor(colors.lightGray)
		term.setCursorPos(2,3) term.write(search_results[clicked_result].artist)
		term.setBackgroundColor(colors.gray) term.setTextColor(colors.white)
		term.setCursorPos(2,6)  term.clearLine() term.write("Play now")
		term.setCursorPos(2,8)  term.clearLine() term.write("Play next")
		term.setCursorPos(2,10) term.clearLine() term.write("Add to queue")
		term.setCursorPos(2,13) term.clearLine() term.write("Cancel")
	end
end

function drawSpeakers()
	term.setBackgroundColor(colors.black)

	term.setBackgroundColor(colors.gray) term.setTextColor(colors.white)
	term.setCursorPos(2,2) term.write(" Refresh ")

	local active_count = 0
	for _, sp in ipairs(speaker_list) do if sp.enabled then active_count=active_count+1 end end
	term.setBackgroundColor(colors.black) term.setTextColor(colors.lightGray)
	term.setCursorPos(13,2)
	term.write(active_count.."/"..#speaker_list.." active")

	-- modem status
	term.setCursorPos(width-10, 2)
	if modem then
		term.setTextColor(colors.lime) term.write("Modem OK")
	else
		term.setTextColor(colors.red) term.write("No modem")
	end

	for i, sp in ipairs(speaker_list) do
		local y = 3 + (i-1)
		if y > height then break end
		if sp.enabled then
			term.setBackgroundColor(colors.lime) term.setTextColor(colors.black)
		else
			term.setBackgroundColor(colors.red) term.setTextColor(colors.white)
		end
		term.setCursorPos(2,y) term.write(sp.enabled and " ON  " or " OFF ")

		term.setBackgroundColor(colors.black)
		term.setTextColor(sp.is_remote and colors.cyan or colors.white)
		term.setCursorPos(8,y)
		local lbl = sp.label
		if #lbl > width-9 then lbl = lbl:sub(1,width-9) end
		term.write(lbl)
	end

	if #speaker_list == 0 then
		term.setBackgroundColor(colors.black) term.setTextColor(colors.gray)
		term.setCursorPos(2,4) term.write("No speakers found")
	end

	if modem then
		term.setBackgroundColor(colors.black) term.setTextColor(colors.gray)
		term.setCursorPos(2,height) term.write("Run speaker_client on remote PCs")
	end
end

-- ============================================================
-- UI LOOP
-- ============================================================
function uiLoop()
	redrawScreen()
	while true do
		if waiting_for_input then
			parallel.waitForAny(
				function()
					term.setCursorPos(3,4)
					term.setBackgroundColor(colors.white) term.setTextColor(colors.black)
					local input = read()
					if #input > 0 then
						last_search = input
						last_search_url = api_base_url.."?v="..version.."&search="..textutils.urlEncode(input)
						http.request(last_search_url)
						search_results = nil search_error = false
					else
						last_search=nil last_search_url=nil search_results=nil search_error=false
					end
					waiting_for_input = false
					os.queueEvent("redraw_screen")
				end,
				function()
					while waiting_for_input do
						local _,_,x,y = os.pullEvent("mouse_click")
						if y<3 or y>5 or x<2 or x>width-1 then
							waiting_for_input=false os.queueEvent("redraw_screen") break
						end
					end
				end
			)
		else
			parallel.waitForAny(
				function()
					local _,btn,x,y = os.pullEvent("mouse_click")
					if btn~=1 then return end

					if not in_search_result and y==1 then
						if     x < width/3   then tab=1
						elseif x < 2*width/3 then tab=2
						else                      tab=3 end
						redrawScreen() return
					end

					if tab==2 and not in_search_result then
						if y>=3 and y<=5 and x>=1 and x<=width-1 then
							paintutils.drawFilledBox(2,3,width-1,5,colors.white)
							waiting_for_input=true
						end
						if search_results then
							for i=1,#search_results do
								if y==7+(i-1)*2 or y==8+(i-1)*2 then
									in_search_result=true clicked_result=i redrawScreen()
								end
							end
						end
					elseif tab==2 and in_search_result then
						local r = search_results[clicked_result]
						if y==6 then
							in_search_result=false stopAll()
							playing=true is_error=false playing_id=nil
							if r.type=="playlist" then
								now_playing=r.playlist_items[1] queue={}
								for i=2,#r.playlist_items do table.insert(queue,r.playlist_items[i]) end
							else now_playing=r end
							os.queueEvent("audio_update")
						elseif y==8 then
							in_search_result=false
							if r.type=="playlist" then
								for i=#r.playlist_items,1,-1 do table.insert(queue,1,r.playlist_items[i]) end
							else table.insert(queue,1,r) end
							os.queueEvent("audio_update")
						elseif y==10 then
							in_search_result=false
							if r.type=="playlist" then
								for i=1,#r.playlist_items do table.insert(queue,r.playlist_items[i]) end
							else table.insert(queue,r) end
							os.queueEvent("audio_update")
						elseif y==13 then in_search_result=false end
						redrawScreen()

					elseif tab==1 and not in_search_result then
						if y==6 then
							if x>=2 and x<8 then
								if playing then
									playing=false stopAll() playing_id=nil is_loading=false is_error=false
									os.queueEvent("audio_update")
								elseif now_playing then
									playing_id=nil playing=true is_error=false os.queueEvent("audio_update")
								elseif #queue>0 then
									now_playing=queue[1] table.remove(queue,1)
									playing_id=nil playing=true is_error=false os.queueEvent("audio_update")
								end
							end
							if x>=9 and x<15 then
								if now_playing or #queue>0 then
									is_error=false
									if playing then stopAll() end
									if #queue>0 then
										if looping==1 then table.insert(queue,now_playing) end
										now_playing=queue[1] table.remove(queue,1) playing_id=nil
									else
										now_playing=nil playing=false is_loading=false is_error=false playing_id=nil
									end
									os.queueEvent("audio_update")
								end
							end
							if x>=16 and x<28 then looping=(looping+1)%3 end
						end
						if y==8 and x>=1 and x<26 then volume=(x-1)/24*3 end
						redrawScreen()

					elseif tab==3 then
						if y==2 and x>=2 and x<=10 then
							refreshLocalSpeakers() redrawScreen()
						end
						for i,sp in ipairs(speaker_list) do
							local sy = 3+(i-1)
							if y==sy and x>=2 and x<=6 then
								speaker_list[i].enabled = not speaker_list[i].enabled
								if not speaker_list[i].enabled then
									if sp.is_remote then
										if modem then rednet.send(sp.client_id,{cmd="stop"},PROTOCOL_CTRL) end
									else
										sp.obj.stop()
										os.queueEvent("playback_stopped")
									end
								end
								redrawScreen() return
							end
						end
					end
				end,
				function()
					local _,btn,x,y = os.pullEvent("mouse_drag")
					if btn==1 and tab==1 and not in_search_result then
						if y>=7 and y<=9 and x>=1 and x<26 then
							volume=(x-1)/24*3 redrawScreen()
						end
					end
				end,
				function()
					os.pullEvent("redraw_screen") redrawScreen()
				end
			)
		end
	end
end

-- ============================================================
-- AUDIO LOOP
-- ============================================================
function audioLoop()
	local last_sent_track_id = nil
	while true do
		if playing and now_playing then
			local thisid = now_playing.id
			if playing_id ~= thisid then
				playing_id = thisid
				last_download_url = api_base_url.."?v="..version.."&id="..textutils.urlEncode(playing_id)
				playing_status=0 needs_next_chunk=1
				http.request({url=last_download_url, binary=true})
				is_loading=true
				os.queueEvent("redraw_screen") os.queueEvent("audio_update")
			elseif playing_status==1 and needs_next_chunk==1 then
				
				-- ENVIA AS INFORMAÇÕES DE MÚSICA APENAS UMA VEZ NO INÍCIO DA REPRODUÇÃO VIA PROTOCOL_CTRL
				if last_sent_track_id ~= thisid then
					last_sent_track_id = thisid
					local remote_ids = getRemoteIds()
					if modem and #remote_ids > 0 then
						for _, cid in ipairs(remote_ids) do
							rednet.send(cid, {
								cmd = "track_info",
								name = now_playing.name,
								artist = now_playing.artist,
								vol = volume
							}, PROTOCOL_CTRL)
						end
					end
				end

				while true do
					local chunk = player_handle.read(size)
					if not chunk then
						last_sent_track_id = nil
						if looping==2 or (looping==1 and #queue==0) then
							playing_id=nil
						elseif looping==1 and #queue>0 then
							table.insert(queue,now_playing) now_playing=queue[1] table.remove(queue,1) playing_id=nil
						else
							if #queue>0 then
								now_playing=queue[1] table.remove(queue,1) playing_id=nil
							else
								now_playing=nil playing=false playing_id=nil is_loading=false is_error=false
							end
						end
						os.queueEvent("redraw_screen")
						player_handle.close() needs_next_chunk=0 break
					else
						if start_bytes then
							chunk,start_bytes = start_bytes..chunk,nil size=size+4
						end
						buffer = decoder(chunk)

						-- Send audio + volume to remote clients
						local remote_ids = getRemoteIds()
						if modem and #remote_ids > 0 then
							for _, cid in ipairs(remote_ids) do
								rednet.send(cid, {data=buffer, vol=volume}, PROTOCOL_AUDIO)
							end
						end

						-- Play on local speakers
						local local_spks = getLocalSpeakers()
						local fn = {}
						for i,speaker in ipairs(local_spks) do
							fn[i] = function()
								local name = peripheral.getName(speaker)
								while not speaker.playAudio(buffer,volume) do
									parallel.waitForAny(
										function() repeat until select(2,os.pullEvent("speaker_audio_empty"))==name end,
										function() os.pullEvent("playback_stopped") end
									)
									if not playing or playing_id~=thisid then return end
								end
								parallel.waitForAny(
									function() repeat until select(2,os.pullEvent("speaker_audio_empty"))==name end,
									function() os.pullEvent("playback_stopped") end
								)
								if not playing or playing_id~=thisid then return end
							end
						end

						if #fn > 0 then
							local ok,err = pcall(parallel.waitForAll,table.unpack(fn))
							if not ok then needs_next_chunk=2 is_error=true break end
						elseif #remote_ids == 0 then
							sleep(0.05)
						else
							sleep(0.1)
						end

						if not playing or playing_id~=thisid then break end
					end
				end
				os.queueEvent("audio_update")
			end
		else
			last_sent_track_id = nil
		end
		os.pullEvent("audio_update")
	end
end

-- ============================================================
-- HTTP LOOP
-- ============================================================
function httpLoop()
	while true do
		parallel.waitForAny(
			function()
				local _,url,handle = os.pullEvent("http_success")
				if url==last_search_url then
					search_results=textutils.unserialiseJSON(handle.readAll())
					os.queueEvent("redraw_screen")
				end
				if url==last_download_url then
					is_loading=false player_handle=handle
					start_bytes=handle.read(4) size=16*1024-4
					playing_status=1
					os.queueEvent("redraw_screen") os.queueEvent("audio_update")
				end
			end,
			function()
				local _,url = os.pullEvent("http_failure")
				if url==last_search_url then search_error=true os.queueEvent("redraw_screen") end
				if url==last_download_url then
					is_loading=false is_error=true playing=false playing_id=nil
					os.queueEvent("redraw_screen") os.queueEvent("audio_update")
				end
			end
		)
	end
end

-- ============================================================
-- REDNET LOOP - listens for client announcements
-- ============================================================
function rednetLoop()
	if not modem then return end
	while true do
		local sender, msg = rednet.receive(PROTOCOL_ANNOUNCE, 30)
		if sender and type(msg)=="table" and msg.cmd=="hello" then
			registerClient(sender, msg.label or "")
		end
	end
end

parallel.waitForAny(uiLoop, audioLoop, httpLoop, rednetLoop)