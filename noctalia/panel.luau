--!nonstrict
-- Control panel for the EWEADN S9. Reads the current settings, then writes
-- polling/DPI/button changes through the helper. Profiles are read-only on
-- the S9 because its vendor SDK has no direct profile-switch command.

local HELPER = noctalia.expandPath("~/.local/bin/eweadn-linux-control")

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

-- Shared control grid. Label and Apply stay fixed; the select sits in a
-- flexible, clipped slot so a narrow panel trims the select instead of
-- pushing the right-aligned Apply button outside the panel.
-- At the nominal size: 72 + 250 + 60 + three 8 px gaps = 406 px.
local GRID_LABEL_WIDTH = 72
local GRID_SELECT_WIDTH = 250
local GRID_APPLY_WIDTH = 60

local config = nil
local config_fetched_at = nil
local loading = false
local read_in_flight = false
local write_in_flight = false
local panel_open = false
local generation = 0
local refresh_queued = false
local refresh_after_write = false
local error_message = nil
local status_message = nil
local live_battery = nil

local draft_polling = nil
local draft_stage = nil
local draft_dpi = nil
local draft_buttons = {}
local draft_button_known = {}

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

local function controls_locked()
	return loading or write_in_flight
end

local function settings_available()
	if config == nil or config.settings_available == false then
		return false
	end
	return type(config.polling) == "table" and type(config.dpi) == "table"
end

local function stage_count()
	if config == nil or type(config.dpi) ~= "table" then
		return 0
	end
	local count = tonumber(config.dpi.stage_count) or 0
	return math.max(0, math.min(8, math.floor(count)))
end

local function current_stage_dpi(stage)
	if config == nil or type(config.dpi) ~= "table" or stage == nil then
		return nil
	end
	stage = tonumber(stage)
	if stage == nil then
		return nil
	end
	stage = math.floor(stage)
	local stages = config.dpi.stages
	if type(stages) ~= "table" then
		return nil
	end
	for _, entry in ipairs(stages) do
		if type(entry) == "table" and entry.index == stage then
			local dpi = tonumber(entry.dpi)
			if dpi ~= nil then
				return math.floor(dpi)
			end
		end
	end
	return nil
end

local function polling_index(hz)
	if hz == nil then
		return nil
	end
	for i, value in ipairs(POLL_VALUES) do
		if value == hz then
			return i
		end
	end
	return nil
end

local function is_known_action(action)
	for _, key in ipairs(ACTION_KEYS) do
		if key == action then
			return true
		end
	end
	return false
end

local function reset_drafts()
	draft_polling = nil
	draft_stage = nil
	draft_dpi = nil
	draft_buttons = {}
	draft_button_known = {}

	if config == nil then
		return
	end

	if type(config.polling) == "table" then
		draft_polling = polling_index(tonumber(config.polling.hz))
	end

	if type(config.dpi) == "table" then
		local stage = tonumber(config.dpi.current_stage)
		if stage ~= nil then
			stage = math.floor(stage)
		end
		local count = stage_count()
		if stage ~= nil and count > 0 and stage >= 1 and stage <= count then
			draft_stage = stage
			draft_dpi = current_stage_dpi(draft_stage)
		end
	end

	if type(config.buttons) == "table" then
		for index, key in ipairs(config.buttons) do
			if type(key) == "table" then
				draft_buttons[index] = key.action
				draft_button_known[index] = is_known_action(key.action)
			end
		end
	end
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

local function effective_battery()
	local snapshot = nil
	if config ~= nil and type(config.battery) == "table" then
		snapshot = config.battery
	end

	if type(live_battery) == "table" then
		local ts = tonumber(live_battery.ts)
		if ts ~= nil and (config_fetched_at == nil or ts > config_fetched_at) then
			return live_battery
		end
	end

	return snapshot
end

local function main_icon(percent, charging, has_error)
	if has_error then
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

local function profile_text()
	if config == nil or type(config.profile) ~= "table" then
		return "Profile unknown"
	end
	local current = math.max(1, math.floor(tonumber(config.profile.current) or 1))
	local maximum = math.floor(tonumber(config.profile.max) or 0)
	if maximum <= 0 then
		return "Profile unknown"
	end
	return string.format("Profile %d of %d", current, maximum)
