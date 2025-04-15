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
DEBUG := false
FRAMES := 0
RENDERTIME := 0
PHYSICSTIME := 0
last_ticks := sdl.GetTicks();

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
    entities:           [dynamic]Entity,
    models:             [dynamic]Model,
    player_collisions:  []bool,
    checkpoint:         [2]vec3, // Position, Rotation
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
    slab := load_object("assets/ref_cube"); defer delete_obj(slab)
    add_model(slab, state)

    for i in 0..<5000 {
        create_entity(state, {.COLLIDER, .STATIC}, 0)
    }

    randomize_tile_positions(state)

    state.player_collisions = make([]bool, len(state.entities))
    init_imgui(state)
} 

randomize_tile_positions :: proc(state: ^AppState) {
    resert_player_pos(state, true)
    state.checkpoint = 0
    for &entity, i in state.entities {
        if i == 0 do continue
        entity.position = {
            random_range(-50, 50),
            random_range(0, 40),
            random_range(-50, 50)
        }
    }
}

init_imgui :: proc(state: ^AppState) {
    assert(state.renderer.window != nil)
    im.CHECKVERSION()
    im.CreateContext()
    using state.renderer
    im_sdl.InitForSDLGPU(window)
    im_sdlgpu.Init(&{
        Device = state.renderer.gpu,
        ColorTargetFormat = sdl.GetGPUSwapchainTextureFormat(gpu, window)
    })
}

run :: proc(state: ^AppState) {
    main_loop: for {
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
                        if !state.player.airborne {
                            state.checkpoint = {state.player.position, state.player.rotation}
                        }
                    case .E:
                        resert_player_pos(state)
                }
            }
        }
        update(state)
        RND_FrameBegin(&state.renderer)
        // now := time.now()
        RND_DrawEntities(state)
        // elapsed := time.since(now)
        RND_DrawBounds(state)

        wireframe := state.renderer.wireframe 
        RND_DrawUI(state)
        if wireframe != state.renderer.wireframe do RND_ToggleWireframe(&state.renderer)
        ok := RND_FrameSubmit(&state.renderer); assert(ok)
        // fmt.println(elapsed)
        if FRAMES % 60 == 0 {}
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

resert_player_pos :: proc(state: ^AppState, at_zero := false) {
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
        process_keyboard(state, dt)
        update_player(state, dt)
        update_camera(&state.player)
    }
}

update_player :: proc(state: ^AppState, dt: f32) {
    g: f32 = 16
    using state
    player.speed.y -= g*dt*2
    if player.speed.y < -10 do player.speed.y = -10
    delta_pos := player.speed * dt
    player.position += delta_pos
    player.bbox.min += delta_pos
    player.bbox.max += delta_pos

    player.airborne = true
    for entity, i in state.entities {
        entity_bbox := AABB {
            min = entity.model.bbox.min + entity.position,
            max = entity.model.bbox.max + entity.position
        }
        if aabbs_collide(player.bbox, entity_bbox) {
            mtv := resolve_aabb_collision_mtv(player.bbox, entity_bbox)
            for axis, j in mtv do if axis != 0 {
                player.speed[j] *= 0.95
                if j == 1 && axis > 0 { // This means we are standing on a block
                    player.airborne = false
                } 
            } 
            player.position += mtv
            player.bbox.min += mtv
            player.bbox.max += mtv
            state.player_collisions[i] = true
        } else {
            state.player_collisions[i] = false
        }
    }
    if player.position.y < -2 {
        resert_player_pos(state)
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
    yaw_cos := math.cos(math.to_radians(player.rotation.y))
    yaw_sin := math.sin(math.to_radians(player.rotation.y))
    player.rotation.x += (pitch_d-pitch_u) * dt * 100
    player.rotation.y += (yaw_r-yaw_l) * dt * 100
    if !player.airborne {
        fb := b-f; lr := r-l
        player.speed.y = (u-d)*move_speed * 0.15
        if key_state[LSHIFT] do move_speed *= 2
        player.speed.x += (lr * yaw_cos - fb * yaw_sin) * move_speed * dt
        player.speed.z += (lr * yaw_sin + fb * yaw_cos) * move_speed * dt
        player.speed *= 0.9
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