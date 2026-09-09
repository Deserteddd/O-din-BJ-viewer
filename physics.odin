package obj_viewer


import "core:fmt"
import b3 "vendor:box3d"

World :: struct {
	world_id: 		b3.WorldId,
	ground_body:	b3.BodyId,
	ground_hull:	b3.ShapeId,
	player_body:	b3.BodyId,
	player_hull:	b3.ShapeId,
}

PhysicsComponent :: struct {
    dyn: bool,
    position,
    scale,
    speed: vec3,
    rotation: quaternion128,
    aabb: AABB,
    b3: struct {
    	body: b3.BodyId,
     	hull: b3.ShapeId // Not sure if necessary to keep
    }
}

init_physics :: proc() {
	world_def := b3.DefaultWorldDef()
	world_def.gravity = {0, -9.81, 0}
	g.world.world_id = b3.CreateWorld(world_def)
}

add_physics_body :: proc(e: ^Entity) {
	if e.physics.b3 != {} {
		b3.DestroyBody(e.physics.b3.body)
	}
	body_def := b3.DefaultBodyDef()
    body_def.type = e.physics.dyn ? .dynamicBody : .staticBody
	body_def.position = e.physics.position
	body_def.rotation = e.physics.rotation
    body_def.linearVelocity = e.physics.speed
	e.physics.b3.body = b3.CreateBody(g.world.world_id, body_def)

    aabb := (e.physics.aabb.max + abs(e.physics.aabb.min)) / 2 * e.physics.scale
	box_hull := b3.MakeBoxHull(aabb.x, aabb.y, aabb.z)

	shape_def := b3.DefaultShapeDef()
	shape_def.density = 1
	shape_def.baseMaterial.friction = 0.7
	assert(e.physics.b3.body != {})
	e.physics.b3.hull = b3.CreateHullShape(e.physics.b3.body, shape_def, &box_hull.base)
}

set_physics_position :: proc(e: ^Entity) {
	b3.Body_SetTransform(e.physics.b3.body, e.physics.position, e.physics.rotation)
}

destroy_physics_body :: proc(e: ^Entity) {
	b3.DestroyBody(e.physics.b3.body)
	e.physics.b3 = {}
}

add_player :: proc() {
	w := &g.world

	player_body_def := b3.DefaultBodyDef()
	player_body_def.position = {0, 1, 0}
	w.player_body = b3.CreateBody(w.world_id, player_body_def)

	player_box := b3.MakeCubeHull(1)

	shape_def := b3.DefaultShapeDef()
	shape_def.density = 1
	shape_def.baseMaterial.friction = 0.3

	w.player_hull = b3.CreateHullShape(w.player_body, shape_def, &player_box.base)
}