end

local function display_button_name(button)
	local name = trim(button)
	if name == "" then
		return "Unknown"
	end
	return string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2)
end

local render

local function update_draft_after_apply(field)
	if type(field) ~= "table" then
		return
	end

	if field.kind == "polling" then
		local hz = nil
		if config ~= nil and type(config.polling) == "table" then
			hz = tonumber(config.polling.hz)
		end
		draft_polling = polling_index(hz) or polling_index(field.hz)
	elseif field.kind == "dpi" then
		local stage = tonumber(field.stage)
		if stage ~= nil then
			stage = math.floor(stage)
		end
		if config ~= nil and type(config.dpi) == "table" then
			local current = tonumber(config.dpi.current_stage)
			if current ~= nil then
				stage = math.floor(current)
			end
		end
		draft_stage = stage
		draft_dpi = current_stage_dpi(stage)
		if draft_dpi == nil then
			draft_dpi = tonumber(field.dpi)
			if draft_dpi ~= nil then
				draft_dpi = math.floor(draft_dpi)
			end
		end
	elseif field.kind == "button" then
		local action = field.action
		if config ~= nil and type(config.buttons) == "table" then
			local key = config.buttons[field.index]
			if type(key) == "table" then
				action = key.action
			end
		end
		draft_buttons[field.index] = action
		draft_button_known[field.index] = is_known_action(action)
	end
end

local function do_refresh()
	if not panel_open then
		return
	end

	if read_in_flight then
		refresh_queued = true
		loading = true
		render()
		return
	end

	if write_in_flight then
		refresh_after_write = true
		loading = true
		render()
		return
	end

	read_in_flight = true
	loading = true
	error_message = nil
	local request_generation = generation
	render()

	local accepted = noctalia.runAsync({ "python3", HELPER, "config", "--json" }, function(result)
		if request_generation ~= generation then
			read_in_flight = false
			if panel_open and refresh_queued then
				refresh_queued = false
				do_refresh()
			end
			return
		end

		read_in_flight = false
		loading = false

		local data = decode(result and result.stdout)
		if result and result.exitCode == 0 and data and data.ok == true then
			config = data
			config_fetched_at = noctalia.nowMs()
			reset_drafts()
			error_message = nil
		else
			error_message = result_error(data, result, "could not read mouse settings")
		end

		render()

		if refresh_queued then
			refresh_queued = false
			do_refresh()
		end
	end)

	if not accepted then
		if request_generation ~= generation then
			return
		end
		read_in_flight = false
		loading = false
		error_message = "could not start helper"
		render()
		if refresh_queued then
			refresh_queued = false
			do_refresh()
		end
	end
end

local function apply(args, label, field)
	if not panel_open or loading or write_in_flight then
		return
	end

	write_in_flight = true
	error_message = nil
	status_message = "Applying " .. label .. "…"
	local request_generation = generation
	render()

	local command = { "python3", HELPER }
	for _, value in ipairs(args) do
		table.insert(command, value)
	end
	table.insert(command, "--apply")
	table.insert(command, "--json")

	local accepted = noctalia.runAsync(command, function(result)
		-- A write must clear its physical in-flight flag even if the panel was
		-- closed or reopened while it ran. Stale results never touch the UI.
		write_in_flight = false
		local fresh = request_generation == generation

		if fresh then
			local data = decode(result and result.stdout)
			if result and result.exitCode == 0 and data and data.ok == true then
				status_message = label .. " applied"
				if type(data.after) == "table" then
					config = data.after
					config_fetched_at = noctalia.nowMs()
				end
				update_draft_after_apply(field)
				noctalia.state.set("refresh", (noctalia.state.get("refresh") or 0) + 1)
			else
				status_message = nil
				error_message = result_error(data, result, "write failed")
			end
			render()
		end

		if refresh_after_write then
			refresh_after_write = false
			if panel_open then
				do_refresh()
			end
		end
	end)

	if not accepted then
		write_in_flight = false
		if request_generation == generation then
			status_message = nil
			error_message = "could not start helper"
			render()
		end
		if refresh_after_write then
			refresh_after_write = false
			if panel_open then
				do_refresh()
			end
		end
	end
