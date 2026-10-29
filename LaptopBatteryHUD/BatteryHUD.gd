extends Node
# Laptop Battery HUD for Road to Vostok (Godot 4.x, Metro Mod Loader autoload)
# v1.1.0 - settings (position, colors, size, ...) are editable in the Mod
# Configuration Menu (MCM). Without MCM the same settings live in
# user://MCM/LaptopBatteryHUD/config.ini and the defaults are used.

const MOD_ID := "LaptopBatteryHUD"
const FRIENDLY_NAME := "Laptop Battery HUD"
const DESCRIPTION := "Shows the laptop battery percentage on screen."
const FILE_PATH := "user://MCM/LaptopBatteryHUD"
const CONFIG_NAME := "config.ini"
const HELPERS_PATH := "res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres"

# --- live settings (filled by _apply_settings) ---
var _enabled: bool = true
var _toggle_key: int = KEY_F10
var _position: String = "top_right"
var _margin: Vector2 = Vector2(24, 18)
var _font_size: int = 18
var _opacity: float = 1.0
var _text_style: String = "short_bat"
var _interval: float = 30.0
var _low_percent: int = 30
var _critical_percent: int = 15
var _col_normal: Color = Color(0.85, 1.0, 0.85)
var _col_charging: Color = Color(0.45, 0.9, 1.0)
var _col_low: Color = Color(1.0, 0.75, 0.3)
var _col_critical: Color = Color(1.0, 0.3, 0.3)

# --- config plumbing ---
var _config: ConfigFile = null
var _def_by_key: Dictionary = {}   # key -> definition dictionary
var _section_by_key: Dictionary = {}   # key -> MCM section name
var _registered: bool = false
var _mcm_retries: int = 10
var _mcm_retry_timer: float = 0.0

# --- UI / battery ---
var _layer: CanvasLayer
var _label: Label
var _thread: Thread = null
var _elapsed: float = 0.0
var _has_battery: bool = false
var _percent: int = -1
var _status: int = 1   # Win32_Battery.BatteryStatus codes
var _last_raw: String = "<none>"
var _got_first_reading: bool = false
var _show_no_battery: bool = true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_config_file()
	_build_ui()
	_apply_settings()
	print("[LaptopBatteryHUD] ready: enabled=%s position=%s toggle=%s" % [_enabled, _position, OS.get_keycode_string(_toggle_key)])
	if not _try_register_mcm():
		_mcm_retries = 10
	else:
		_mcm_retries = 0
	_elapsed = _interval  # read the battery right away


func _exit_tree() -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null


func _process(delta: float) -> void:
	# MCM may be mounted after us (load order); retry for a few seconds.
	if not _registered and _mcm_retries > 0:
		_mcm_retry_timer += delta
		if _mcm_retry_timer >= 1.0:
			_mcm_retry_timer = 0.0
			_mcm_retries -= 1
			_try_register_mcm()

	if _thread != null:
		if not _thread.is_alive():
			var result = _thread.wait_to_finish()
			_thread = null
			_apply_battery(String(result))
		return
	_elapsed += delta
	if _elapsed >= _interval:
		_elapsed = 0.0
		_thread = Thread.new()
		_thread.start(_query)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == _toggle_key:
			_enabled = not _enabled
			_set_value("enabled", _enabled)
			_refresh()


# ------------------------------------------------------------- settings

