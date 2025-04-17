package obj_viewer

import "core:math"
import "core:math/linalg"
import "core:fmt"
import "core:simd"

PhysicsFlags :: distinct bit_set[PhysicsFlag]

PhysicsFlag :: enum {
    STATIC,
    DYNAMIC,
    COLLIDER,
    AIRBORNE,
    PLAYER
}

AABB :: struct {
    min: vec3,
    max: vec3
}

AABB_soa :: struct {
    min: #soa[dynamic]vec3,
    max: #soa[dynamic]vec3
}

create_furstum_planes :: proc(vp: matrix[4,4]f32) -> [6]vec4 {
    vp := linalg.transpose(vp)
    return {
        vp[3]+vp[0],
        vp[3]-vp[0],
        vp[3]+vp[1],
        vp[3]-vp[1],
        vp[3]+vp[2],
        vp[3]-vp[2],
    }
}

aabb_intersects_frustum :: proc(frustum_planes: [6]vec4, aabb: AABB) -> bool {
    using aabb
    if linalg.length((aabb.min + aabb.max)/2) > 100 do return false
    for p in frustum_planes {
        p_vertex: vec3
        if p.x >= 0 do p_vertex.x = max.x; else do p_vertex.x = min.x
        if p.y >= 0 do p_vertex.y = max.y; else do p_vertex.y = min.y
        if p.z >= 0 do p_vertex.z = max.z; else do p_vertex.z = min.z

        if linalg.dot(p.xyz, p_vertex) + p.w < 0 {
            return false
        }
    }
    return true
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
        if direction.x < 0 do mtv.x = -x_overlap; else do mtv.x = x_overlap
	} else if y_overlap <= z_overlap {
        if direction.y < 0 do mtv.y = -y_overlap; else do mtv.y = y_overlap
	} else {
        if direction.z < 0 do mtv.z = -z_overlap; else do mtv.z = z_overlap
	}

	return mtv
}
