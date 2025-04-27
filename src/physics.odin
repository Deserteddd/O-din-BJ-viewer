package obj_viewer

import "core:math"
import "core:math/linalg"
import "core:time"
import "core:fmt"
import "core:thread"
import "core:sync"

PhysicsFlags :: distinct bit_set[PhysicsFlag]

PhysicsFlag :: enum {
    STATIC,
    DYNAMIC,
    COLLIDER,
    AIRBORNE,
    PLAYER,
    SHADOW_CASTER
}

AABB :: struct {
    min: vec3,
    max: vec3
}

workerData :: struct {
    waitgroupdata: ^sync.Wait_Group,
    player: ^Player,
    entity_bboxes: ^[dynamic]AABB,
    found_collision: ^bool,
    start, end: int,
}

resolve_aabb_collisions :: proc(t: ^thread.Thread) {
    data := (cast(^workerData)t.data)
    using data
    using player
    for i in start..<end {
        if aabbs_collide(bbox, entity_bboxes[i]) {
            found_collision^ = true
            mtv := resolve_aabb_collision_mtv(bbox, entity_bboxes[i])
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
    sync.wait_group_done(data.waitgroupdata)
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
    length := v.x*v.x + v.y*v.y + v.z*v.z
    length = math.sqrt(length)
    if length != 0 {
        ilength := 1/length
        v^ *= ilength
    }
    return length
}

update_player :: proc(state: ^AppState, wishveloc: ^vec3, dt: f32) {
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

    for i in 0..<len(aabbs) {
        if aabbs_collide(bbox, state.aabbs[i]) {
            found_collision = true
            mtv := resolve_aabb_collision_mtv(bbox, state.aabbs[i])
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

    // sync.wait_group_wait(&wg)

    if !found_collision do airborne = true
    if !airborne_at_start && !airborne {
        speed *= 0.8
    }
    if linalg.length(speed) > 20 do speed *= 0.9
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

aabb_intersects_frustum :: proc(frustum_planes: [6]vec4, aabb: AABB) -> bool {
    using aabb
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