func _make_defs() -> Array:
	var key_options := {}
	for k in ["F6", "F7", "F8", "F9", "F10", "F11", "F12", "Insert", "Home", "End", "PageUp", "PageDown"]:
		key_options[k] = k
	return [
		["Bool", "enabled", {
			"name": "Show battery HUD",
			"tooltip": "Show or hide the battery indicator (also toggled by the hotkey).",
			"default": true}],
		["Dropdown", "toggleKey", {
			"name": "Toggle hotkey",
			"tooltip": "Key that shows/hides the indicator.",
			"default": "F10",
			"options": key_options}],
		["Dropdown", "position", {
			"name": "Position",
			"tooltip": "Screen corner for the indicator.",
			"default": "top_right",
			"options": {
				"top_left": "Top left",
				"top_right": "Top right",
				"bottom_left": "Bottom left",
				"bottom_right": "Bottom right"}}],
		["Int", "marginX", {
			"name": "Horizontal margin (px)",
			"tooltip": "Distance from the left/right screen edge.",
			"default": 24, "minRange": 0, "maxRange": 800, "step": 1}],
		["Int", "marginY", {
			"name": "Vertical margin (px)",
			"tooltip": "Distance from the top/bottom screen edge.",
			"default": 18, "minRange": 0, "maxRange": 800, "step": 1}],
		["Int", "fontSize", {
			"name": "Text size",
			"tooltip": "Font size of the indicator.",
			"default": 18, "minRange": 8, "maxRange": 96, "step": 1}],
		["Float", "opacity", {
			"name": "Opacity",
			"tooltip": "1.0 = fully visible.",
			"default": 1.0, "minRange": 0.2, "maxRange": 1.0, "step": 0.05}],
		["Dropdown", "textStyle", {
			"name": "Text style",
			"tooltip": "How the text is written.",
			"default": "short_bat",
			"options": {
				"short_bat": "BAT 85%",
				"long_battery": "Battery 85%",
				"percent_only": "85%"}}],
		["Bool", "showNoBattery", {
			"name": "Show 'BAT N/A' when no battery is found",
			"tooltip": "Turn this off on desktop PCs to hide the indicator completely.",
			"default": true}],
		["Int", "updateSeconds", {
			"name": "Update interval (seconds)",
			"tooltip": "How often the battery is read.",
			"default": 30, "minRange": 5, "maxRange": 300, "step": 5}],
		["Int", "lowPercent", {
			"name": "Low battery at (%)",
			"tooltip": "At or below this level the low color is used.",
			"default": 30, "minRange": 1, "maxRange": 99, "step": 1}],
		["Int", "criticalPercent", {
			"name": "Critical battery at (%)",
			"tooltip": "At or below this level the critical color is used.",
			"default": 15, "minRange": 1, "maxRange": 99, "step": 1}],
		["Color", "colorNormal", {
			"name": "Color: normal",
			"tooltip": "Color while discharging above the low level.",
			"default": Color(0.85, 1.0, 0.85)}],
		["Color", "colorCharging", {
			"name": "Color: charging",
			"tooltip": "Color while plugged in / charging.",
			"default": Color(0.45, 0.9, 1.0)}],
		["Color", "colorLow", {
			"name": "Color: low",
			"tooltip": "Color at or below the low level.",
			"default": Color(1.0, 0.75, 0.3)}],
		["Color", "colorCritical", {
			"name": "Color: critical",
			"tooltip": "Color at or below the critical level.",
			"default": Color(1.0, 0.3, 0.3)}],
	]


func _build_defs_config() -> ConfigFile:
	var cfg := ConfigFile.new()
	for entry in _make_defs():
		var section: String = entry[0]
		var key: String = entry[1]
		var d: Dictionary = (entry[2] as Dictionary).duplicate(true)
		d["value"] = d["default"]
		cfg.set_value(section, key, d)
		_def_by_key[key] = d
		_section_by_key[key] = section
	return cfg


func _load_config_file() -> void:
	var fresh := _build_defs_config()
	var path := FILE_PATH + "/" + CONFIG_NAME
	if not FileAccess.file_exists(path):
		DirAccess.make_dir_recursive_absolute(FILE_PATH)
		fresh.save(path)
	_config = ConfigFile.new()
	if _config.load(path) != OK:
		_config = fresh


func _cfg(key: String) -> Variant:
	var section: String = _section_by_key.get(key, "")
	if _config != null and section != "" and _config.has_section_key(section, key):
		var d = _config.get_value(section, key)
		if d is Dictionary:
			if d.has("value"):
				return d["value"]
			if d.has("default"):
				return d["default"]
	var def: Dictionary = _def_by_key.get(key, {})
	return def.get("default")


