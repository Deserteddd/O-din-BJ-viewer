package obj_viewer

import "core:math"
import "core:log"
import lg "core:math/linalg"
import rd "../Redef"

Player :: struct {
    position,
    speed,
    rotation:   vec3,
	fov:        f32,
    bbox:       AABB,
    airborne,
    noclip:     bool,
    checkpoint: [2]vec3,                // Position, Rotation
}

create_player :: proc(pos: vec3 = 0, rotation: vec3 = 0) {
    g.player = {
        position = pos,
        rotation = rotation,
        bbox = AABB {
            min = pos + {-0.3, 0, -0.3},
            max = pos + {0.3, 2.0, 0.3}
        },
        checkpoint = {pos, rotation},
        fov = 90
    }
}

camera_position :: proc() -> vec3 {
    return g.player.position + {0, 2, 0}
}

get_player_translation :: proc() -> [2]vec3 {
    return {
        g.player.position,
        g.player.rotation
    }
}

update_player :: proc() {
    G :: 25
    p := &g.player
    dt := g.dt
    wishveloc := player_wish_speed()
    airborne_at_start := p.airborne
    // if p.noclip {
        p.speed = 0
        delta_pos := wishveloc * f32(dt) * 16
        p.position += delta_pos
        p.bbox.min += delta_pos
        p.bbox.max += delta_pos
    // } 
    // else {
    //     if wishveloc.y > 0 && !p.airborne {
    //         p.speed.y = 9
    //         p.airborne = true
    //     } else if !p.airborne {
    //         p.speed += wishveloc
    //     } else {
    //         air_accelerate(&wishveloc, f32(dt))
    //         p.speed.y -= f32(G * dt)
    //         p.speed.y = math.max(p.speed.y, -20)
    //     }
    //     delta_pos := p.speed * f32(dt)
    //     p.position += delta_pos
    //     p.bbox.min += delta_pos
    //     p.bbox.max += delta_pos
    // }
}

reset_player_pos :: proc(at_origin := false) {
    if at_origin do g.player.position = 0; 
    else if g.player.checkpoint.x == 0 {
        g.player.position = g.player.checkpoint.x
    } else {
        g.player.position = g.player.checkpoint.x
        g.player.rotation = g.player.checkpoint.y
    }
    g.player.speed = 0
    g.player.bbox = AABB {
        min = g.player.position + {-0.3, 0, -0.3},
        max = g.player.position + {0.3, 2, 0.3}
    }
}

player_wish_speed :: proc() -> vec3 {
    wish_speed: vec3
    u := f32(int(rd.is_key_down(.SPACE)))
    d := f32(int(rd.is_key_down(.CONTROL)))
    fb := f32(int(rd.is_key_down(.S))-int(rd.is_key_down(.W)))
    lr := f32(int(rd.is_key_down(.D))-int(rd.is_key_down(.A)))

    yaw_cos := math.cos(math.to_radians(g.player.rotation.y))
    yaw_sin := math.sin(math.to_radians(g.player.rotation.y))

    wish_speed.y = u * f32(int(!g.player.airborne)) - d
    if g.player.noclip do wish_speed.y = u-d
    wish_speed.x += (lr * yaw_cos - fb * yaw_sin)
    wish_speed.z += (lr * yaw_sin + fb * yaw_cos)
    return wish_speed
}

air_accelerate :: proc(wishveloc: ^vec3, dt: f32) {
    addspeed, wishspd, accelspeed, currentspeed: f32
    wishveloc^ *= 10
    wishspd = vector_normalize(wishveloc);
    grounded_wishspd := wishspd
    // if wishspd > 2 do wishspd = 2
    wishspd = math.min(wishspd, 2)
    currentspeed = lg.dot(g.player.speed, wishveloc^)
    addspeed = wishspd - currentspeed
    if addspeed <= 0 do return

    accelspeed = grounded_wishspd * 5 * dt
    g.player.speed += accelspeed * wishveloc^
}