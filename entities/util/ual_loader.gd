class_name UALLoader
extends RefCounted

# Loads the Quaternius UAL1 animation pack onto an arbitrary character node.
# The local player and the remote puppets both use the Male_Ranger skeleton,
# so they can share the same retargeted animation library. Tracks authored
# against UAL1's own Skeleton3D get rewritten to point at the destination
# character's Skeleton3D path so they bind without retargeting.

const UAL_SOURCE_PATH := "res://assets/models/characters/quaternius/UAL1_Standard.glb"

static func find_skeleton(root: Node) -> Skeleton3D:
	if root == null:
		return null
	if root is Skeleton3D:
		return root
	for c in root.get_children():
		var s := find_skeleton(c)
		if s != null:
			return s
	return null

# Build (or reuse) an AnimationPlayer on `character` with UAL clips loaded.
# Returns the AnimationPlayer, or null if the character has no skeleton.
static func install(character: Node3D) -> AnimationPlayer:
	if character == null:
		return null
	var ap: AnimationPlayer = character.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap == null:
		ap = AnimationPlayer.new()
		ap.name = "AnimationPlayer"
		character.add_child(ap)
		ap.owner = character
	ap.root_node = ap.get_path_to(character)
	var packed: PackedScene = load(UAL_SOURCE_PATH) as PackedScene
	if packed == null:
		push_warning("UAL animations failed to load at %s" % UAL_SOURCE_PATH)
		return ap
	var inst: Node = packed.instantiate()
	var src_ap: AnimationPlayer = inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if src_ap == null:
		inst.queue_free()
		return ap
	var dst_skel: Skeleton3D = find_skeleton(character)
	var src_root: Node = src_ap.get_node_or_null(src_ap.root_node)
	if src_root == null:
		src_root = inst
	var src_skel: Skeleton3D = find_skeleton(src_root)
	var dst_skel_path: NodePath = character.get_path_to(dst_skel) if dst_skel else NodePath()
	var src_skel_path_str: String = String(src_root.get_path_to(src_skel)) if src_skel else ""
	var lib := AnimationLibrary.new()
	for src_lib_name in src_ap.get_animation_library_list():
		var src_lib := src_ap.get_animation_library(src_lib_name)
		for anim_name in src_lib.get_animation_list():
			var anim: Animation = (src_lib.get_animation(anim_name) as Animation).duplicate(true)
			if dst_skel != null:
				for ti in anim.get_track_count():
					var ttype := anim.track_get_type(ti)
					if ttype != Animation.TYPE_POSITION_3D \
						and ttype != Animation.TYPE_ROTATION_3D \
						and ttype != Animation.TYPE_SCALE_3D:
						continue
					var p_str := String(anim.track_get_path(ti))
					var colon := p_str.find(":")
					var node_part := p_str if colon < 0 else p_str.substr(0, colon)
					var sub: String = "" if colon < 0 else p_str.substr(colon)
					if src_skel_path_str != "" and node_part == src_skel_path_str:
						anim.track_set_path(ti, NodePath(String(dst_skel_path) + sub))
					elif node_part == "Skeleton3D" or node_part == "Armature":
						anim.track_set_path(ti, NodePath(String(dst_skel_path) + sub))
			lib.add_animation(anim_name, anim)
	for force_loop_name in ["Sword_Idle"]:
		if lib.has_animation(force_loop_name):
			var fa: Animation = lib.get_animation(force_loop_name)
			fa.loop_mode = Animation.LOOP_LINEAR
	if ap.has_animation_library(""):
		ap.remove_animation_library("")
	ap.add_animation_library("", lib)
	ap.active = true
	ap.playback_default_blend_time = 0.15
	inst.queue_free()
	return ap
