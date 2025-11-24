package obj_viewer

import "core:math/linalg"
import "core:math"

AABB :: struct {
    min: vec3,
    max: vec3
}

entity_aabbs :: proc(entity: Entity) -> []AABB {
    aabbs := make([]AABB, len(entity.model.aabbs), context.temp_allocator)
    for aabb, i in entity.model.aabbs {
        aabbs[i] = AABB {
            min = aabb.min * entity.transform.scale + entity.transform.translation,
            max = aabb.max * entity.transform.scale + entity.transform.translation
        }
    }
    return aabbs
}

vector_normalize :: proc(v: ^vec3) -> f32 {
    length := linalg.length(v^)
    if length != 0 {
        ilength := 1/length
        v^ *= ilength
    }
    return length
}

create_frustum_planes :: proc "contextless" (vp: mat4) -> [6]vec4 {
    t := linalg.transpose(vp)
    return {
        t[3]+t[0],
        t[3]+t[0],
        t[3]+t[1],
        t[3]+t[1],
        t[3]+t[2],
        t[3]+t[2],
    }
}

aabb_intersects_frustum :: proc(frustum_planes: [6]vec4, aabb: AABB) -> bool #no_bounds_check {
    using aabb
    p_vertex: vec3
    for p in frustum_planes {
        p_vertex = {
            f32(cast(byte)bool(p.x >= 0))*(max.x)+f32(cast(byte)bool(p.x<0))*min.x,
            f32(cast(byte)bool(p.y >= 0))*(max.y)+f32(cast(byte)bool(p.y<0))*min.y,
            f32(cast(byte)bool(p.z >= 0))*(max.z)+f32(cast(byte)bool(p.z<0))*min.z,
        }

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

ray_from_screen :: proc(
    screen_pos:    vec2,
    viewport_size: vec2
) -> (origin, direction: vec3) {
    proj_matrix := create_proj_matrix()
    view_matrix := create_view_matrix()
    vp := proj_matrix * view_matrix
    // normalize to NDC (-1..1)
    ndc_x := (2.0 * screen_pos.x) / viewport_size.x - 1.0
    ndc_y := 1.0 - (2.0 * screen_pos.y) / viewport_size.y // flip y if needed
    // ndc_x, ndc_y: f32 = 0, 0
    near_point := vec4{ndc_x, ndc_y, -1.0, 1.0}
    far_point  := vec4{ndc_x, ndc_y,  1.0, 1.0}

    inv_viewproj := linalg.inverse(vp)

    near_world := inv_viewproj * near_point
    far_world  := inv_viewproj * far_point

    // Perspective divide
    near_world /= near_world.w
    far_world  /= far_world.w
    origin    = near_world.xyz
    direction = linalg.normalize(far_world.xyz - near_world.xyz)
    return
}

ray_intersect_aabb :: proc(origin: vec3, dir: vec3, box: AABB) -> f32 {
    using math

    inv_dir := 1.0 / dir
    t1 := (box.min.x - origin.x) * inv_dir.x
    t2 := (box.max.x - origin.x) * inv_dir.x
    tmin := min(t1, t2)
    tmax := max(t1, t2)

    ty1 := (box.min.y - origin.y) * inv_dir.y
    ty2 := (box.max.y - origin.y) * inv_dir.y
    tmin = max(tmin, min(ty1, ty2))
    tmax = min(tmax, max(ty1, ty2))

    tz1 := (box.min.z - origin.z) * inv_dir.z
    tz2 := (box.max.z - origin.z) * inv_dir.z
    tmin = max(tmin, min(tz1, tz2))
    tmax = min(tmax, max(tz1, tz2))

    if tmax >= max(tmin, 0.0) {
        return tmin // hit distance
    }
    return -1.0 // no hit
}