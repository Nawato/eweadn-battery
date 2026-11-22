--!nonstrict
-- Control panel for the EWEADN S9. Reads the current settings, then writes
-- polling/DPI/button changes through the helper. Profiles are read-only on
-- the S9 because its vendor SDK has no direct profile-switch command.

local HELPER = noctalia.expandPath("~/.local/bin/eweadn-battery")

local POLL_VALUES = { 125, 250, 500, 1000, 2000, 4000, 8000 }

local ACTION_KEYS = {
	"left",
	"right",
	"middle",
	"back",
	"forward",
	"dpi_up",
	"dpi_down",
	"dpi_loop",
	"profile_1",
	"profile_2",
	"profile_3",
	"profile_4",
	"profile_cycle",
	"media_play_pause",
	"media_next",
	"media_prev",
	"media_mute",
	"volume_up",
	"volume_down",
	"disabled",
}

local ACTION_LABELS = {
	"Left click",
	"Right click",
	"Middle click",
	"Back",
	"Forward",
	"DPI up",
	"DPI down",
	"DPI loop",
	"Profile 1",
	"Profile 2",
	"Profile 3",
	"Profile 4",
	"Profile cycle",
	"Play / pause",
	"Next track",
	"Previous track",
	"Mute",
	"Volume up",
	"Volume down",
	"Disabled",
}

local config = nil
local loading = false
local busy = false
local error_message = nil
local status_message = nil

local draft_polling = 4
local draft_stage = 1
local draft_dpi = 800
local draft_buttons = {}
local draft_button_known = {}

local function trim(value)
	if type(value) ~= "string" then
		return ""
	end
	return noctalia.string.trim(value)
end

local function current_stage_dpi(stage)
	if config == nil then
		return 800
	end
	for _, entry in ipairs(config.dpi.stages or {}) do
		if entry.index == stage then
			return entry.dpi
		end
	end
	return 800
end

local function reset_drafts()
	if config == nil then
		return
	end
	if config.polling == nil or config.dpi == nil then
		draft_polling = 4
		draft_stage = 1
		draft_dpi = 800
		draft_buttons = {}
		draft_button_known = {}
		return
	end

	local polling = config.polling.hz or 1000
	draft_polling = 1
	for i, hz in ipairs(POLL_VALUES) do
		if hz == polling then
			draft_polling = i
			break
		end
	end

	draft_stage = config.dpi.current_stage or 1
	draft_dpi = current_stage_dpi(draft_stage)

	draft_buttons = {}
	draft_button_known = {}
	for index, key in ipairs(config.buttons or {}) do
		draft_buttons[index] = key.action
		draft_button_known[index] = false
		for _, action in ipairs(ACTION_KEYS) do
			if action == key.action then
				draft_button_known[index] = true
				break
			end
		end
	end
end

local function decode(value)
	if value == nil or value == "" then
		return nil
	end
	local ok, parsed = pcall(noctalia.json.decode, value)
	if ok then
		return parsed
	end
	return nil
end

local function main_icon(percent, charging)
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

local function profile_text()
	if config == nil or config.profile == nil then
		return "Profile unknown"
	end
	local current = math.max(1, tonumber(config.profile.current) or 1)
	local maximum = tonumber(config.profile.max) or 0
	if maximum <= 0 then
		return "Profile unknown"
	end
	return string.format("Profile %d of %d", current, maximum)
end

local function polling_index(hz)
	for i, value in ipairs(POLL_VALUES) do
		if value == hz then
			return i
		end
	end
	return 4
end

local function action_index(action)
	for i, key in ipairs(ACTION_KEYS) do
		if key == action then
			return i
		end
	end
	return nil
end

local render

