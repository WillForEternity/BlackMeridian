extends Node

# NOTE: These effects are intentionally built in code (meshes + tweens +
# ImmediateMesh) rather than as GPUParticles3D scenes or shaders. I'll learn
# the renderer properly later — for now I just wanted Claude to drop in some
# placeholder VFX so the weapons feel alive. Plan to migrate to
# scene + shader + pool based effects later. See chat for full refactor plan.

func _attach(node: Node) -> void:
	get_tree().current_scene.add_child(node)

# Returns an up vector safe to feed look_at() — falls back to FORWARD when
# `dir` is nearly parallel to world UP (otherwise look_at()'s basis degenerates).
func safe_up(dir: Vector3) -> Vector3:
	if absf(dir.dot(Vector3.UP)) > 0.99:
		return Vector3.FORWARD
	return Vector3.UP

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

# Scattering spark burst. Emits N small emissive streaks from `at` along a
# cone around `dir`. Streaks fly outward, droop under fake gravity, and fade.
# A brief OmniLight tints the surroundings so the burst still reads as a flash
# at a glance without the chunky sphere/cross primitives of the older effects.
func sparks(at: Vector3, dir: Vector3, scale_mul: float, tint: Color, count: int = 14) -> void:
	var d := dir.normalized() if dir.length_squared() > 1e-6 else Vector3.UP
	var up := safe_up(d)
	var right := d.cross(up).normalized()
	if right.length() < 0.1:
		right = Vector3.RIGHT
	up = right.cross(d).normalized()
	var light := OmniLight3D.new()
	light.light_color = tint
	light.light_energy = 4.5 * scale_mul
	light.omni_range = 3.0 * scale_mul
	_attach(light)
	light.global_position = at
	var lt := light.create_tween()
	lt.tween_property(light, "light_energy", 0.0, 0.16)
	get_tree().create_timer(0.2).timeout.connect(light.queue_free)
	for i in count:
		var theta: float = randf() * TAU
		var spread: float = lerpf(0.1, 1.3, randf() * randf())
		var lateral: Vector3 = (right * cos(theta) + up * sin(theta)) * sin(spread)
		var forward: Vector3 = d * cos(spread)
		var v: Vector3 = (forward + lateral).normalized() * lerpf(3.5, 8.5, randf()) * scale_mul
		_spawn_spark(at, v, tint, scale_mul)

