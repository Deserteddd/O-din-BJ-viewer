package obj_viewer

import "base:runtime"
import "core:log"
import "core:math"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:math/linalg"
import "core:math/rand"
import "core:path/filepath"
import "core:time"
import sdl "vendor:sdl3"
import im "shared:imgui"
import im_sdl "shared:imgui/imgui_impl_sdl3"
import im_sdlgpu "shared:imgui/imgui_impl_sdlgpu3"

default_context: runtime.Context
FRAMES := 0
last_ticks := sdl.GetTicks();
WORLD_SIZE: vec3 = {250, 30, 250}

main :: proc() {
    state: AppState
    init(&state)
    fmt.println("MAIN: init done")
    run(&state)
    fmt.println("MAIN: Exiting")
}

AppState :: struct {
    mode:               AppMode,
    player:             Player,
    renderer:           Renderer,
    debug_info:         DebugInfo,
    ui_context:         ^im.Context,
    models:             [dynamic]Model,
    entities:           [dynamic]Entity,
    aabbs:              [dynamic]AABB,
    checkpoint:         [2]vec3, // Position, Rotation
}

DebugInfo :: struct {
    frame_time:     time.Duration,
    rendered:       u32,
}

AppMode :: enum u8 {
    GAME,
    MENU
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
    
    state.renderer = RND_Init({})
    state.player = create_player()
    ground := load_object("assets/ref_tris"); defer delete_obj(ground)
    add_model(ground, state)
    slab := load_object("assets/ref_cube"); defer delete_obj(slab)
    add_model(slab, state)

    create_entity(state, {.COLLIDER, .STATIC}, 0)
    for i in 0..<100_000 {
        create_entity(state, {.COLLIDER, .STATIC, .SHADOW_CASTER}, 1)
    }
    randomize_tile_positions(state)

    init_imgui(state)
}

randomize_tile_positions :: proc(state: ^AppState) {
    assert(len(state.aabbs) == len(state.entities))
    // reset_player_pos(state, true)
    // state.checkpoint = 0
    static_collider_index := 0
    for &entity, i in state.entities {
        if i < 1 do continue
        entity.position = {
            random_range(-WORLD_SIZE.x, WORLD_SIZE.x),
            random_range(0, WORLD_SIZE.y),
            random_range(-WORLD_SIZE.z, WORLD_SIZE.z)
        }
        state.aabbs[i] = AABB {
            min = entity.model.bbox.min + entity.position,
            max = entity.model.bbox.max + entity.position
        }
    }
}

init_imgui :: proc(state: ^AppState) {
    assert(state.renderer.window != nil)
    if state.ui_context != nil {
        im_sdlgpu.Shutdown()
        im_sdl.Shutdown()
        im.Shutdown()
        im.DestroyContext(state.ui_context)
        state.ui_context = nil
    }
    im.CHECKVERSION()
    state.ui_context = im.CreateContext()
    using state.renderer
    im_sdl.InitForSDLGPU(window)
    im_sdlgpu.Init(&{
        Device = state.renderer.gpu,
        ColorTargetFormat = sdl.GetGPUSwapchainTextureFormat(gpu, window)
    })
}

run :: proc(state: ^AppState) {
    main_loop: for {
        now := time.now()
        defer FRAMES += 1
        ev: sdl.Event
        for sdl.PollEvent(&ev) {
            im_sdl.ProcessEvent(&ev)
            #partial switch ev.type {
                case .QUIT: 
                    break main_loop
                case .KEY_DOWN: #partial switch ev.key.scancode {
                    case .ESCAPE:
                        switch_mode(state)
                    case .Q:
                        if !state.player.airborne do state.checkpoint = {state.player.position, state.player.rotation}
                    case .E:
                        reset_player_pos(state)
                    case .F:
                        RND_ToggleFullscreen(state)
                }
            }
        }
        update(state)
        RND_FrameBegin(&state.renderer)
        RND_DrawEntities(state)
        wireframe := state.renderer.wireframe 
        RND_DrawUI(state)
        if wireframe != state.renderer.wireframe do RND_ToggleWireframe(&state.renderer)
        ok := RND_FrameSubmit(&state.renderer); assert(ok)
        state.debug_info.frame_time = time.since(now)
    }
}

switch_mode :: proc(state: ^AppState) {
    if state.mode == .GAME do state.mode = .MENU
    else do state.mode = .GAME
    switch state.mode {
        case .GAME: {
            ok := sdl.HideCursor(); assert(ok)
            ok = sdl.SetWindowRelativeMouseMode(state.renderer.window, true); assert(ok)
        }
        case .MENU: {
            ok := sdl.ShowCursor(); assert(ok)
            ok = sdl.SetWindowRelativeMouseMode(state.renderer.window, false); assert(ok)
            sdl.WarpMouseInWindow(state.renderer.window, 700, 90)
        }
    }
}

reset_player_pos :: proc(state: ^AppState, at_zero := false) {
    using state
    if at_zero do player.position = 0; 
    else if checkpoint.x == 0 {
        player.position = checkpoint.x
    } else {
        player.position = checkpoint.x
        player.rotation = checkpoint.y
    }
    player.speed = 0
    player.bbox = AABB {
        min = player.position + {-0.2, 0, -0.2},
        max = player.position + {0.2, 2.1, 0.2}
    }
}

update :: proc(state: ^AppState) {
    using state
    new_ticks := sdl.GetTicks();
    dt := f32(new_ticks - last_ticks) / 1000
    last_ticks = new_ticks
    if state.mode == .GAME {
        process_keyboard(state)
        update_player(state, dt)
        update_camera(&state.player)
    }
}

process_keyboard :: proc(state: ^AppState) {
    using sdl.Scancode
    key_state := sdl.GetKeyboardState(nil)
    f, b, l, r, u: f32
    yaw_r, yaw_l, pitch_u, pitch_d : f32
    if key_state[W] do f = 1
    if key_state[S] do b = 1
    if key_state[A] do l = 1
    if key_state[D] do r = 1
    if key_state[SPACE] do u = 1
    if key_state[RIGHT] do yaw_r = 1
    if key_state[LEFT] do yaw_l = 1
    if key_state[UP] do pitch_u = 1
    if key_state[DOWN] do pitch_d = 1
    state.player.crouching = key_state[LCTRL]

    using state
    yaw_cos := math.cos(math.to_radians(player.rotation.y))
    yaw_sin := math.sin(math.to_radians(player.rotation.y))
    player.rotation.x += (pitch_d-pitch_u)
    player.rotation.y += (yaw_r-yaw_l)
    if !player.airborne {
        fb := b-f; lr := r-l
        if key_state[LSHIFT] {fb *= 2; lr *= 2}
        player.speed.y = u
        player.speed.x += (lr * yaw_cos - fb * yaw_sin)
        player.speed.z += (lr * yaw_sin + fb * yaw_cos)
    }
}

update_camera :: proc(player: ^Player) {
    x, y: f32
    using player
    _ = sdl.GetRelativeMouseState(&x, &y)
    rotation.y += x * 0.05
    rotation.x += y * 0.05
    if rotation.x >  90 do rotation.x =  90
    if rotation.x < -90 do rotation.x = -90
}