local function do_refresh()
	loading = true
	error_message = nil
	render()

	local accepted = noctalia.runAsync({ "python3", HELPER, "config", "--json" }, function(result)
		loading = false
		local data = decode(result and result.stdout)
		if result and result.exitCode == 0 and data and data.ok then
			config = data
			reset_drafts()
			error_message = nil
		else
			error_message = (data and data.error) or trim(result and result.stderr) or "could not read mouse settings"
		end
		render()
	end)

	if not accepted then
		loading = false
		error_message = "could not start helper"
		render()
	end
end

local function apply(args, label)
	if busy then
		return
	end

	busy = true
	error_message = nil
	status_message = "Applying " .. label .. "…"
	render()

	local command = { "python3", HELPER }
	for _, value in ipairs(args) do
		table.insert(command, value)
	end
	table.insert(command, "--apply")
	table.insert(command, "--json")

	local accepted = noctalia.runAsync(command, function(result)
		busy = false
		local data = decode(result and result.stdout)
		if result and result.exitCode == 0 and data and data.ok then
			status_message = label .. " applied"
			if data.after then
				config = data.after
				reset_drafts()
			end
			noctalia.state.set("refresh", (noctalia.state.get("refresh") or 0) + 1)
		else
			status_message = nil
			error_message = (data and data.error) or trim(result and result.stderr) or "write failed"
		end
		render()
	end)

	if not accepted then
		busy = false
		status_message = nil
		error_message = "could not start helper"
		render()
	end
end

local function section(title, control)
	return ui.column({ gap = 8, align = "stretch" }, {
		ui.label({ text = title, fontWeight = "medium", color = "on_surface_variant" }),
		control,
	})
end

local function status_row(label, value, color)
	return ui.row({ align = "center", justify = "space_between", gap = 12 }, {
		ui.label({ text = label, color = "on_surface_variant", flexGrow = 1 }),
		ui.label({ text = value, color = color or "on_surface", fontWeight = "medium" }),
	})
end

local function build_polling()
	local selected = draft_polling or polling_index(config.polling.hz or 1000)
	local options = {}
	for _, hz in ipairs(POLL_VALUES) do
		table.insert(options, string.format("%d Hz", hz))
	end
	local changed = POLL_VALUES[selected] ~= config.polling.hz
	return section("Polling rate", ui.row({ gap = 8, align = "center" }, {
		ui.select({
			options = options,
			selectedIndex = selected - 1,
			onChange = function(value)
				draft_polling = (tonumber(value) or 0) + 1
				render()
			end,
			flexGrow = 1,
		}),
		ui.button({
			text = "Apply",
			variant = "primary",
			enabled = changed and not busy,
			onClick = function()
				apply({ "set-polling", tostring(POLL_VALUES[selected]) }, string.format("%d Hz polling", POLL_VALUES[selected]))
			end,
		}),
	}))
end

