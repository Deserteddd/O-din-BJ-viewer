package obj_viewer

import "base:runtime"
import "core:log"
import "core:math"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:math/linalg"
import sdl "vendor:sdl3"

default_context: runtime.Context

vert_shader_code := #load("../shaders/spv/triangle.vert.spv")
frag_shader_code := #load("../shaders/spv/triangle.frag.spv")

main :: proc() {
    state: AppState
    init(&state, true); // param: Fullscreen
    run(&state)
}

AppState :: struct {
    renderer: Renderer,
    rotation: Rotation
}


init :: proc(state: ^AppState, fullscreen: bool){
    context.logger = log.create_console_logger()
    default_context = context
    sdl.SetLogPriorities(.VERBOSE)
    sdl.SetLogOutputFunction(
        proc "c" (userdata: rawptr, category: sdl.LogCategory, priority: sdl.LogPriority, message: cstring) {
            context = default_context
            log.debugf("SDL {} [{}]", category, priority, message)
        }, nil
    )
    ok := sdl.Init({.VIDEO}); assert(ok)

    renderer: Renderer
    create_renderer(&renderer)
    state.renderer = renderer
}

Dir :: enum {
    NONE,
    LEFT,
    RIGHT,
    UP,
    DOWN,
}

Rotation :: struct {
    amount: f32,
    dir: Dir,
    row: f32
}

run :: proc(state: ^AppState) {
    last_ticks := sdl.GetTicks();
    second: f32 = 0
    frames := 0;
    wireframe := false
    main_loop: for {
        defer frames += 1
        new_ticks := sdl.GetTicks();
        delta_time := f32(new_ticks - last_ticks) / 1000
        second += delta_time
        ev: sdl.Event
        for sdl.PollEvent(&ev) {
            #partial switch ev.type {
                case .QUIT: 
                    break main_loop
                case .KEY_DOWN: #partial switch ev.key.scancode {
                    case .ESCAPE: break main_loop
                    case .F: 
                        wireframe = !wireframe
                        build_pipeline(&state.renderer, wireframe)
                    case .E:
                        if state.rotation.dir == .NONE do state.rotation.dir = .RIGHT
                        if state.rotation.dir == .LEFT {
                            state.rotation.dir = .RIGHT
                            state.rotation.amount += 90
                        }
                    case .Q:
                        if state.rotation.dir == .NONE do state.rotation.dir = .LEFT
                        if state.rotation.dir == .RIGHT {
                            state.rotation.dir = .LEFT
                            state.rotation.amount -= 90
                        }
                    case .W:
                        if state.rotation.dir == .NONE do state.rotation.dir = .UP
                        if state.rotation.dir == .DOWN {
                            state.rotation.dir = .UP
                            state.rotation.amount += 90
                        }
                    case .S:
                        if state.rotation.dir == .NONE do state.rotation.dir = .DOWN
                        if state.rotation.dir == .UP {
                            state.rotation.dir = .DOWN
                            state.rotation.amount -= 90
                        }
                    case ._1:
                        state.rotation.row = 0
                    case ._2:
                        state.rotation.row = 1
                    case ._3:
                        state.rotation.row = 2
                }
            }
        }


        if second >= 0.5 {
            fmt.println("fps:", frames * 2)
            second, frames = 0, 0
            // for i in 0..<len(state.renderer.model.instance_positions)
        }

        last_ticks = new_ticks
        update(state, delta_time)
        render(&state.renderer)
    }
}

rotate :: proc(model: ^Model, rotation: ^Rotation, dt: f32) {
    using linalg
    rotate_by: f32 = dt * 200
    c: vec3
    axis: vec3
    switch rotation.dir {
        case .RIGHT:
            c = vec3{1, rotation.row, 1}
            axis = vec3{0, 1, 0}
            if rotation.amount + rotate_by > 90 {
                rotate_by = 90 - rotation.amount
            }
        case .LEFT:
            c = vec3{1, rotation.row, 1}
            axis = vec3{0, 1, 0}
            rotate_by *= -1
            if rotation.amount + rotate_by < -90 {
                rotate_by = -90 - rotation.amount
            }
        case .UP:
            c = vec3{rotation.row, 1, 1}
            axis = vec3{1, 0, 0}
            if rotation.amount + rotate_by > 90 {
                rotate_by = 90 - rotation.amount
            }
        case .DOWN:
            c = vec3{rotation.row, 1, 1}
            axis = vec3{1, 0, 0}
            rotate_by *= -1
            if rotation.amount + rotate_by < -90 {
                rotate_by = -90 - rotation.amount
            }
        case .NONE: panic("Rotate called with rotation.NONE")
    }
    for i in 0..<27 {
        location := &model.instance_positions[i]
        if location[int(axis[1])] == rotation.row {
            r := matrix3_rotate_f32(to_radians(rotate_by), axis)
            p_prime := c + r*(location^-c)
            model.instance_rotations[i][int(axis[0])] += rotate_by
            location^ = p_prime
        }
    }
    rotation.amount += rotate_by
}

update :: proc(state: ^AppState, dt: f32) {
    rotation_done := false
    if state.rotation.dir != .NONE {
        if abs(state.rotation.amount) < 90 do rotate(&state.renderer.model, &state.rotation, dt)
        else {
            state.rotation.dir = .NONE
            state.rotation.amount = 0
            rotation_done = true
        }
    }
    if rotation_done {
        for &pos, i in state.renderer.model.instance_positions {
            pos.x = abs(math.round_f32(pos.x))
            pos.y = abs(math.round_f32(pos.y))
            pos.z = abs(math.round_f32(pos.z))
        }
    }
    process_mouse(&state.renderer.camera)
    process_keyboard(&state.renderer.camera, dt)
}

process_keyboard :: proc(camera: ^Camera, dt: f32) {
    using sdl.Scancode
    speed: f32 = 6
    key_state := sdl.GetKeyboardState(nil)
    f, b, l, r, u, d: f32
    yaw_r, yaw_l, pitch_u, pitch_d : f32
    if key_state[W] {f = 1}
    if key_state[S] {b = 1}
    if key_state[A] {l = 1}
    if key_state[D] {r = 1}
    if key_state[LSHIFT] {u = 1}
    if key_state[SPACE] {d = 1}
    if key_state[RIGHT] {yaw_r = 1}
    if key_state[LEFT] {yaw_l = 1}
    if key_state[UP] {pitch_u = 1}
    if key_state[DOWN] {pitch_d = 1}
    fb := f-b
    lr := l-r
    ud := u-d
    yaw := yaw_r - yaw_l
    pitch := pitch_d - pitch_u
    yaw_cos := math.cos(math.to_radians(camera.yaw))
    yaw_sin := math.sin(math.to_radians(camera.yaw))
    camera.position +=  {
        ((lr * yaw_cos) + (-fb * yaw_sin)) * dt * speed, 
        ud * dt * speed,
        ((fb*yaw_cos) + (lr * yaw_sin)) * dt * speed
    }
    camera.pitch += (pitch_d-pitch_u) * dt * 100
    camera.yaw += (yaw_r-yaw_l) * dt * 100

}

process_mouse :: proc(camera: ^Camera) {
    x, y: f32
    _flags := sdl.GetRelativeMouseState(&x, &y)
    camera.yaw   += x * 0.05
    camera.pitch += y * 0.05
    if camera.pitch >  90 do camera.pitch =  90
    if camera.pitch < -90 do camera.pitch = -90
}