#+feature dynamic-literals
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
import sdl "vendor:sdl3"

default_context: runtime.Context

last_ticks := sdl.GetTicks();

main :: proc() {
    state: AppState
    init(&state)
    run(&state)
}

AppState :: struct {
    renderer: Renderer,
    objects: [dynamic]Object,
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

    asset_handle, err := os.open("assets", 0, 0); assert(err == nil)
    asset_dir: []os.File_Info
    asset_dir, err = os.read_dir(asset_handle, 0); assert(err == nil)
    fmt.println("File count: {}", len(asset_dir))
    objects: [dynamic]Object
    for file in asset_dir {
        split: []string; defer delete(split)
        split, err = strings.split(file.name, "."); assert(err == nil)
        if split[len(split)-1] == "obj" {
            obj_path := strings.concatenate({"assets/", file.name}); defer delete(obj_path)
            obj_data := load_obj(obj_path); defer destroy_obj(obj_data)
            append(&objects, RND_CreateObject(obj_data, renderer.gpu))
        }
    }
    state.objects = objects
}

run :: proc(state: ^AppState) {
    wireframe := false
    main_loop: for {
        ev: sdl.Event
        for sdl.PollEvent(&ev) {
            #partial switch ev.type {
                case .QUIT: 
                    break main_loop
                case .KEY_DOWN: #partial switch ev.key.scancode {
                    case .ESCAPE: break main_loop
                    case .F: 
                        wireframe = !wireframe
                        RND_SetWireframe(&state.renderer, wireframe)
                }
            }
        }

        update(state)

        RND_FrameBegin(&state.renderer)
        RND_DrawObjects(&state.renderer, state.objects[:])

        ok := RND_FrameSubmit(&state.renderer); assert(ok)
    }
}


update :: proc(state: ^AppState) {
    new_ticks := sdl.GetTicks();
    dt := f32(new_ticks - last_ticks) / 1000
    last_ticks = new_ticks
    process_mouse(&state.renderer.camera)
    process_keyboard(&state.renderer.camera, dt)
}

process_keyboard :: proc(camera: ^Camera, dt: f32) {
    using sdl.Scancode
    speed: f32 = 6
    key_state := sdl.GetKeyboardState(nil)
    f, b, l, r, u, d: f32
    yaw_r, yaw_l, pitch_u, pitch_d : f32
    if key_state[W] do f = 1
    if key_state[S] do b = 1
    if key_state[A] do l = 1
    if key_state[D] do r = 1
    if key_state[LSHIFT] do u = 1
    if key_state[SPACE] do d = 1
    if key_state[RIGHT] do yaw_r = 1
    if key_state[LEFT] do yaw_l = 1
    if key_state[UP] do pitch_u = 1
    if key_state[DOWN] do pitch_d = 1
    fb := f-b; lr := l-r; ud := d-u
    yaw_cos := math.cos(math.to_radians(camera.yaw))
    yaw_sin := math.sin(math.to_radians(camera.yaw))
    camera.position +=  {
        ((lr * yaw_cos) + (-fb * yaw_sin)) * dt * speed, ud * dt * speed,
        ((fb * yaw_cos) + ( lr * yaw_sin)) * dt * speed
    }
    camera.pitch += (pitch_d-pitch_u) * dt * speed
    camera.yaw   += (yaw_r-yaw_l) * dt * speed
}

process_mouse :: proc(camera: ^Camera) {
    x, y: f32
    _flags := sdl.GetRelativeMouseState(&x, &y)
    camera.yaw   += x * 0.05
    camera.pitch += y * 0.05
    if camera.pitch >  90 do camera.pitch =  90
    if camera.pitch < -90 do camera.pitch = -90
}