func _set_value(key: String, value: Variant) -> void:
	if _config == null or not _section_by_key.has(key):
		return
	var section: String = _section_by_key[key]
	var d: Dictionary = {}
	if _config.has_section_key(section, key):
		var cur = _config.get_value(section, key)
		if cur is Dictionary:
			d = cur.duplicate(true)
	if d.is_empty():
		d = (_def_by_key[key] as Dictionary).duplicate(true)
	d["value"] = value
	_config.set_value(section, key, d)
	_config.save(FILE_PATH + "/" + CONFIG_NAME)


func _color_cfg(key: String, fallback: Color) -> Color:
	var c = _cfg(key)
	if c is Color:
		return c
	return fallback


func _apply_settings() -> void:
	_enabled = bool(_cfg("enabled"))
	var kc := OS.find_keycode_from_string(str(_cfg("toggleKey")))
	_toggle_key = kc if kc != KEY_NONE else KEY_F10
	_position = str(_cfg("position"))
	_margin = Vector2(float(_cfg("marginX")), float(_cfg("marginY")))
	_font_size = clampi(int(_cfg("fontSize")), 8, 96)
	_opacity = clampf(float(_cfg("opacity")), 0.2, 1.0)
	_text_style = str(_cfg("textStyle"))
	_show_no_battery = bool(_cfg("showNoBattery"))
	_interval = clampf(float(_cfg("updateSeconds")), 5.0, 600.0)
	_low_percent = int(_cfg("lowPercent"))
	_critical_percent = int(_cfg("criticalPercent"))
	_col_normal = _color_cfg("colorNormal", _col_normal)
	_col_charging = _color_cfg("colorCharging", _col_charging)
	_col_low = _color_cfg("colorLow", _col_low)
	_col_critical = _color_cfg("colorCritical", _col_critical)
	if _label != null:
		_label.add_theme_font_size_override("font_size", _font_size)
		_place()
		_refresh()


# ------------------------------------------------------------------ MCM

func _try_register_mcm() -> bool:
	if _registered:
		return true
	if not ResourceLoader.exists(HELPERS_PATH):
		return false
	var helpers = load(HELPERS_PATH)
	if helpers == null:
		return false
	var path := FILE_PATH + "/" + CONFIG_NAME
	# Let MCM merge settings that were added in newer versions of this mod.
	if helpers.has_method("CheckConfigurationHasUpdated"):
		helpers.CheckConfigurationHasUpdated(MOD_ID, _build_defs_config(), path)
		var reloaded := ConfigFile.new()
		if reloaded.load(path) == OK:
			_config = reloaded
			_apply_settings()
	helpers.RegisterConfiguration(
		MOD_ID,
		FRIENDLY_NAME,
		FILE_PATH,
		DESCRIPTION,
		{CONFIG_NAME: Callable(self, "_on_mcm_saved")}
	)
	_registered = true
	return true


func _on_mcm_saved(config: ConfigFile) -> void:
	# MCM can hand us another mod's config file; ignore anything that is not ours.
	if config == null or not config.has_section_key("Dropdown", "toggleKey") \
			or not config.has_section_key("Int", "fontSize"):
		print("[LaptopBatteryHUD] ignored a foreign MCM save callback")
		return
	_config = config
	_apply_settings()
	_elapsed = _interval  # re-read the battery soon


# ------------------------------------------------------------------- UI

func _build_ui() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 128
	_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_layer)

	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", _font_size)
	_label.add_theme_constant_override("outline_size", 5)
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_layer.add_child(_label)
	_place()
	_refresh()


