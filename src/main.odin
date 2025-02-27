package obj_viewer

import "base:runtime"
import "core:log"
import "core:math"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
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
    cube: Cube
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
    cube: Cube
    create_cube(&cube)
    state.renderer = renderer
    state.cube = cube
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


run :: proc(state: ^AppState) {
    last_ticks := sdl.GetTicks();
    second: f32 = 0
    frames := 0;
    wireframe := false
    main_loop: for {
        defer frames += 1
        ev: sdl.Event
        for sdl.PollEvent(&ev) {
            #partial switch ev.type {
                case .QUIT: 
                    break main_loop
                case .KEY_DOWN: #partial switch ev.key.scancode {
                    case .ESCAPE: break main_loop
                    case .Q: 
                        wireframe = !wireframe
                        build_pipeline(&state.renderer, wireframe)
                }
            }
        }
        new_ticks := sdl.GetTicks();
        delta_time := f32(new_ticks - last_ticks) / 1000
        second += delta_time
        if second >= 0.5 {
            fmt.println("fps:", frames * 2)
            second, frames = 0, 0
        }
        last_ticks = new_ticks
        update(state, delta_time)
        render(&state.renderer, &state.cube)
    }
}

update :: proc(state: ^AppState, dt: f32) {
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