end

local function section(title, control)
	return ui.column({ gap = 8, align = "stretch" }, {
		ui.label({ text = title, fontWeight = "medium", color = "on_surface_variant" }),
		control,
	})
end

local function control_row(label, control, action, key)
	return ui.row({ key = key, gap = 8, align = "center" }, {
		ui.row({ width = GRID_LABEL_WIDTH, align = "center" }, {
			ui.label({ text = label, color = "on_surface_variant" }),
		}),
		ui.row({ flexGrow = 1, minWidth = 0, align = "center", clip = true }, {
			control,
		}),
		action,
	})
end

local function status_row(label, value, color)
	return ui.row({ align = "center", justify = "space_between", gap = 12 }, {
		ui.label({ text = label, color = "on_surface_variant", flexGrow = 1 }),
		ui.label({ text = value, color = color or "on_surface", fontWeight = "medium" }),
	})
end

local function build_polling()
	if config == nil or type(config.polling) ~= "table" then
		return section("Polling rate", ui.label({
			text = "Polling settings are unavailable.",
			color = "on_surface_variant",
		}))
	end

	local current_hz = tonumber(config.polling.hz)
	local current_known = polling_index(current_hz) ~= nil
	local selected = draft_polling or polling_index(current_hz)
	local selected_hz = selected and POLL_VALUES[selected] or nil
	local changed = selected_hz ~= nil and selected_hz ~= current_hz
	local locked = controls_locked()
	local option_offset = current_known and 0 or 1

	local options = {}
	if not current_known then
		table.insert(options, "Unknown rate")
	end
	for _, hz in ipairs(POLL_VALUES) do
		table.insert(options, string.format("%d Hz", hz))
	end

	local rows = {
		control_row(
			"Rate",
			ui.select({
				key = "polling-select",
				options = options,
				selectedIndex = selected and (selected - 1 + option_offset) or 0,
				enabled = not locked,
				onChange = function(value)
					local chosen = tonumber(value)
					if chosen == nil then
						return
					end
					chosen = math.floor(chosen)
					if option_offset == 1 and chosen == 0 then
						draft_polling = nil
						render()
						return
					end
					local pool_index = chosen + 1 - option_offset
					if pool_index >= 1 and pool_index <= #POLL_VALUES then
						draft_polling = pool_index
						render()
					end
				end,
				width = GRID_SELECT_WIDTH,
			}),
			ui.button({
				key = "polling-apply",
				text = "Apply",
				variant = "primary",
				enabled = changed and not locked,
				width = GRID_APPLY_WIDTH,
				onClick = function()
					if selected_hz == nil then
						return
					end
					apply(
						{ "set-polling", tostring(selected_hz) },
						string.format("%d Hz polling", selected_hz),
						{ kind = "polling", hz = selected_hz }
					)
				end,
			}),
			"polling-row"
		),
	}

	if not current_known then
		table.insert(rows, ui.label({
			text = "The current polling rate is unknown. Choose a rate to replace it.",
			color = "on_surface_variant",
			fontSize = 12,
		}))
	end

	return section("Polling rate", ui.column({ gap = 6, align = "stretch" }, rows))
end

