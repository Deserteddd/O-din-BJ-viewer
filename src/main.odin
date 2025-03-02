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

Cube :: [3][3][3]int
create_cube :: proc(cube: ^Cube) {
    value := 0
    for i in 0..<3 {
        for j in 0..<3 {
            for k in 0..<3 {
                cube[i][j][k] = value
                value += 1
            }
        }
    }
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
    row: u8
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
                    case .Q:
                        if state.rotation.dir == .NONE do state.rotation.dir = .LEFT
                    case ._1:
                        if state.rotation.dir == .NONE do state.rotation.row = 0
                    case ._2:
                        if state.rotation.dir == .NONE do state.rotation.row = 1
                    case ._3:
                        if state.rotation.dir == .NONE do state.rotation.row = 2
                }
            }
        }


        if second >= 0.5 {
            fmt.println("fps:", frames * 2)
            second, frames = 0, 0
        }

        last_ticks = new_ticks
        update(state, delta_time)
        render(&state.renderer)
    }
}

rotate_horizontal :: proc(model: ^Model, rotation: ^Rotation, dt: f32) {
    using linalg
    rotate_by: f32 = dt * 300
    #partial switch rotation.dir {
        case .RIGHT:
            if rotation.amount + rotate_by > 90 {
                rotate_by = 90 - rotation.amount
            }
        case .LEFT:
            rotate_by *= -1
            if rotation.amount + rotate_by < -90 {
                rotate_by = -90 - rotation.amount
            }
    }
    for i in 0..<27 {
        location := model.instance_locations[i]
        if location.y == f32(rotation.row) {
            c := vec3{1, location.y, 1}
            r := matrix3_rotate_f32(to_radians(rotate_by), vec3{0, 1, 0})
            p_prime := c + r*(location-c)
            model.instance_rotations[i] += to_radians(rotate_by)
            model.instance_locations[i] = p_prime
        }
    }
    rotation.amount += rotate_by
}


update :: proc(state: ^AppState, dt: f32) {
    #partial switch state.rotation.dir {
        case .RIGHT:
            if state.rotation.amount < 90 do rotate_horizontal(&state.renderer.model, &state.rotation, dt)
            else {
                state.rotation.dir = .NONE
                state.rotation.amount = 0
            }
        case .LEFT:
            if state.rotation.amount > -90 do rotate_horizontal(&state.renderer.model, &state.rotation, dt)
            else {
                state.rotation.dir = .NONE
                state.rotation.amount = 0
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