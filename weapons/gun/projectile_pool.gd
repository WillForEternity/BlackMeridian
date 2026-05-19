extends Node

# Reusable bullet pool. Bullets are kept in the scene as orphan nodes (held by
# this autoload) when idle and re-parented under the current scene on acquire().
# Avoids per-shot instantiate/free churn.

const PROJECTILE_SCENE := preload("res://weapons/gun/projectile.tscn")
const POOL_PREWARM: int = 16

var _free: Array[Node] = []

func _ready() -> void:
	for i in POOL_PREWARM:
		_free.append(_make())

func _make() -> Node:
	var p := PROJECTILE_SCENE.instantiate()
	# Tell the bullet to release itself rather than queue_free.
	p.pooled = true
	return p

func acquire(parent: Node) -> Node:
	var p: Node = _free.pop_back() if _free.size() > 0 else _make()
	if p.get_parent():
		p.get_parent().remove_child(p)
	parent.add_child(p)
	p.reset_for_reuse()
	return p

func release(p: Node) -> void:
	if p.get_parent():
		p.get_parent().remove_child(p)
	_free.append(p)

func _exit_tree() -> void:
	for p in _free:
		if is_instance_valid(p):
			p.free()
	_free.clear()