local function build_dpi()
	local dpi = config ~= nil and type(config.dpi) == "table" and config.dpi or nil
	local stages = stage_count()
	local max_dpi = dpi and tonumber(dpi.max_dpi) or nil

	if dpi == nil or stages <= 0 or max_dpi == nil or max_dpi < 50 then
		return section("DPI", ui.label({
			text = "DPI settings are unavailable for this connection.",
			color = "on_surface_variant",
		}))
	end

	max_dpi = math.floor(max_dpi)

	local stage_options = {}
	local current_stage = tonumber(dpi.current_stage)
	if current_stage ~= nil then
		current_stage = math.floor(current_stage)
	end
	local current_stage_known = current_stage ~= nil and current_stage >= 1 and current_stage <= stages
	local option_offset = current_stage_known and 0 or 1
	if not current_stage_known then
		table.insert(stage_options, "Unknown stage")
	end
	for stage = 1, stages do
		table.insert(stage_options, string.format("Stage %d", stage))
	end

	local current_dpi = current_stage_dpi(current_stage)
	local selected_stage = draft_stage
	if selected_stage == nil or selected_stage < 1 or selected_stage > stages then
		selected_stage = current_stage_known and current_stage or nil
	end
	local selected_dpi = draft_dpi
	if selected_dpi == nil and draft_stage == nil then
		selected_dpi = current_stage_dpi(selected_stage)
	end
	local changed = selected_stage ~= nil
		and selected_dpi ~= nil
		and (selected_stage ~= current_stage or selected_dpi ~= current_dpi)
	local locked = controls_locked()
	local has_value = selected_dpi ~= nil

	local rows = {
		control_row(
			"Stage",
			ui.select({
				key = "dpi-stage-select",
				options = stage_options,
				selectedIndex = selected_stage and (selected_stage - 1 + option_offset) or 0,
				enabled = not locked,
				onChange = function(value)
					local chosen = tonumber(value)
					if chosen == nil then
						return
					end
					chosen = math.floor(chosen)
					if option_offset == 1 and chosen == 0 then
						draft_stage = nil
						draft_dpi = nil
						render()
						return
					end
					local stage = chosen + 1 - option_offset
					if stage >= 1 and stage <= stages then
						draft_stage = stage
						draft_dpi = current_stage_dpi(draft_stage)
					end
					render()
				end,
				width = GRID_SELECT_WIDTH,
			}),
			ui.button({
				key = "dpi-apply",
				text = "Apply",
				variant = "primary",
				enabled = changed and not locked,
				width = GRID_APPLY_WIDTH,
				onClick = function()
					if selected_stage == nil or selected_dpi == nil then
						return
					end
					apply({
						"set-dpi",
						tostring(selected_stage),
						tostring(selected_dpi),
						"--stage-count",
						tostring(stages),
					}, string.format("%d DPI", selected_dpi), {
						kind = "dpi",
						stage = selected_stage,
						dpi = selected_dpi,
					})
				end,
			}),
			"dpi-row"
		),
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.label({ text = "Value", color = "on_surface_variant" }),
			ui.label({
				text = has_value and string.format("%d DPI", selected_dpi) or "Unknown",
				fontWeight = "bold",
				color = has_value and "primary" or "on_surface_variant",
			}),
		}),
	}

	if has_value then
		table.insert(rows, ui.slider({
			key = "dpi-slider",
			min = 50,
			max = max_dpi,
			step = 50,
			value = math.max(50, math.min(max_dpi, selected_dpi)),
			enabled = not locked,
			onChange = function(value)
				draft_dpi = math.floor(tonumber(value) or 50)
				render()
			end,
		}))
	else
		table.insert(rows, ui.label({
			text = "The current DPI value is unknown. Choose a stage with a known value.",
			color = "on_surface_variant",
			fontSize = 12,
		}))
	end

	table.insert(rows, ui.row({ gap = 6, align = "center" }, {
		ui.button({
			key = "dpi-minus-500",
			text = "−500",
			variant = "ghost",
			controlSize = "sm",
			enabled = has_value and not locked,
			onClick = function()
				if draft_dpi == nil then
					return
				end
				draft_dpi = math.max(50, draft_dpi - 500)
				render()
			end,
		}),
		ui.button({
			key = "dpi-minus-50",
			text = "−50",
			variant = "ghost",
			controlSize = "sm",
			enabled = has_value and not locked,
			onClick = function()
				if draft_dpi == nil then
					return
				end
				draft_dpi = math.max(50, draft_dpi - 50)
				render()
			end,
		}),
		ui.button({
			key = "dpi-plus-50",
			text = "+50",
			variant = "ghost",
			controlSize = "sm",
			enabled = has_value and not locked,
			onClick = function()
				if draft_dpi == nil then
					return
				end
				draft_dpi = math.min(max_dpi, draft_dpi + 50)
				render()
			end,
		}),
		ui.button({
			key = "dpi-plus-500",
			text = "+500",
			variant = "ghost",
			controlSize = "sm",
			enabled = has_value and not locked,
			onClick = function()
				if draft_dpi == nil then
					return
				end
				draft_dpi = math.min(max_dpi, draft_dpi + 500)
				render()
			end,
		}),
		ui.spacer({ flexGrow = 1 }),
		ui.label({
			text = string.format("max %d", max_dpi),
			color = "on_surface_variant",
			fontSize = 12,
		}),
	}))

	return section("DPI", ui.column({ gap = 10, align = "stretch" }, rows))
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
		local suffix = action ~= nil and " (" .. tostring(action) .. ")" or ""
		table.insert(options, "Unknown" .. suffix)
		selected = #options
	end
	return options, selected, known
