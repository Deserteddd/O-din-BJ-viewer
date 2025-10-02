package obj_viewer

import "core:math"
import "core:math/linalg"
import sdl "vendor:sdl3"

Player :: struct {
    position: vec3,
    speed: vec3,
    rotation: vec3,
    bbox: AABB,
    airborne: bool,
    noclip: bool,
}

create_player :: proc() -> Player {
    position: vec3 = {0, 0, 15}
    return Player {
        position = position,
        bbox = AABB {
            min = position + {-0.3, 0, -0.3},
            max = position + {0.3, 2.0, 0.3}
        },
    }
}

get_player_translation :: proc(p: Player) -> [2]vec3 {
    return {
        p.position,
        p.rotation
    }
}

update_player :: proc(state: ^AppState, dt: f32) #no_bounds_check {
    using state, player
    defer props.lmb_pressed = false
    g: f32 = 25
    wishveloc := player_wish_speed(player)
    airborne_at_start := airborne
    if noclip {
        speed = 0
        delta_pos := wishveloc * dt * 10
        position += delta_pos
        bbox.min += delta_pos
        bbox.max += delta_pos
        return
    }

    if wishveloc.y > 0 && !airborne {
        speed.y = 9
        airborne = true
    } else if !airborne {
        speed += wishveloc
    } else {
        air_accelerate(&wishveloc, &player, dt)
        speed.y -= g * dt
    }
    delta_pos := speed * dt
    position += delta_pos
    bbox.min += delta_pos
    bbox.max += delta_pos
    found_collision: bool
    
    ray_origin, ray_dir := ray_from_screen(renderer.view_projection)
    closest_hit: f32 = math.F32_MAX
    closest_index := -1

    for entity, i in entities {
        if entity.model.type == .GLTF do continue
        aabb := entity_aabb(entity)
        if aabbs_collide(bbox, aabb) {
            found_collision = true
            mtv := resolve_aabb_collision_mtv(bbox, aabb)
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
        intersection := ray_intersect_aabb(ray_origin, ray_dir, aabb)
        if intersection != -1 && intersection < closest_hit {
            closest_hit = intersection
            closest_index = i
        }

    }
    if !found_collision do airborne = true

    if !airborne_at_start && !airborne {
        speed *= 0.8
    }

    if linalg.length(speed.xz) > 20 do speed.xz *= 0.9

    if closest_index != -1 && state.entities[closest_index].name == "slab" && state.props.lmb_pressed == true {
        unordered_remove_soa(&state.entities, closest_index)
    }

    if position.y < -5 {
        reset_player_pos(state)
        
    }

}

update_camera :: proc(player: ^Player) {
    x, y: f32
    using player
    _ = sdl.GetRelativeMouseState(&x, &y)
    rotation.y += x * 0.03
    rotation.x += y * 0.03
    if rotation.x >  90 do rotation.x =  90
    if rotation.x < -90 do rotation.x = -90
}

player_wish_speed :: proc(player: Player) -> vec3 {
    using sdl.Scancode
    key_state := sdl.GetKeyboardState(nil)
    wish_speed: vec3

    u := f32(int(key_state[SPACE]))
    d := f32(int(key_state[LCTRL]))
    fb := f32(int(key_state[S])-int(key_state[W]))
    lr := f32(int(key_state[D])-int(key_state[A]))

    yaw_cos := math.cos(math.to_radians(player.rotation.y))
    yaw_sin := math.sin(math.to_radians(player.rotation.y))

    if !player.airborne do wish_speed.y = u
    if player.noclip do wish_speed.y = u-d
    wish_speed.x += (lr * yaw_cos - fb * yaw_sin)
    wish_speed.z += (lr * yaw_sin + fb * yaw_cos)
    return wish_speed
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