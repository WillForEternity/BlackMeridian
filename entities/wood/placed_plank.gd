class_name PlacedPlank
extends StaticBody3D

const LENGTH: float = 2.6
const THICKNESS: float = 0.08
const WIDTH: float = 0.45

func _ready() -> void:
	collision_layer = 1
	collision_mask = 0
	add_to_group("placed_plank")
	_build()
	_register_occluder()

func _exit_tree() -> void:
	var terrain := get_tree().current_scene.get_node_or_null("Terrain")
	if terrain != null and terrain.has_method("remove_grass_occluder"):
		terrain.remove_grass_occluder(get_instance_id())

func _build() -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(LENGTH, THICKNESS, WIDTH)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.62, 0.46, 0.28)
	mat.roughness = 0.85
	bm.material = mat
	mi.mesh = bm
	add_child(mi)

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = bm.size
	col.shape = box
	add_child(col)

func _register_occluder() -> void:
	var terrain := get_tree().current_scene.get_node_or_null("Terrain")
	if terrain != null and terrain.has_method("add_grass_occluder"):
		var xz := Vector2(global_position.x, global_position.z)
		terrain.add_grass_occluder(get_instance_id(), xz, LENGTH * 0.5)
