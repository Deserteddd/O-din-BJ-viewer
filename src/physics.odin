package obj_viewer

import "core:math"
import "core:fmt"

PhysicsFlags :: distinct bit_set[PhysicsFlag]

PhysicsFlag :: enum {
    STATIC,     // Isn't affected by gravity
    DYNAMIC,    // Is affected by gravity
    COLLIDER,   // Duh?
    AIRBORNE,
    PLAYER
}

// AABB stores 6 values when it only needs to store witdth, height and offset
AABB :: struct {
    min: vec3,
    max: vec3
}

aabbs_collide :: proc(a: AABB, b: AABB) -> bool {
    return (a.min.x <= b.max.x && a.max.x >= b.min.x) &
    (a.min.y <= b.max.y && a.max.y >= b.min.y) &
    (a.min.z <= b.max.z && a.max.z >= b.min.z)
}

resolve_aabb_collision_mtv :: proc(moving: AABB, solid: AABB) -> vec3 {
	mtv: vec3

	x_overlap := min(moving.max.x, solid.max.x) - max(moving.min.x, solid.min.x)
	y_overlap := min(moving.max.y, solid.max.y) - max(moving.min.y, solid.min.y)
	z_overlap := min(moving.max.z, solid.max.z) - max(moving.min.z, solid.min.z)

	if x_overlap <= 0 || y_overlap <= 0 || z_overlap <= 0 {
		return mtv // No collision
	}

	center_moving := (moving.min + moving.max) * 0.5
	center_solid  := (solid.min + solid.max) * 0.5

	direction := center_moving - center_solid

	// Resolve along axis of least penetration
	if x_overlap <= y_overlap && x_overlap <= z_overlap {
		// mtv.x = if direction.x < 0 then -x_overlap else x_overlap
        if direction.x < 0 do mtv.x = -x_overlap; else do mtv.x = x_overlap
	} else if y_overlap <= z_overlap {
		// mtv.y = if direction.y < 0 then -y_overlap else y_overlap
        if direction.y < 0 do mtv.y = -y_overlap; else do mtv.y = y_overlap
	} else {
        if direction.z < 0 do mtv.z = -z_overlap; else do mtv.z = z_overlap
	}

	return mtv
}