local function build_dpi()
	local stage_options = {}
	for stage = 1, config.dpi.stage_count do
		table.insert(stage_options, string.format("Stage %d", stage))
	end

	local changed = draft_stage ~= config.dpi.current_stage
		or draft_dpi ~= current_stage_dpi(config.dpi.current_stage)

	return section("DPI", ui.column({ gap = 10, align = "stretch" }, {
		ui.row({ gap = 8, align = "center" }, {
			ui.select({
				options = stage_options,
				selectedIndex = math.max(0, math.min(#stage_options - 1, draft_stage - 1)),
				onChange = function(value)
					draft_stage = (tonumber(value) or 0) + 1
					draft_dpi = current_stage_dpi(draft_stage)
					render()
				end,
				flexGrow = 1,
			}),
			ui.label({
				text = string.format("%d DPI", draft_dpi),
				fontWeight = "bold",
				color = "primary",
				width = 100,
				textAlign = "end",
			}),
		}),
		ui.slider({
			min = 50,
			max = config.dpi.max_dpi,
			step = 50,
			value = draft_dpi,
			onChange = function(value)
				draft_dpi = math.floor(tonumber(value) or 50)
				render()
			end,
		}),
		ui.row({ gap = 6, align = "center" }, {
			ui.button({
				text = "−500",
				variant = "ghost",
				controlSize = "sm",
				onClick = function()
					draft_dpi = math.max(50, draft_dpi - 500)
					render()
				end,
			}),
			ui.button({
				text = "−50",
				variant = "ghost",
				controlSize = "sm",
				onClick = function()
					draft_dpi = math.max(50, draft_dpi - 50)
					render()
				end,
			}),
			ui.button({
				text = "+50",
				variant = "ghost",
				controlSize = "sm",
				onClick = function()
					draft_dpi = math.min(config.dpi.max_dpi, draft_dpi + 50)
					render()
				end,
			}),
			ui.button({
				text = "+500",
				variant = "ghost",
				controlSize = "sm",
				onClick = function()
					draft_dpi = math.min(config.dpi.max_dpi, draft_dpi + 500)
					render()
				end,
			}),
			ui.spacer({ flexGrow = 1 }),
			ui.label({
				text = string.format("max %d", config.dpi.max_dpi),
				color = "on_surface_variant",
				fontSize = 12,
			}),
		}),
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.label({
				text = string.format("Sensor max %d DPI", config.dpi.max_dpi),
				color = "on_surface_variant",
				flexGrow = 1,
			}),
			ui.button({
				text = "Apply",
				variant = "primary",
				enabled = changed and not busy,
				onClick = function()
					apply({
						"set-dpi",
						tostring(draft_stage),
						tostring(draft_dpi),
						"--stage-count",
						tostring(config.dpi.stage_count),
					}, string.format("%d DPI", draft_dpi))
				end,
			}),
		}),
	}))
end

local function button_options(action)
	local options = {}
	local selected = 1
	local known = false
	for i, key in ipairs(ACTION_KEYS) do
		table.insert(options, ACTION_LABELS[i])
		if key == action then
			selected = i
			known = true
		end
	end
	if not known then
		table.insert(options, "Unknown (" .. tostring(action) .. ")")
		selected = #options
	end
	return options, selected, known
end

local function build_buttons()
	local rows = {}
	local label_width = 72
	local select_width = 260
	local apply_width = 64

	for index, key in ipairs(config.buttons or {}) do
		local draft = draft_buttons[index] or key.action
		local options, selected = button_options(draft)
		local known = draft_button_known[index] == true
		local changed = draft ~= key.action and known

		table.insert(rows, ui.row({ gap = 8, align = "center" }, {
			ui.label({
				text = key.button,
				width = label_width,
				color = "on_surface_variant",
			}),
			ui.select({
				options = options,
				selectedIndex = selected - 1,
				onChange = function(value)
					local chosen = (tonumber(value) or 0) + 1
					if chosen <= #ACTION_KEYS then
						draft_buttons[index] = ACTION_KEYS[chosen]
						draft_button_known[index] = true
					end
					render()
				end,
				width = select_width,
			}),
			ui.button({
				text = "Apply",
				variant = changed and "primary" or "secondary",
				enabled = changed and not busy,
				width = apply_width,
				onClick = function()
					apply({
						"set-button",
						key.button,
						draft,
					}, key.button .. " button")
				end,
			}),
		}))
	end

	return section("Mouse buttons", ui.column({ gap = 8, align = "stretch" }, rows))
end

