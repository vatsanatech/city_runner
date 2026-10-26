extends Node

var _game: Node
var _bridge: Object
var _opening := false

func _ready() -> void:
	if OS.get_cmdline_user_args().has("--prepare-bootstrap"):
		get_tree().quit(ProjectSettings.save_custom("res://project.binary"))
		return
	if Engine.has_singleton("CityRunnerHost"):
		_bridge = Engine.get_singleton("CityRunnerHost")
		_bridge.connect("open_requested", _open_game)
		_bridge.connect("close_requested", close_game)
		_open_game()
		return
	var common := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--native-common="):
			common = arg.trim_prefix("--native-common=")
	if not common.is_absolute_path() or not ProjectSettings.load_resource_pack(common):
		push_error("Verified shared game resources are required")
		get_tree().quit(1)
		return
	get_tree().change_scene_to_file.call_deferred("res://main.tscn")

func _open_game() -> void:
	if _opening:
		return
	_opening = true
	if is_instance_valid(_game):
		_game.queue_free()
		await get_tree().process_frame
	var launch: Dictionary = JSON.parse_string(_bridge.launchData())
	if not str(launch.common).is_absolute_path() or not ProjectSettings.load_resource_pack(str(launch.common)):
		_opening = false
		_bridge.failGame("Verified shared game resources are required")
		return
	_game = load("res://main.tscn").instantiate()
	add_child(_game)
	_opening = false

func close_game(error: String = "") -> void:
	if _opening:
		return
	_opening = true
	if is_instance_valid(_game):
		_game.queue_free()
		await get_tree().process_frame
	_game = null
	var world = load("res://scripts/city_world.gd")
	world.preloaded.clear()
	_opening = false
	if error.is_empty():
		_bridge.closeGame()
	else:
		_bridge.failGame(error)
