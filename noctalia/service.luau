--!nonstrict
-- Polls the EWEADN receiver and publishes the result for the bar widget.
-- The service is loaded with the plugin, so it starts automatically with
-- Noctalia and keeps running even if the widget is not on a bar.

local HELPER = noctalia.expandPath("~/.local/bin/eweadn-battery")
local POLL_MS = 30000
local LOW_PERCENT = 15

local last = nil
local pending = false
local lowNotified = false

local function publish()
	noctalia.state.set("battery", last)
end

local function setError(message)
	if last == nil then
		last = {
			percent = nil,
			charging = false,
			ts = noctalia.nowMs(),
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

local function poll()
	if pending then
		return
	end
	pending = true

	local accepted = noctalia.runAsync({ "python3", HELPER, "--json" }, function(result)
		pending = false

		local data = nil
		if result and result.stdout and result.stdout ~= "" then
			data = noctalia.json.decode(result.stdout)
		end

		if result and result.exitCode == 0 and data and data.ok then
			local percent = data.percent
			if type(percent) == "number" then
				percent = math.floor(percent + 0.5)
			else
				percent = nil
			end

			local charging = data.charging == true
			last = {
				percent = percent,
				charging = charging,
				ts = noctalia.nowMs(),
				error = nil,
				source = data.source or "2.4 GHz receiver",
			}

			if charging then
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
			local message = "no reply"
			if data and data.error then
				message = data.error
			elseif result and result.stderr and result.stderr ~= "" then
				message = noctalia.string.trim(result.stderr)
			end
			setError(message)
		end
	end)

	if not accepted then
		pending = false
		setError("could not start helper")
	end
end

noctalia.state.watch("refresh", function()
	poll()
end)

poll()

function update()
	noctalia.setUpdateInterval(POLL_MS)
	poll()
end

function onIpc(event)
	if event == "refresh" then
		poll()
	end
end