func _spawn_spark(at: Vector3, vel: Vector3, tint: Color, scale_mul: float) -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.014, 0.014, 0.22)
	mi.mesh = box
	var mat := flat_emissive_mat(tint, 14.0)
	mi.set_surface_override_material(0, mat)
	_attach(mi)
	mi.global_position = at
	var ndir: Vector3 = vel.normalized()
	mi.look_at(at + ndir, safe_up(ndir))
	mi.scale = Vector3(1.0, 1.0, 0.55 * scale_mul)
	var life: float = lerpf(0.22, 0.42, randf())
	var gravity: float = -9.0
	var start: Vector3 = at
	var tw := mi.create_tween()
	tw.set_parallel(true)
	tw.tween_method(func(t: float) -> void:
		mi.global_position = start + vel * t + Vector3(0.0, 0.5 * gravity * t * t, 0.0)
	, 0.0, life, life)
	tw.tween_property(mi, "scale", Vector3(1.0, 1.0, 1.6 * scale_mul), life * 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_method(func(a: float) -> void:
		mat.emission_energy_multiplier = a * 14.0
		mat.albedo_color.a = a
	, 1.0, 0.0, life).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	get_tree().create_timer(life + 0.05).timeout.connect(mi.queue_free)

func muzzle_flash_cross(at: Vector3, fire_dir: Vector3, scale_mul: float, tint: Color) -> void:
	var parent := Node3D.new()
	_attach(parent)
	parent.global_position = at
	parent.look_at(parent.global_position + fire_dir, safe_up(fire_dir))

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
	mi.look_at(to, safe_up(diff.normalized()))
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

	var side := dir.cross(safe_up(dir)).normalized()
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

func swirl_pillar(at: Vector3, radius: float, duration: float, tint: Color) -> void:
	var mi := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mi.mesh = im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = tint
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = 7.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_attach(mi)
	mi.global_position = at

	var height: float = 3.6
	var turns: float = 3.0
	var steps: int = 56

	var light := OmniLight3D.new()
	light.light_color = tint
	light.light_energy = 6.0
	light.omni_range = radius * 1.4
	mi.add_child(light)

	var t := mi.create_tween()
	t.set_parallel(true)
	t.tween_method(func(phase: float):
		im.clear_surfaces()
		var r: float = radius * lerpf(0.25, 1.0, clampf(phase * 1.4, 0.0, 1.0))
		for strand in 3:
			var off: float = float(strand) * TAU / 3.0
			im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
			for i in range(steps + 1):
				var u: float = float(i) / float(steps)
				var ang: float = u * turns * TAU + phase * TAU * 2.0 + off
				var y: float = u * height
				var p: Vector3 = Vector3(cos(ang) * r, y, sin(ang) * r)
				im.surface_add_vertex(p)
			im.surface_end()
	, 0.0, 1.0, duration)
	t.tween_method(func(v: float):
		mat.albedo_color.a = v
		mat.emission_energy_multiplier = v * 7.0
		light.light_energy = v * 6.0
	, 1.0, 0.0, duration)
	get_tree().create_timer(duration + 0.1).timeout.connect(mi.queue_free)

func _emp_arc(a: Vector3, b: Vector3, tint: Color) -> void:
	# Cleaner arc than arc_lightning: additive blend, soft falloff, subtle jitter.
	# Reads as a wisp of EM discharge instead of a scribbled line.
	var dir := b - a
	var dlen := dir.length()
	if dlen < 0.001:
		return
	var fwd := dir.normalized()
	var side := fwd.cross(safe_up(fwd)).normalized()
	var up2 := side.cross(fwd).normalized()

	var mi := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mi.mesh = im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = tint
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = 5.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_attach(mi)

	# Subtle sinusoidal sway + small noise → wisp, not zigzag scribble.
	var steps := 14
	var jitter: float = dlen * 0.02
	var sway: float = dlen * 0.06
	var phase: float = randf() * TAU
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		var envelope: float = sin(t * PI)
		var s_off: float = sin(t * PI * 2.0 + phase) * sway * envelope + randf_range(-jitter, jitter) * envelope
		var u_off: float = cos(t * PI * 2.0 + phase) * sway * envelope + randf_range(-jitter, jitter) * envelope
		var p: Vector3 = a + dir * t + side * s_off + up2 * u_off
		im.surface_add_vertex(p)
	im.surface_end()

	var life := 0.16
	var tw := mi.create_tween()
	tw.tween_method(func(v: float):
		mat.albedo_color.a = v
		mat.emission_energy_multiplier = v * 5.0
	, 1.0, 0.0, life)
	get_tree().create_timer(life + 0.02).timeout.connect(mi.queue_free)

func _emp_arch_bolt(from: Vector3, to: Vector3, tint: Color) -> void:
	# Rainbow-arched 3D bolt: a horizontal sweep from `from` to `to` with a
	# sinusoidal vertical arch (peak at midpoint) plus per-segment jitter for
	# chaos. Additive blend so overlapping bolts pile into glow, not paint.
	var dir := to - from
	var dist := dir.length()
	if dist < 0.001:
		return

	var mi := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mi.mesh = im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = tint
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = 6.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_attach(mi)

	# Arch height scales with horizontal span — wider arcs go taller, like a
	# rainbow. Side-axis perpendicular to the ground sweep gives jitter room.
	var flat := Vector3(dir.x, 0, dir.z)
	var flat_len: float = flat.length()
	var fwd: Vector3 = flat.normalized() if flat_len > 0.01 else Vector3.FORWARD
	var side: Vector3 = fwd.cross(Vector3.UP).normalized()
	if side.length() < 0.5:
		side = Vector3.RIGHT
	var arch_height: float = lerpf(0.6, 2.2, clampf(dist / 9.0, 0.0, 1.0))
	var jitter: float = 0.18

	var steps: int = 14
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		var base: Vector3 = from.lerp(to, t)
		var lift: float = sin(t * PI) * arch_height
		var envelope: float = sin(t * PI)
		var side_j: float = randf_range(-jitter, jitter) * envelope
		var up_j: float = randf_range(-jitter * 0.5, jitter * 0.5) * envelope
		var p: Vector3 = base + Vector3(0, lift + up_j, 0) + side * side_j
		im.surface_add_vertex(p)
	im.surface_end()

	var life: float = 0.22
	var tw := mi.create_tween()
	tw.tween_method(func(v: float):
		mat.albedo_color.a = v
		mat.emission_energy_multiplier = v * 6.0
	, 1.0, 0.0, life)
	get_tree().create_timer(life + 0.02).timeout.connect(mi.queue_free)

func emp_ground_wave(origin: Vector3, max_radius: float, duration: float, tint: Color) -> void:
	# Flat expanding ring on the ground at `origin` — an annulus rendered with
	# a triangle strip whose inner/outer radii both grow each frame, so it reads
	# as a single shockwave traveling outward across the floor. Additive blend
	# keeps it readable as light rather than paint. Crackles are scheduled
	# separately along the wavefront so the EM discharge sweeps with the ring.
	var mi := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mi.mesh = im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = tint
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = 5.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_attach(mi)
	mi.global_position = origin + Vector3(0, 0.04, 0)

	var light := OmniLight3D.new()
	light.light_color = tint
	light.light_energy = 7.0
	light.omni_range = max_radius * 1.1
	light.position = Vector3(0, 0.6, 0)
	mi.add_child(light)

	var segs: int = 72
	var thickness: float = max(0.6, max_radius * 0.18)
	var t := mi.create_tween()
	t.set_parallel(true)
	t.tween_method(func(phase: float):
		var outer_r: float = lerpf(0.1, max_radius, phase)
		var inner_r: float = maxf(0.0, outer_r - thickness * (1.0 - phase * 0.4))
		im.clear_surfaces()
		im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
		for i in range(segs + 1):
			var ang: float = float(i) / float(segs) * TAU
			var c: float = cos(ang)
			var s: float = sin(ang)
			im.surface_add_vertex(Vector3(c * outer_r, 0, s * outer_r))
			im.surface_add_vertex(Vector3(c * inner_r, 0, s * inner_r))
		im.surface_end()
	, 0.0, 1.0, duration).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	t.tween_method(func(v: float):
		mat.emission_energy_multiplier = v * 5.0
		mat.albedo_color.a = v
		light.light_energy = v * 7.0
	, 1.0, 0.0, duration)
	get_tree().create_timer(duration + 0.05).timeout.connect(mi.queue_free)

	# Capture the scene this effect belongs to. If the player resets mid-super,
	# the queued timer closures will see a swapped current_scene and bail rather
	# than spawning stray bolts into the freshly reloaded arena.
	var scene := get_tree().current_scene

	# Chaotic rainbow-arched bolts from the player out to the wavefront. Each
	# tick spawns a clump of arcs landing at random points along the current
	# ring radius, so the EM field reads as continuously discharging outward.
	var arch_ticks: int = 16
	for i in arch_ticks:
		var tick_t: float = float(i) / float(arch_ticks) * duration
		get_tree().create_timer(tick_t, true, false, true).timeout.connect(func():
			if not is_instance_valid(scene) or get_tree().current_scene != scene:
				return
			var phase: float = tick_t / duration
			var r: float = lerpf(0.6, max_radius, phase)
			var arcs_this_tick: int = 3
			for j in arcs_this_tick:
				var ang: float = randf() * TAU
				var radial_jitter: float = randf_range(-0.6, 0.6)
				var landing := origin + Vector3(cos(ang) * (r + radial_jitter), 0.05, sin(ang) * (r + radial_jitter))
				_emp_arch_bolt(origin + Vector3(0, 0.4, 0), landing, tint)
		)

	# Crackles riding the wavefront — each burst spawns at the ring's current
	# radius and arcs tangentially along it. Many small bursts read as the
	# pulse "frying" everything it passes over.
	var burst_count: int = 18
	for i in burst_count:
		var burst_t: float = float(i) / float(burst_count) * duration
		get_tree().create_timer(burst_t, true, false, true).timeout.connect(func():
			if not is_instance_valid(scene) or get_tree().current_scene != scene:
				return
			var phase: float = burst_t / duration
			var r: float = lerpf(0.1, max_radius, phase)
			var arcs_per_burst: int = 4
			for j in arcs_per_burst:
				var ang: float = randf() * TAU
				var dirn := Vector3(cos(ang), 0, sin(ang))
				var tang := Vector3(-sin(ang), 0, cos(ang))
				var a_pt: Vector3 = origin + dirn * r + Vector3(0, 0.05, 0)
				var span: float = randf_range(0.5, 1.4)
				var sign_t: float = 1.0 if randf() < 0.5 else -1.0
				var b_pt: Vector3 = a_pt + tang * span * sign_t + Vector3(0, randf_range(0.05, 0.6), 0)
				_emp_arc(a_pt, b_pt, tint)
		)

func emp_shockwave(origin: Vector3, max_radius: float, tint: Color) -> void:
	# Expanding emissive sphere shell + crackling arcs sweeping outward along the
	# wavefront. Reads as a single instantaneous EM blast — the shell does the
	# "pulse" and the arcs do the "crackle". No persistent field; everything is
	# gone by ~0.45s.
	var pair := _spawn_emissive_sphere(origin, 1.0, 24, 12, tint, 2.2)
	var mi: MeshInstance3D = pair[0]
	var mat: StandardMaterial3D = pair[1]
	mat.albedo_color.a = 0.18
	mi.scale = Vector3.ONE * 0.15

	var light := OmniLight3D.new()
	light.light_color = tint
	light.light_energy = 9.0
	light.omni_range = max_radius * 1.2
	mi.add_child(light)

	var life: float = 0.5
	var t := mi.create_tween()
	t.set_parallel(true)
	t.tween_property(mi, "scale", Vector3.ONE * max_radius, life).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	t.tween_method(func(v: float):
		mat.emission_energy_multiplier = v * 2.2
		mat.albedo_color.a = v * 0.18
		light.light_energy = v * 9.0
	, 1.0, 0.0, life)
	get_tree().create_timer(life + 0.05).timeout.connect(mi.queue_free)

	# A handful of clean radial filaments streaking outward from the origin at
	# t=0 — these read as the EM pulse itself. Followed by a small number of
	# soft wispy arcs riding the wavefront and a couple inside, all using the
	# additive _emp_arc style so they glow instead of looking like scribbles.
	var filaments: int = 10
	for i in filaments:
		var yaw: float = randf() * TAU
		var pitch: float = randf_range(-0.7, 0.7)
		var n := Vector3(cos(yaw) * cos(pitch), sin(pitch), sin(yaw) * cos(pitch))
		var end_r: float = randf_range(max_radius * 0.7, max_radius)
		_emp_arc(origin, origin + n * end_r, tint)

	# See emp_ground_wave for the rationale; same scene-reload guard.
	var scene := get_tree().current_scene
	var bursts: int = 4
	for i in bursts:
		var burst_t: float = float(i + 1) / float(bursts) * life * 0.7
		get_tree().create_timer(burst_t, true, false, true).timeout.connect(func():
			if not is_instance_valid(scene) or get_tree().current_scene != scene:
				return
			var phase: float = burst_t / life
			var r: float = lerpf(0.3, 1.0, phase) * max_radius
			var surface_count: int = 3
			for j in surface_count:
				var yaw: float = randf() * TAU
				var pitch: float = randf_range(-0.5, 0.5)
				var n := Vector3(cos(yaw) * cos(pitch), sin(pitch), sin(yaw) * cos(pitch))
				var a_pt: Vector3 = origin + n * r
				var tangent := n.cross(Vector3.UP)
				if tangent.length() < 0.01:
					tangent = Vector3.RIGHT
				tangent = tangent.normalized()
				var sign_t: float = 1.0 if randf() < 0.5 else -1.0
				var b_pt: Vector3 = a_pt + tangent * randf_range(0.8, 1.8) * sign_t
				_emp_arc(a_pt, b_pt, tint)
		)

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
	var side := fwd.cross(safe_up(fwd)).normalized()
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
