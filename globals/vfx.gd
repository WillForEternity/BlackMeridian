extends Node

func _attach(node: Node) -> void:
	get_tree().current_scene.add_child(node)

func _spawn_emissive_sphere(at: Vector3, radius: float, segs: int, rings: int, tint: Color, energy: float) -> Array:
	# Returns [MeshInstance3D, StandardMaterial3D] — caller animates them.
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = segs
	sm.rings = rings
	mi.mesh = sm
	var mat := flat_emissive_mat(tint, energy)
	mi.set_surface_override_material(0, mat)
	_attach(mi)
	mi.global_position = at
	return [mi, mat]

func flat_emissive_mat(tint: Color, energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = energy
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat

func impact_burst(at: Vector3, scale_mul: float, tint: Color) -> void:
	var pair := _spawn_emissive_sphere(at, 0.18, 12, 6, tint, 9.0)
	var mi: MeshInstance3D = pair[0]
	var mat: StandardMaterial3D = pair[1]
	mi.scale = Vector3.ONE * 0.25
	var light := OmniLight3D.new()
	light.light_color = tint
	light.light_energy = 5.5 * scale_mul
	light.omni_range = 4.0 * scale_mul
	mi.add_child(light)
	var life := 0.38
	var t := mi.create_tween()
	t.set_parallel(true)
	t.tween_property(mi, "scale", Vector3.ONE * 1.6 * scale_mul, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_method(func(v: float):
		mat.emission_energy_multiplier = v * 9.0
		mat.albedo_color.a = v
		light.light_energy = v * 5.5 * scale_mul
	, 1.0, 0.0, life)
	get_tree().create_timer(life + 0.05).timeout.connect(mi.queue_free)

func muzzle_flash(at: Vector3, scale_mul: float, tint: Color) -> void:
	var pair := _spawn_emissive_sphere(at, 0.16, 10, 5, tint, 10.0)
	var mi: MeshInstance3D = pair[0]
	var mat: StandardMaterial3D = pair[1]
	mi.scale = Vector3.ONE * 0.4 * scale_mul
	var light := OmniLight3D.new()
	light.light_color = tint
	light.light_energy = 6.0 * scale_mul
	light.omni_range = 3.5 * scale_mul
	mi.add_child(light)
	var t := mi.create_tween()
	t.set_parallel(true)
	t.tween_property(mi, "scale", Vector3.ONE * 1.3 * scale_mul, 0.1).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_method(func(v: float):
		mat.emission_energy_multiplier = v * 10.0
		mat.albedo_color.a = v
		light.light_energy = v * 6.0 * scale_mul
	, 1.0, 0.0, 0.14)
	get_tree().create_timer(0.18).timeout.connect(mi.queue_free)

func muzzle_flash_cross(at: Vector3, fire_dir: Vector3, scale_mul: float, tint: Color) -> void:
	var parent := Node3D.new()
	_attach(parent)
	parent.global_position = at
	var up := Vector3.UP
	if absf(fire_dir.dot(up)) > 0.99:
		up = Vector3.FORWARD
	parent.look_at(parent.global_position + fire_dir, up)

	var tongue := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.18, 0.18, 0.55)
	tongue.mesh = box
	var mat_t := flat_emissive_mat(tint, 12.0)
	tongue.set_surface_override_material(0, mat_t)
	parent.add_child(tongue)
	tongue.position = Vector3(0, 0, -0.28)
	tongue.scale = Vector3(0.4 * scale_mul, 0.4 * scale_mul, 0.4 * scale_mul)

	for i in 2:
		var flare := MeshInstance3D.new()
		var pl := PlaneMesh.new()
		pl.size = Vector2(0.6, 0.18)
		flare.mesh = pl
		var mat_f := flat_emissive_mat(tint, 10.0)
		flare.set_surface_override_material(0, mat_f)
		parent.add_child(flare)
		flare.position = Vector3(0, 0, -0.05)
		if i == 0:
			flare.rotation = Vector3(deg_to_rad(90.0), 0, 0)
		else:
			flare.rotation = Vector3(deg_to_rad(90.0), 0, deg_to_rad(90.0))
		flare.scale = Vector3(scale_mul, 1, scale_mul)

	var light := OmniLight3D.new()
	light.light_color = tint
	light.light_energy = 7.5 * scale_mul
	light.omni_range = 4.5 * scale_mul
	parent.add_child(light)

	var t := parent.create_tween()
	t.set_parallel(true)
	t.tween_property(parent, "scale", parent.scale * 1.4, 0.09).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_method(func(v: float):
		mat_t.emission_energy_multiplier = v * 12.0
		mat_t.albedo_color.a = v
		light.light_energy = v * 7.5 * scale_mul
	, 1.0, 0.0, 0.13)
	get_tree().create_timer(0.16).timeout.connect(parent.queue_free)

func brass_puff(at: Vector3, fire_dir: Vector3) -> void:
	var right := fire_dir.cross(Vector3.UP).normalized()
	if right.length() < 0.1:
		right = Vector3.RIGHT
	var puff := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.06
	sm.height = 0.12
	sm.radial_segments = 8
	sm.rings = 4
	puff.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.7, 0.7, 0.78, 0.5)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	puff.set_surface_override_material(0, mat)
	_attach(puff)
	puff.global_position = at + right * 0.08 + Vector3(0, 0.05, 0)
	var t := puff.create_tween()
	t.set_parallel(true)
	t.tween_property(puff, "global_position", puff.global_position + right * 0.25 + Vector3(0, 0.3, 0), 0.5)
	t.tween_property(puff, "scale", Vector3.ONE * 2.0, 0.5)
	t.tween_method(func(v: float):
		mat.albedo_color.a = v * 0.5
	, 1.0, 0.0, 0.5)
	get_tree().create_timer(0.55).timeout.connect(puff.queue_free)