local function build_status()
	local battery = config.battery or {}
	local charging = battery.charging == true
	local percent = battery.percent
	local battery_text = charging and "Charging" or (percent ~= nil and string.format("%d%%", percent) or "Unknown")

	local rows = {
		ui.row({ gap = 12, align = "center" }, {
			ui.glyph({
				name = main_icon(percent, charging),
				size = 26,
				color = charging and "primary" or (percent ~= nil and percent <= 15 and "error" or "on_surface"),
			}),
			ui.column({ gap = 2, flexGrow = 1 }, {
				ui.label({ text = "EWEADN S9", fontWeight = "bold", fontSize = 16 }),
				ui.label({ text = config.device.source, color = "on_surface_variant" }),
			}),
			ui.label({
				text = battery_text,
				fontSize = 18,
				fontWeight = "bold",
				color = charging and "primary" or (percent ~= nil and percent <= 15 and "error" or "on_surface"),
			}),
		}),
		ui.separator({ spacing = 2 }),
	}

	if config.polling then
		table.insert(rows, status_row("Polling", string.format("%d Hz", config.polling.hz)))
	end
	if config.dpi then
		table.insert(rows, status_row("DPI", string.format("%d DPI", current_stage_dpi(config.dpi.current_stage))))
	end
	if config.profile and (tonumber(config.profile.max) or 0) > 0 then
		table.insert(rows, status_row("Profile", profile_text(), "primary"))
	end

	return ui.column({ gap = 8, align = "stretch" }, rows)
end

render = function()
	if config == nil then
		local content = {
			ui.row({ align = "center", justify = "space_between", gap = 8 }, {
				ui.label({ text = "EWEADN S9", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
				ui.button({ glyph = "refresh", variant = "ghost", enabled = not loading, onClick = "refresh" }),
				ui.button({ glyph = "x", variant = "ghost", onClick = "close_panel" }),
			}),
		}
		if loading then
			table.insert(content, ui.label({ text = "Reading mouse settings…", color = "on_surface_variant" }))
		else
			table.insert(content, ui.label({
				text = error_message or "Could not read mouse settings",
				color = "error",
			}))
			table.insert(content, ui.button({ text = "Retry", variant = "primary", onClick = "refresh" }))
		end
		panel.render(ui.column({ gap = 16, flexGrow = 1 }, content))
		return
	end

	local content = {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.label({ text = "EWEADN S9", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
			ui.button({ glyph = "refresh", variant = "ghost", enabled = not loading and not busy, onClick = "refresh" }),
			ui.button({ glyph = "x", variant = "ghost", onClick = "close_panel" }),
		}),
		build_status(),
	}

	if error_message ~= nil then
		table.insert(content, ui.label({ text = error_message, color = "error" }))
	end
	if status_message ~= nil then
		table.insert(content, ui.label({ text = status_message, color = "primary" }))
	end

	table.insert(content, ui.separator({ spacing = 4 }))

	if config.settings_available == false then
		table.insert(content, section("Settings", ui.label({
			text = "Settings are unavailable over Bluetooth. Use the 2.4 GHz receiver or the USB cable for polling, DPI, and button changes.",
			color = "on_surface_variant",
		})))
		table.insert(content, ui.label({
			text = "Battery monitoring still works over Bluetooth through BlueZ.",
			color = "on_surface_variant",
			fontSize = 12,
		}))
	else
		table.insert(content, build_polling())
		table.insert(content, build_dpi())
		table.insert(content, build_buttons())
		table.insert(content, section("Profiles", ui.column({ gap = 6, align = "stretch" }, {
			ui.label({ text = profile_text(), fontWeight = "medium" }),
			ui.label({
				text = "The S9 firmware has no direct profile-switch command. Use the onboard profile button or bind a button to Profile 1-4 or Profile cycle above.",
				color = "on_surface_variant",
				fontSize = 12,
			}),
		})))
		table.insert(content, ui.label({
			text = "Changes are written to onboard memory. A backup is saved before every write.",
			color = "on_surface_variant",
			fontSize = 12,
		}))
	end

	local scrolled = {}
	for i = 3, #content do
		table.insert(scrolled, content[i])
	end

	panel.render(ui.column({ flexGrow = 1, gap = 14 }, {
		content[1],
		content[2],
		ui.scroll({ flexGrow = 1, gap = 14 }, scrolled),
	}))
end

function onOpen(_context)
	if config == nil then
		loading = true
	else
		loading = false
	end
	error_message = nil
	status_message = nil
	render()
	do_refresh()
end

function refresh()
	do_refresh()
end

function close_panel()
	panel.close()
end
