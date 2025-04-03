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
    bounds:             [dynamic]AABB,
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
    
    renderer := RND_Init({})
    state.renderer = renderer
    player_entity := Entity { id = 0 }
    player_physics := Physics{
        flags = {.PLAYER, .COLLIDER, .DYNAMIC},
        position = {0, 0, 5}
    }
    append(&state.entities, player_entity)
    append(&state.entity_physics, player_physics)
    data := load_object("assets/cube_world"); defer delete_obj(data)
    CreateEntity(data, state, {.COLLIDER, .STATIC})
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
                        state.entity_physics[0].position = {0, 0, 5}
                }
            }
        }
        update(state)
        RND_FrameBegin(&state.renderer)
        RND_DrawEntities(state)
        RND_DrawBounds(state)
        ok := RND_FrameSubmit(&state.renderer); assert(ok)
        if FRAMES % 30 == 0 {
            fmt.println("player pos:\t", state.entity_physics[0].position)
        //     fmt.println("player rot:\t", state.entity_physics[0].rotation)
        //     fmt.println("First bbox:\t", state.entities[1].bboxes[0])
        //     fmt.println("Airborne:\t", .AIRBORNE in state.entity_physics[0].flags)
        //     fmt.println()
        }
    }
}

update :: proc(state: ^AppState) {
    using state
    assert(state.entities[0].bboxes_vbo == nil)
    new_ticks := sdl.GetTicks();
    dt := f32(new_ticks - last_ticks) / 1000
    last_ticks = new_ticks
    update_entity_physics(state, dt)
    process_keyboard(state, dt)
    update_camera(&state.entity_physics[0])
}

check_player_collision :: proc(p: vec3, aabb: AABB) -> vec3 {
    clampedX := math.max(aabb.min.x, math.min(p.x, aabb.max.x));
    clampedY := math.max(aabb.min.y, math.min(p.y, aabb.max.y));
    clampedZ := math.max(aabb.min.z, math.min(p.z, aabb.max.z));
    return {clampedX, clampedY, clampedZ};
}

update_entity_physics :: proc(state: ^AppState, dt: f32) {
    // assert(len(state.bounding_boxes) == 4)
    for &physics, i in state.entity_physics {
        using state, physics
        nearest_y := 1000
        if .PLAYER in flags {
            g: f32 = 18
            previous := position
            position += speed * dt
            speed.y -= g*dt
            assert(physics.position == state.entity_physics[0].position)
            for aabb, j in bounds {
                collision := check_player_collision(physics.position, aabb) 
                if collision == physics.position {
                    // speed.y = 0
                    position = previous
                }
            }
            if position.y <= 0 {
                speed.y = 0
                position.y = 0
                flags -= {.AIRBORNE}
            } else {
                flags += {.AIRBORNE}
            }
        }

    }
}

process_keyboard :: proc(state: ^AppState, dt: f32) {
    using sdl.Scancode
    key_state := sdl.GetKeyboardState(nil)
    f, b, l, r, u, d: f32
    yaw_r, yaw_l, pitch_u, pitch_d : f32
    move_speed: f32 = 50
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
    if key_state[LSHIFT] do move_speed *= 2

    using state
    player:= &entity_physics[0]
    yaw_cos := math.cos(math.to_radians(player.rotation.y))
    yaw_sin := math.sin(math.to_radians(player.rotation.y))

    player.rotation.x += (pitch_d-pitch_u) * dt * 100
    player.rotation.y += (yaw_r-yaw_l) * dt * 100
    if !(.AIRBORNE in entity_physics[0].flags) {
        assert(player.speed.y == 0)
        fb := b-f; lr := r-l
        friction: f32 = 0.1
        player.speed.x += (lr * yaw_cos - fb * yaw_sin) * move_speed * dt
        player.speed.z += (lr * yaw_sin + fb * yaw_cos) * move_speed * dt
        player.speed.y = u*move_speed * 0.11
        player.speed.xz *= 1-friction
    }
}

update_camera :: proc(player_physics: ^Physics) {
    x, y: f32
    using player_physics
    _flags := sdl.GetRelativeMouseState(&x, &y)
    rotation.y += x * 0.05
    rotation.x += y * 0.05
    if rotation.x >  90 do rotation.x =  90
    if rotation.x < -90 do rotation.x = -90
}