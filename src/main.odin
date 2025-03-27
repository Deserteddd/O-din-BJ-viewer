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
TEST := false
last_ticks := sdl.GetTicks();



main :: proc() {
    if !TEST {
        state: AppState
        init(&state)
        fmt.println("MAIN: init done")
        run(&state)
        fmt.println("MAIN: Exiting")
        return
    } else {
        asset_handle := os.open("assets", 0, 0) or_else panic("os error opening asset dir")
        asset_dir := os.read_dir(asset_handle, 0) or_else panic("couln't read asset dir")
        objects := make([]ObjectData, len(asset_dir))
        for file, i in asset_dir {
            if file.is_dir {
                fmt.printfln("\n[ {} ]", i+1)
                start := time.now()
                objects[i] = load_object(file.fullpath)
                duration := time.since(start)
                fmt.printfln("Load time from main: {}", duration)
            }
        }
    }
}

AppState :: struct {
    renderer: Renderer,
    entities: [dynamic]Entity,
    point_light: vec4 // Pos.xyz, intensity 0..1
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
    
    // state.point_light = {14, 2, 10}
    renderer := RND_Init({.FULLSCREEN, .DRAW_UI})
    state.renderer = renderer

    data := load_object("assets/ref_tris"); defer delete_obj(data)
    append(&state.entities, CreateObject(data, state.renderer.gpu)); delete_obj(data)
    state.entities[0].position = {1.5, 12, -20}
    state.entities[0].rotation.y = 180

    data = load_object("assets/22-moto_simple");
    append(&state.entities, CreateObject(data, state.renderer.gpu)); delete_obj(data)
    state.entities[1].position = {0, 7, -20}

    data = load_object("assets/box_world"); 
    append(&state.entities, CreateObject(data, state.renderer.gpu))
}   

run :: proc(state: ^AppState) {
    main_loop: for {
        ev: sdl.Event
        for sdl.PollEvent(&ev) {
            #partial switch ev.type {
                case .QUIT: 
                    break main_loop
                case .KEY_DOWN: #partial switch ev.key.scancode {
                    case .ESCAPE: break main_loop
                    case .F: 
                        RND_ToggleWireframe(&state.renderer)
                }
            }
        }

        update(state)

        RND_FrameBegin(&state.renderer)
        RND_DrawEntities(&state.renderer, state.entities[:], state.point_light)
        draw_ui(&state.renderer)

        ok := RND_FrameSubmit(&state.renderer); assert(ok)
    }
}


update :: proc(state: ^AppState) {
    new_ticks := sdl.GetTicks();
    dt := f32(new_ticks - last_ticks) / 1000
    last_ticks = new_ticks
    process_mouse(&state.renderer.camera)
    process_keyboard(state, dt)
}

process_keyboard :: proc(state: ^AppState, dt: f32) {
    using sdl.Scancode
    key_state := sdl.GetKeyboardState(nil)
    speed: f32 = 2
    if key_state[LSHIFT] do speed = 6
    f, b, l, r, u, d: f32
    yaw_r, yaw_l, pitch_u, pitch_d : f32
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
    fb := f-b; lr := l-r; ud := d-u
    using state.renderer
    yaw_cos := math.cos(math.to_radians(camera.yaw))
    yaw_sin := math.sin(math.to_radians(camera.yaw))
    camera.position +=  {
        ((lr * yaw_cos) + (-fb * yaw_sin)) * dt * speed, ud * dt * speed,
        ((fb * yaw_cos) + ( lr * yaw_sin)) * dt * speed
    }
    camera.pitch += (pitch_d-pitch_u) * dt * speed * 30
    camera.yaw   += (yaw_r-yaw_l) * dt * speed * 30
    
    if key_state[E] do state.point_light.w += 0.005
    if key_state[Q] && state.point_light.w >= 0 do state.point_light.w -= 0.005 
}

process_mouse :: proc(camera: ^Camera) {
    x, y: f32
    _flags := sdl.GetRelativeMouseState(&x, &y)
    camera.yaw   += x * 0.05
    camera.pitch += y * 0.05
    if camera.pitch >  90 do camera.pitch =  90
    if camera.pitch < -90 do camera.pitch = -90
}