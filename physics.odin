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
     	hull: b3.ShapeId
    }
}

init_physics :: proc() {
	world_def := b3.DefaultWorldDef()
	world_def.gravity = {0, -9.81, 0}

	g.world.world_id = b3.CreateWorld(world_def)

}

add_ground :: proc() {
	w := &g.world

	groundBodyDef := b3.DefaultBodyDef()
	groundBodyDef.position = {0, -10, 0}

	w.ground_body = b3.CreateBody(w.world_id, groundBodyDef)

	groundBox := b3.MakeBoxHull(200.0, 1.0, 200.0);

	groundShapeDef := b3.DefaultShapeDef();
	w.ground_hull = b3.CreateHullShape(w.ground_body, groundShapeDef, &groundBox.base)
}
add_dynamic_body :: proc(e: ^Entity) {

	body_def := b3.DefaultBodyDef()
    body_def.type = .dynamicBody
	body_def.position = e.physics.position
	body_def.rotation = e.physics.rotation
    body_def.linearVelocity = e.physics.speed
	e.physics.b3.body = b3.CreateBody(g.world.world_id, body_def)

    aabb := e.physics.aabb
	box_hull := b3.MakeBoxHull(aabb.max.x, aabb.max.y, aabb.max.z)

	shape_def := b3.DefaultShapeDef()
	shape_def.density = 1
	shape_def.baseMaterial.friction = 0.7
	assert(e.physics.b3.body != {})
	e.physics.b3.hull = b3.CreateHullShape(e.physics.b3.body, shape_def, &box_hull.base)
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