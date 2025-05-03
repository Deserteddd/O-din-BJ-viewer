package obj_viewer

import "core:math/linalg"
import "core:time"
import "core:fmt"

AABB :: struct {
    min: vec3,
    max: vec3
}

air_accelerate :: proc(wishveloc: ^vec3, player: ^Player, dt: f32) {
    addspeed, wishspd, accelspeed, currentspeed: f32
    wishveloc^ *= 10
    wishspd = vector_normalize(wishveloc);
    grounded_wishspd := wishspd
    if wishspd > 2 do wishspd = 2
    currentspeed = linalg.dot(player.speed, wishveloc^)
    addspeed = wishspd - currentspeed
    if addspeed <= 0 do return

    accelspeed = grounded_wishspd * 5 * dt
    player.speed += accelspeed * wishveloc^
}

vector_normalize :: proc(v: ^vec3) -> f32 {
    length := linalg.length(v^)
    if length != 0 {
        ilength := 1/length
        v^ *= ilength
    }
    return length
}

update_player :: proc(state: ^AppState, wishveloc: ^vec3, dt: f32) #no_bounds_check {
    g: f32 = 25
    using state, player
    airborne_at_start := airborne
    if wishveloc.y > 0 && !airborne {
        speed.y = 9
        airborne = true
    } else if !airborne {
        speed += wishveloc^
    } else {
        air_accelerate(wishveloc, &player, dt)
        speed.y -= g * dt
    }
    delta_pos := speed * dt
    position += delta_pos
    bbox.min += delta_pos
    bbox.max += delta_pos
    found_collision: bool

    for entity in entities {
        if aabbs_collide(bbox, entity.aabb) {
            found_collision = true
            mtv := resolve_aabb_collision_mtv(bbox, entity.aabb)
            for axis, j in mtv do if axis != 0 {
                speed[j] *= 0.9
                if j == 1 { 
                    if axis > 0 { // This means we are standing on a block
                        airborne = false
                    } else {
                        speed.y = -0.1
                    }
                }
            }
            position += mtv
            bbox.min += mtv
            bbox.max += mtv
        }
    }

    if !found_collision do airborne = true
    if !airborne_at_start && !airborne {
        speed *= 0.8
    }
    if linalg.length(speed.xz) > 20 do speed.xz *= 0.9
    if position.y < -5 {
        reset_player_pos(state)
    }
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

aabb_intersects_frustum :: proc(frustum_planes: [6]vec4, aabb: AABB) -> bool #no_bounds_check {
    using aabb
    p_vertex: vec3
    for p in frustum_planes {
        p_vertex = {
            f32(transmute(byte)bool(p.x >= 0))*(max.x)+f32(transmute(byte)bool(p.x<0))*min.x,
            f32(transmute(byte)bool(p.y >= 0))*(max.y)+f32(transmute(byte)bool(p.y<0))*min.y,
            f32(transmute(byte)bool(p.z >= 0))*(max.z)+f32(transmute(byte)bool(p.z<0))*min.z,
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