end

local function build_buttons()
	local buttons = config ~= nil and type(config.buttons) == "table" and config.buttons or nil
	local rows = {}

	if buttons == nil then
		return section("Mouse buttons", ui.label({
			text = "Button settings are unavailable for this connection.",
			color = "on_surface_variant",
		}))
	end

	for index, key in ipairs(buttons) do
		if type(key) == "table" then
			local draft = draft_buttons[index] or key.action
			local options, selected = button_options(draft)
			local known = draft_button_known[index] == true
			local changed = draft ~= key.action and known
			local locked = controls_locked()
			local button_name = display_button_name(key.button)

			table.insert(rows, control_row(
				button_name,
				ui.select({
					key = "button-select-" .. tostring(index),
					options = options,
					selectedIndex = selected - 1,
					enabled = not locked,
					onChange = function(value)
						local chosen = tonumber(value)
						if chosen == nil then
							return
						end
						chosen = math.floor(chosen) + 1
						if chosen >= 1 and chosen <= #ACTION_KEYS then
							draft_buttons[index] = ACTION_KEYS[chosen]
							draft_button_known[index] = true
						end
						render()
					end,
					width = GRID_SELECT_WIDTH,
				}),
				ui.button({
					key = "button-apply-" .. tostring(index),
					text = "Apply",
					variant = changed and "primary" or "secondary",
					enabled = changed and not locked,
					width = GRID_APPLY_WIDTH,
					onClick = function()
						if draft == nil then
							return
						end
						apply({
							"set-button",
							key.button,
							draft,
						}, button_name .. " button", {
							kind = "button",
							index = index,
							action = draft,
						})
					end,
				}),
				"button-row-" .. tostring(index)
			))
		end
	end

	if #rows == 0 then
		table.insert(rows, ui.label({
			text = "No button settings were reported.",
			color = "on_surface_variant",
		}))
	end

	return section("Mouse buttons", ui.column({ gap = 8, align = "stretch" }, rows))
end

