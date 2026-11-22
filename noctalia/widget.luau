--!nonstrict
-- Bar widget for the battery value published by service.luau.

local function glyphFor(percent, charging, error)
	if error ~= nil then
		return "battery-exclamation"
	end
	if charging then
		return "battery-charging"
	end
	if percent == nil then
		return "battery-off"
	end
	if percent >= 90 then
		return "battery-4"
	elseif percent >= 65 then
		return "battery-3"
	elseif percent >= 40 then
		return "battery-2"
	elseif percent >= 15 then
		return "battery-1"
	end
	return "battery"
end

local function relativeTime(ts)
	if ts == nil then
		return "never"
	end
	local seconds = math.max(0, math.floor((noctalia.nowMs() - ts) / 1000))
	if seconds < 60 then
		return string.format("%ds ago", seconds)
	end
	local minutes = math.floor(seconds / 60)
	if minutes < 60 then
		return string.format("%dm ago", minutes)
	end
	return string.format("%dh ago", math.floor(minutes / 60))
end

local function render(battery)
	if battery == nil then
		barWidget.setGlyph("battery-off")
		barWidget.setText("--")
		barWidget.setColor("on_surface")
		barWidget.setTooltip({
			{ key = "Mouse", value = "EWEADN S9" },
			{ key = "Status", value = "waiting for 2.4 GHz receiver" },
		})
		return
	end

	local percent = tonumber(battery.percent)
	if percent ~= nil then
		percent = math.floor(percent)
	end
	local charging = battery.charging == true
	local error = battery.error
	if type(error) == "string" then
		error = noctalia.string.trim(error)
	end
	if type(error) ~= "string" or error == "" then
		error = nil
	end

	barWidget.setGlyph(glyphFor(percent, charging, error))

	if charging then
		if error ~= nil then
			barWidget.setText("Charging?")
			barWidget.setColor("secondary")
		else
			barWidget.setText("Charging")
			barWidget.setColor("primary")
		end
	elseif percent ~= nil then
		if error ~= nil then
			barWidget.setText(string.format("%d%%?", percent))
			if percent <= 15 then
				barWidget.setColor("error")
			else
				barWidget.setColor("secondary")
			end
		else
			barWidget.setText(string.format("%d%%", percent))
			if percent <= 15 then
				barWidget.setColor("error")
			else
				barWidget.setColor("on_surface")
			end
		end
	else
		barWidget.setText("--")
		barWidget.setColor(error ~= nil and "secondary" or "on_surface")
	end

	local status
	if charging then
		if error ~= nil then
			status = "charging? (last reading may be stale)"
		elseif percent ~= nil then
			status = string.format("charging at %d%%", percent)
		else
			status = "charging (level not reported)"
		end
	elseif percent ~= nil then
		status = error ~= nil and string.format("%d%% (stale)", percent) or "discharging"
	else
		status = "unknown"
	end

	local tooltip = {
		{ key = "Mouse", value = "EWEADN S9" },
		{ key = "Battery", value = status },
		{ key = "Link", value = battery.source or "2.4 GHz receiver" },
		{ key = "Updated", value = relativeTime(battery.ts) },
	}
	if error ~= nil then
		table.insert(tooltip, { key = "Error", value = error })
	end
	barWidget.setTooltip(tooltip)
end

noctalia.state.watch("battery", render)
render(noctalia.state.get("battery"))

function onClick()
	noctalia.togglePanel("nawato/eweadn-battery:control")
end

function onRightClick()
	noctalia.state.set("refresh", (noctalia.state.get("refresh") or 0) + 1)
end
