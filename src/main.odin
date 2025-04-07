package obj_viewer

import "base:runtime"
import "core:log"
import "core:math"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:math/linalg"
import "core:path/filepath"
import "core:time"
import sdl "vendor:sdl3"

default_context: runtime.Context
DEBUG := false
FRAMES := 0
last_ticks := sdl.GetTicks();

main :: proc() {
    state: AppState
    init(&state)
    fmt.println("MAIN: init done")
    run(&state)
    fmt.println("MAIN: Exiting")
}

AppState :: struct {
    renderer:           Renderer,
    entities:           [dynamic]Entity,
    entity_physics:     [dynamic]Physics,
    entity_bounds:      [dynamic]AABB,
    player_collisions:  []bool
}

init :: proc(state: ^AppState) {
    context.logger = log.create_console_logger()
    default_context = context
    sdl.SetLogPriorities(.VERBOSE)
    sdl.SetLogOutputFunction(
        proc "c" (userdata: rawptr, category: sdl.LogCategory, priority: sdl.LogPriority, message: cstring) {
            context = default_context
            log.debugf("SDL {} [{}]", category, priority, message)
        }, nil
    )
    
    state.renderer = RND_Init({.FULLSCREEN})
    CreatePlayer(state)
    slab := load_object("assets/ref_cube"); defer delete_obj(slab)
    for i in 0..<10 {
        CreateEntity(slab, state, {.COLLIDER, .STATIC})
        physics := &state.entity_physics[i+1]
        bbox := &state.entity_bounds[i+1]
        move_by := vec3{0, f32(i), -f32(i)*2}
        move_entity(physics, bbox, move_by)
    }
    creeper := load_object("assets/22-moto_simple"); defer delete_obj(creeper)
    CreateEntity(creeper, state, {.STATIC, .COLLIDER})
    // state.entity_physics[11].position = {0, 6, -20}
    move_entity(&state.entity_physics[11], &state.entity_bounds[11], {-2, 4, -20})
    // state.entity_physics[11].rotation.y = 90
    state.player_collisions = make([]bool, len(state.entity_physics))
}   

run :: proc(state: ^AppState) {
    main_loop: for {
        defer FRAMES += 1
        ev: sdl.Event
        for sdl.PollEvent(&ev) {
            #partial switch ev.type {
                case .QUIT: 
                    break main_loop
                case .KEY_DOWN: #partial switch ev.key.scancode {
                    case .ESCAPE: break main_loop
                    case .F: 
                        RND_ToggleWireframe(&state.renderer)
                    case .Q:
                        p := &state.entity_physics[0]
                        b := &state.entity_bounds[0]
                        move_entity(p, b, -p.position+{0, 2, 0})
                        p.speed = 0
                }
            }
        }
        // fmt.println(state.player_collisions)
        update(state)
        RND_FrameBegin(&state.renderer)
        RND_DrawEntities(state)
        RND_DrawBounds(state)
        ok := RND_FrameSubmit(&state.renderer); assert(ok)
        if FRAMES % 60 == 0 {
            fmt.println("speed:\t", state.entity_physics[0].speed)
            fmt.println("Airborne:\t", .AIRBORNE in state.entity_physics[0].flags)
            fmt.println("bbox_min:\t", state.entity_bounds[0].min)
            fmt.println("bbox_max:\t", state.entity_bounds[0].max)
            fmt.println()
        }
    }
}

update :: proc(state: ^AppState) {
    using state
    new_ticks := sdl.GetTicks();
    dt := f32(new_ticks - last_ticks) / 1000
    last_ticks = new_ticks
    process_keyboard(state, dt)
    update_player(state, dt)
    update_camera(&state.entity_physics[0])
}

update_player :: proc(state: ^AppState, dt: f32) {
    g: f32 = 16
    p := &state.entity_physics[0]
    p.speed.y -= g*dt*2
    if p.speed.y < -10 do p.speed.y = -10
    delta_pos := p.speed * dt
    move_entity(p, &state.entity_bounds[0], delta_pos)
    p.flags += {.AIRBORNE}
    for box, i in state.entity_bounds {
        if i == 0 do continue
        if aabbs_collide(state.entity_bounds[0], box) {
            mtv := resolve_aabb_collision_mtv(state.entity_bounds[0], box)
            for axis, j in mtv do if axis != 0 {
                p.speed[j] *= 0.95
                if j == 1 && axis > 0 { // This means we are standing on a block
                    p.flags -= {.AIRBORNE}
                } 
            } 
            move_entity(p, &state.entity_bounds[0], mtv)
            state.player_collisions[i] = true
        } else {
            state.player_collisions[i] = false
        }
    }
}

process_keyboard :: proc(state: ^AppState, dt: f32) {
    using sdl.Scancode
    key_state := sdl.GetKeyboardState(nil)
    f, b, l, r, u, d: f32
    yaw_r, yaw_l, pitch_u, pitch_d : f32
    move_speed: f32 = 75
    if key_state[W] do f = 1
    if key_state[S] do b = 1
    if key_state[A] do l = 1
    if key_state[D] do r = 1
    if key_state[SPACE] do u = 1
    if key_state[LCTRL] do d = 1
    if key_state[RIGHT] do yaw_r = 1
    if key_state[LEFT] do yaw_l = 1
    if key_state[UP] do pitch_u = 1
    if key_state[DOWN] do pitch_d = 1

    using state
    player:= &entity_physics[0]
    yaw_cos := math.cos(math.to_radians(player.rotation.y))
    yaw_sin := math.sin(math.to_radians(player.rotation.y))
    player.rotation.x += (pitch_d-pitch_u) * dt * 100
    player.rotation.y += (yaw_r-yaw_l) * dt * 100
    if !(.AIRBORNE in state.entity_physics[0].flags) {
        fb := b-f; lr := r-l
        player.speed.y = (u-d)*move_speed * 0.15
        if key_state[LSHIFT] do move_speed *= 2
        player.speed.x += (lr * yaw_cos - fb * yaw_sin) * move_speed * dt
        player.speed.z += (lr * yaw_sin + fb * yaw_cos) * move_speed * dt
        player.speed *= 0.9
    }
}

update_camera :: proc(player_physics: ^Physics) {
    x, y: f32
    using player_physics
    _ = sdl.GetRelativeMouseState(&x, &y)
    rotation.y += x * 0.05
    rotation.x += y * 0.05
    if rotation.x >  90 do rotation.x =  90
    if rotation.x < -90 do rotation.x = -90
}