--!nonstrict
-- Polls the EWEADN receiver and publishes the result for the bar widget.
-- The service is loaded with the plugin, so it starts automatically with
-- Noctalia and keeps running even if the widget is not on a bar.

local HELPER = noctalia.expandPath("~/.local/bin/eweadn-battery")
local POLL_MS = 30000
local LOW_PERCENT = 15

local last = nil
local pending = false
local refresh_queued = false
local lowNotified = false
local started_at = noctalia.nowMs()
local first_update = true

local function trim(value)
	if type(value) ~= "string" then
		return ""
	end
	local trimmed = noctalia.string.trim(value)
	if type(trimmed) ~= "string" then
		return ""
	end
	return trimmed
end

local function decode(value)
	local text = trim(value)
	if text == "" then
		return nil
	end
	local ok, parsed = pcall(noctalia.json.decode, text)
	if ok and type(parsed) == "table" then
		return parsed
	end
	return nil
end

local function result_error(data, result, fallback)
	if type(data) == "table" then
		local message = trim(data.error)
		if message ~= "" then
			return message
		end
	end

	local stderr = trim(result and result.stderr)
	if result and result.timedOut == true then
		if stderr ~= "" then
			return "helper timed out: " .. stderr
		end
		return "helper timed out"
	end
	if stderr ~= "" then
		return stderr
	end

	local exit_code = result and tonumber(result.exitCode)
	if exit_code ~= nil and exit_code ~= 0 then
		return string.format("helper exited with code %d", math.floor(exit_code))
	end

	return fallback
end

local function publish()
	noctalia.state.set("battery", last)
end

local function setError(message)
	message = trim(message)
	if message == "" then
		message = "could not read mouse battery"
	end

	if last == nil then
		last = {
			percent = nil,
			charging = false,
			ts = nil,
			error = message,
		}
	else
		last = {
			percent = last.percent,
			charging = last.charging,
			ts = last.ts,
			error = message,
			source = last.source,
		}
	end
	publish()
end

local poll

poll = function()
	if pending then
		-- A forced refresh must not be dropped just because a poll is running.
		refresh_queued = true
		return
	end
	pending = true

	local accepted = noctalia.runAsync({ "python3", HELPER, "--json" }, function(result)
		pending = false

		local data = decode(result and result.stdout)

		if result and result.exitCode == 0 and data and data.ok == true then
			local percent = data.percent
			if type(percent) == "number" then
				percent = math.floor(percent + 0.5)
			else
				percent = nil
			end

			local source = trim(data.source)
			if source == "" then
				source = "2.4 GHz receiver"
			end

			last = {
				percent = percent,
				charging = data.charging == true,
				ts = noctalia.nowMs(),
				error = nil,
				source = source,
			}

			if last.charging then
				lowNotified = false
			elseif percent ~= nil then
				if percent <= LOW_PERCENT then
					if not lowNotified then
						lowNotified = true
						noctalia.notify(
							"Mouse battery low",
							string.format("EWEADN S9: %d%% left. Charge it soon.", percent)
						)
					end
				elseif percent > LOW_PERCENT + 5 then
					lowNotified = false
				end
			end

			publish()
		else
			setError(result_error(data, result, "no reply from helper"))
		end

		if refresh_queued then
			refresh_queued = false
			poll()
		end
	end)

	if not accepted then
		pending = false
		setError("could not start helper")
		if refresh_queued then
			refresh_queued = false
			poll()
		end
	end
end

noctalia.setUpdateInterval(POLL_MS)

noctalia.state.watch("refresh", function()
	poll()
end)

poll()

function update()
	-- Noctalia invokes update() once immediately after the chunk loads. The
	-- top-level poll already covers startup, so skip only that duplicate.
	if first_update then
		first_update = false
		if noctalia.nowMs() - started_at < 5000 then
			return
		end
	end
	poll()
end

function onIpc(event)
	if event == "refresh" then
		poll()
	end
end