func tracer_beam(from: Vector3, to: Vector3, charge01: float) -> void:
	var diff := to - from
	var dist := diff.length()
	if dist < 0.05:
		return
	var dir := diff.normalized()
	var tint := Color(0.4, 0.95, 1, 1)
	var core_tint := Color(0.95, 0.99, 1.0, 1)

	_beam_layer(from, to, lerpf(0.025, 0.05, charge01), core_tint, 18.0, 0.55)
	_beam_layer(from, to, lerpf(0.08, 0.18, charge01), tint, 9.0, 0.55)
	_beam_layer(from, to, lerpf(0.16, 0.32, charge01), tint, 3.5, 0.45)

	_helix_wrap(from, dir, dist, charge01, tint)

	var flash_light := OmniLight3D.new()
	flash_light.light_color = tint
	flash_light.light_energy = 8.0 + charge01 * 6.0
	flash_light.omni_range = 5.0 + charge01 * 4.0
	_attach(flash_light)
	flash_light.global_position = from + dir * (dist * 0.5)
	var ft := flash_light.create_tween()
	ft.tween_property(flash_light, "light_energy", 0.0, 0.45)
	get_tree().create_timer(0.5).timeout.connect(flash_light.queue_free)

func _beam_layer(from: Vector3, to: Vector3, thickness: float, tint: Color, energy: float, life: float) -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(thickness, thickness, 1.0)
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = energy
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.set_surface_override_material(0, mat)
	_attach(mi)
	var diff := to - from
	var dist := diff.length()
	mi.global_position = from + diff * 0.5
	var up := Vector3.UP
	if absf(diff.normalized().dot(up)) > 0.99:
		up = Vector3.FORWARD
	mi.look_at(to, up)
	mi.scale = Vector3(1, 1, dist)
	var t := mi.create_tween()
	t.set_parallel(true)
	t.tween_property(mi, "scale", Vector3(0.2, 0.2, dist), life)
	t.tween_method(func(v: float):
		mat.emission_energy_multiplier = v * energy
		mat.albedo_color.a = v
	, 1.0, 0.0, life)
	get_tree().create_timer(life + 0.05).timeout.connect(mi.queue_free)

func _helix_wrap(from: Vector3, dir: Vector3, dist: float, charge01: float, tint: Color) -> void:
	var mi := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mi.mesh = im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = tint
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = 5.0 + 3.0 * charge01
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_attach(mi)

	var up := Vector3.UP
	if absf(dir.dot(up)) > 0.99:
		up = Vector3.FORWARD
	var side := dir.cross(up).normalized()
	var up2 := side.cross(dir).normalized()
	var radius: float = lerpf(0.12, 0.22, charge01)
	var turns: float = 4.5
	var steps: int = 36

	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		var ang: float = t * turns * TAU
		var p: Vector3 = from + dir * (dist * t) + side * cos(ang) * radius + up2 * sin(ang) * radius
		im.surface_add_vertex(p)
	im.surface_end()

	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		var ang: float = -t * turns * TAU
		var p: Vector3 = from + dir * (dist * t) + side * cos(ang) * radius + up2 * sin(ang) * radius
		im.surface_add_vertex(p)
	im.surface_end()

	var life := 0.42
	var tw := mi.create_tween()
	tw.tween_method(func(v: float):
		mat.albedo_color.a = v
		mat.emission_energy_multiplier = v * (5.0 + 3.0 * charge01)
	, 1.0, 0.0, life)
	get_tree().create_timer(life + 0.05).timeout.connect(mi.queue_free)

func arc_lightning(a: Vector3, b: Vector3, charge01: float) -> void:
	var mi := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mi.mesh = im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var tint := Color(0.7, 1.0, 1.0, 1)
	mat.albedo_color = tint
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = 14.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_attach(mi)

	var dir := b - a
	var dlen := dir.length()
	if dlen < 0.001:
		mi.queue_free()
		return
	var fwd := dir.normalized()
	var up := Vector3.UP
	if absf(fwd.dot(up)) > 0.99:
		up = Vector3.FORWARD
	var side := fwd.cross(up).normalized()
	var up2 := side.cross(fwd).normalized()

	var jitter := lerpf(0.012, 0.03, charge01)
	var steps := 9
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		var off_s: float = 0.0
		var off_u: float = 0.0
		if i != 0 and i != steps:
			off_s = randf_range(-jitter, jitter)
			off_u = randf_range(-jitter, jitter)
		var p: Vector3 = a + dir * t + side * off_s + up2 * off_u
		im.surface_add_vertex(p)
	im.surface_end()

	var life := 0.05
	var tw := mi.create_tween()
	tw.tween_method(func(v: float):
		mat.albedo_color.a = v
	, 1.0, 0.0, life)
	get_tree().create_timer(life + 0.02).timeout.connect(mi.queue_free)