func _place() -> void:
	_label.offset_left = 0.0
	_label.offset_top = 0.0
	_label.offset_right = 0.0
	_label.offset_bottom = 0.0
	match _position:
		"top_left":
			_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
			_label.offset_left = _margin.x
			_label.offset_top = _margin.y
			_label.grow_horizontal = Control.GROW_DIRECTION_END
			_label.grow_vertical = Control.GROW_DIRECTION_END
			_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		"bottom_left":
			_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
			_label.offset_left = _margin.x
			_label.offset_bottom = -_margin.y
			_label.grow_horizontal = Control.GROW_DIRECTION_END
			_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
			_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		"bottom_right":
			_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
			_label.offset_right = -_margin.x
			_label.offset_bottom = -_margin.y
			_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
			_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
			_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_:
			_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
			_label.offset_right = -_margin.x
			_label.offset_top = _margin.y
			_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
			_label.grow_vertical = Control.GROW_DIRECTION_END
			_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT


func _refresh() -> void:
	if _label == null:
		return
	if not _enabled:
		_label.visible = false
		return
	if not _has_battery or _percent < 0:
		# Before the first reading arrives show nothing; afterwards optionally
		# tell the player that no battery was found (helps troubleshooting).
		if _got_first_reading and _show_no_battery:
			_label.text = "BAT N/A"
			_label.add_theme_color_override("font_color", _col_normal)
			_label.modulate = Color(1, 1, 1, _opacity)
			_label.visible = true
		else:
			_label.visible = false
		return
	var charging: bool = _status in [6, 7, 8, 9]
	var prefix := ""
	match _text_style:
		"long_battery":
			prefix = "Battery "
		"percent_only":
			prefix = ""
		_:
			prefix = "BAT "
	var text := "%s%d%%" % [prefix, _percent]
	if charging:
		text += " +"
	elif _status == 3:
		text += " FULL"
	elif _status == 2:
		text += " AC"
	_label.text = text

	var col := _col_normal
	if charging:
		col = _col_charging
	elif _percent <= _critical_percent:
		col = _col_critical
	elif _percent <= _low_percent:
		col = _col_low
	_label.add_theme_color_override("font_color", col)
	_label.modulate = Color(1, 1, 1, _opacity)
	_label.visible = true


# ---------------------------------------------------------- battery query

# Runs in a worker thread. Returns "percent,status" or "" when unavailable.
func _query() -> String:
	var os_name := OS.get_name()
	if os_name == "Windows":
		return _query_windows()
	if os_name == "Linux":
		return _query_linux()
	return ""


func _query_windows() -> String:
	var out: Array = []
	# One plain, human-readable read-only query. Only single quotes are used,
	# so nothing needs escaping, and nothing is encoded or hidden.
	var script := "$b = Get-CimInstance Win32_Battery | Select-Object -First 1; if ($b) { Write-Output (([string]$b.EstimatedChargeRemaining) + ',' + ([string]$b.BatteryStatus)) }"
	var code := OS.execute("powershell.exe", ["-NoProfile", "-Command", script], out, false, false)
	if code == 0 and out.size() > 0:
		var line := String(out[0]).strip_edges()
		if line.contains(","):
			return line
	return ""


func _query_linux() -> String:
	var dir := DirAccess.open("/sys/class/power_supply")
	if dir == null:
		return ""
	for entry in dir.get_directories():
		if not entry.begins_with("BAT"):
			continue
		var base := "/sys/class/power_supply/%s/" % entry
		var cap := FileAccess.get_file_as_string(base + "capacity").strip_edges()
		if not cap.is_valid_int():
			continue
		var st := FileAccess.get_file_as_string(base + "status").strip_edges()
		var code := 2
		match st:
			"Charging":
				code = 6
			"Full":
				code = 3
			"Discharging":
				code = 1
		return "%s,%d" % [cap, code]
	return ""


func _apply_battery(result: String) -> void:
	if result != _last_raw:
		_last_raw = result
		print("[LaptopBatteryHUD] battery reading: '%s' (os=%s)" % [result, OS.get_name()])
	_got_first_reading = true
	var parts := result.split(",")
	if parts.size() < 1 or not parts[0].is_valid_int():
		_has_battery = false
		_percent = -1
	else:
		_has_battery = true
		_percent = clampi(int(parts[0]), 0, 100)
		_status = int(parts[1]) if parts.size() > 1 and parts[1].is_valid_int() else 1
	_refresh()