local function build_status()
	local battery = effective_battery() or {}
	local charging = battery.charging == true
	local percent = tonumber(battery.percent)
	if percent ~= nil then
		percent = math.floor(percent)
	end
	local battery_error = trim(battery.error)
	local has_error = battery_error ~= ""
	local low = percent ~= nil and percent <= 15
	local color = "on_surface"
	if has_error then
		color = low and "error" or "secondary"
	elseif charging then
		color = "primary"
	elseif low then
		color = "error"
	end

	local battery_text
	if charging then
		battery_text = has_error and "Charging?" or "Charging"
	elseif percent ~= nil then
		battery_text = has_error and string.format("%d%%?", percent) or string.format("%d%%", percent)
	else
		battery_text = "Unknown"
	end

	local device = type(config.device) == "table" and config.device or {}
	local source = trim(battery.source)
	if source == "" then
		source = trim(device.source)
	end
	if source == "" then
		source = "Unknown connection"
	end

	local rows = {
		ui.row({ gap = 12, align = "center" }, {
			ui.glyph({
				name = main_icon(percent, charging, has_error),
				size = 26,
				color = color,
			}),
			ui.column({ gap = 2, flexGrow = 1 }, {
				ui.label({ text = "EWEADN S9", fontWeight = "bold", fontSize = 16 }),
				ui.label({ text = source, color = "on_surface_variant" }),
			}),
			ui.label({
				text = battery_text,
				fontSize = 18,
				fontWeight = "bold",
				color = color,
			}),
		}),
		ui.separator({ spacing = 2 }),
	}

	if config.settings_available ~= false then
		local polling_hz = nil
		if type(config.polling) == "table" then
			polling_hz = tonumber(config.polling.hz)
			if polling_hz ~= nil then
				polling_hz = math.floor(polling_hz)
			end
		end
		if polling_hz ~= nil then
			table.insert(rows, status_row("Polling", string.format("%d Hz", polling_hz)))
		else
			table.insert(rows, status_row("Polling", "Unknown", "on_surface_variant"))
		end

		local current_stage = nil
		if type(config.dpi) == "table" then
			current_stage = tonumber(config.dpi.current_stage)
		end
		local dpi = current_stage_dpi(current_stage)
		if dpi ~= nil then
			table.insert(rows, status_row("DPI", string.format("%d DPI", dpi)))
		else
			table.insert(rows, status_row("DPI", "Unknown", "on_surface_variant"))
		end
	end

	if type(config.profile) == "table" and (tonumber(config.profile.max) or 0) > 0 then
		table.insert(rows, status_row("Profile", profile_text(), "primary"))
	end

	return ui.column({ gap = 8, align = "stretch" }, rows)
end

render = function()
	local locked = controls_locked()
	local header = ui.row({ align = "center", justify = "space_between", gap = 8 }, {
		ui.label({ text = "EWEADN S9", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
		ui.button({
			key = "refresh",
			glyph = "refresh",
			tooltip = "Refresh",
			variant = "ghost",
			enabled = not locked,
			onClick = "refresh",
		}),
		ui.button({
			key = "close",
			glyph = "x",
			tooltip = "Close",
			variant = "ghost",
			onClick = "close_panel",
		}),
	})

	if config == nil then
		local content = { header }
		if loading or write_in_flight then
			table.insert(content, ui.label({
				text = write_in_flight and "Waiting for the current write to finish…" or "Reading mouse settings…",
				color = "on_surface_variant",
			}))
		else
			table.insert(content, ui.label({
				text = error_message or "Could not read mouse settings",
				color = "error",
			}))
			table.insert(content, ui.button({
				text = "Retry",
				variant = "primary",
				onClick = "refresh",
			}))
		end
		panel.render(ui.column({ gap = 16, flexGrow = 1 }, content))
		return
	end

	local content = {
		header,
		build_status(),
	}

	if error_message ~= nil then
		table.insert(content, ui.label({ text = error_message, color = "error" }))
	end
	if status_message ~= nil then
		table.insert(content, ui.label({ text = status_message, color = "primary" }))
	end

	table.insert(content, ui.separator({ spacing = 4 }))

	if not settings_available() then
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
			table.insert(content, section("Settings", ui.label({
				text = "Mouse settings were incomplete over this connection. Refresh to try again.",
				color = "on_surface_variant",
			})))
		end
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

noctalia.state.watch("battery", function(value)
	if not panel_open or type(value) ~= "table" then
		return
	end

	local ts = tonumber(value.ts)
	if ts ~= nil and (config_fetched_at == nil or ts > config_fetched_at) then
		live_battery = value
		render()
	end
end)

function onOpen(_context)
	generation = generation + 1
	panel_open = true
	loading = false
	refresh_queued = false
	refresh_after_write = false
	error_message = nil
	status_message = nil
	live_battery = noctalia.state.get("battery")

	-- Drop drafts from the previous visit before the first render. Reads keep
	-- all mutating controls disabled until this visit's snapshot arrives.
	if config ~= nil then
		reset_drafts()
	end

	do_refresh()
end

function onClose()
	generation = generation + 1
	panel_open = false
	loading = false
	refresh_queued = false
	refresh_after_write = false
	-- read_in_flight and write_in_flight stay set until their callbacks run.
end

function refresh()
	do_refresh()
end

function close_panel()
	panel.close()
end
