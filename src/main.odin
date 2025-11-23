package obj_viewer

import "base:runtime"
import "core:log"
import "core:fmt"
import "core:math/linalg"
import "core:time"
import sa "core:container/small_array"
import sdl "vendor:sdl3"
import im "shared:imgui"
import im_sdl "shared:imgui/imgui_impl_sdl3"

// Globals
VSYNC :: true
default_context: runtime.Context
g: Globals = {
    fov = 90
}

KeyEvent :: struct {
    key: sdl.Scancode,
    mod: sdl.Keymod
}

KeyboardEvents :: sa.Small_Array(64, KeyEvent)

DebugInfo :: struct {
    frame_time:         time.Duration,
    draw_call_count:    u32,
    player_speed:       f32,
}

Renderer :: struct {
    r2: Renderer2,
    r3: Renderer3,
    fallback_texture:   ^sdl.GPUTexture,
    default_sampler:    ^sdl.GPUSampler,
}

AppState :: struct {
    editor:             Editor,
    player:             Player,
    debug_info:         DebugInfo,
    renderer:           Renderer,
    ui_context:        ^im.Context,
    sprites:            [dynamic]Sprite,
    models:             [dynamic]OBJModel,
    entities:       #soa[dynamic]Entity,
}

main :: proc() {
    context.logger = log.create_console_logger()
    fmt.println("MAIN: initing")
    state: AppState = {}
    init(&state)
    fmt.println("MAIN: init done")
    run(&state)
    fmt.println("MAIN: Exiting")
}

init :: proc(state: ^AppState) {
    using state
    default_context = context
    sdl.SetLogPriorities(.VERBOSE)
    sdl.SetLogOutputFunction(
        proc "c" (userdata: rawptr, category: sdl.LogCategory, priority: sdl.LogPriority, message: cstring) {
            context = default_context
            log.debugf("SDL {} [{}]", category, priority, message)
        }, nil
    )
    ok := sdl.Init({.VIDEO}); assert(ok)
    window_flags: sdl.WindowFlags
    g.window = sdl.CreateWindow("Demo window", 1280, 720, window_flags); assert(g.window != nil)
    ok = sdl.SetWindowRelativeMouseMode(g.window, true); assert(ok)

    g.gpu = sdl.CreateGPUDevice({.SPIRV}, ODIN_DEBUG, nil); assert(g.gpu != nil)
    ok = sdl.ClaimWindowForGPUDevice(g.gpu, g.window); assert(ok)
    present_mode: sdl.GPUPresentMode = VSYNC? .VSYNC : .IMMEDIATE
    ok = sdl.SetGPUSwapchainParameters(g.gpu, g.window, .SDR_LINEAR, present_mode); assert(ok)

    renderer = RND_Init()
    init_imgui(state)
    editor = {
        sidebar_left  = {{0, 0, 300, 720}},
        sidebar_right = {{1280-300, 0, 300, 720}}
    }

    player = create_player()
    load_scene(state, "savefile")
}

run :: proc(state: ^AppState) {
    context.allocator = runtime.panic_allocator()
    free_all(context.temp_allocator)
    using state
    main_loop: for {
        defer {
            free_all(context.temp_allocator)
            g.lmb_down = false
            g.rmb_down = false
            g.frame += 1
        }
        now := time.now()
        key_presses: KeyboardEvents
        ev: sdl.Event
        for sdl.PollEvent(&ev) {
            im_sdl.ProcessEvent(&ev)
            #partial switch ev.type {
                case .QUIT: 
                    break main_loop
                case .KEY_DOWN: 
                    #partial switch ev.key.scancode {
                        case .F11: toggle_fullscreen(state)
                    }
                    sa.append(&key_presses, KeyEvent{ev.key.scancode, ev.key.mod})
                case .MOUSE_BUTTON_DOWN: switch ev.button.button {
                    case 1: g.lmb_down = true
                    case 3: g.rmb_down = true
                }
                case .MOUSE_BUTTON_UP: switch ev.button.button {
                    case 1: stop_dragging(&state.editor)
                }
            }
        }
        if update(state, key_presses) do break main_loop
        vert_ubo := get_vertex_ubo_global(player)
        debug_info.draw_call_count = 0
        frag_ubo := create_frag_ubo(state)
        frame := frame_begin(vert_ubo, frag_ubo)
        defer frame_submit(frame)

        begin_3d(renderer, &frame)
        render_3D(state, &frame)
        submit_3d(&frame)
        assert(frame.render_pass == nil)

        begin_2d(renderer, &frame)
        if g.mode == .EDIT {
            draw_editor(&state.editor, renderer, frame)
        } else {
            draw_crosshair(renderer.r2, frame)
        }
        submit_2d(&frame)
        dragging := editor.dragging
        draw_imgui(state, frame)
        if !dragging && editor.dragging do start_dragging(&editor)
        state.debug_info.frame_time = time.since(now)
    }
}

update :: proc(state: ^AppState, keys: KeyboardEvents) -> (exit: bool) {
    using state
    switch g.mode {
        case .PLAY:
            exit = update_game(state, keys)
        case .EDIT:
            exit = update_editor(state, keys)
    }
    return
}

update_game :: proc(state: ^AppState, keys: KeyboardEvents) -> (exit: bool) {
    using state
    for elem in 0..<keys.len {
        key := keys.data[elem].key
        mod := keys.data[elem].mod
        #partial switch key {
            case .ESCAPE:
                toggle_mode(state)
            case .C:
                if .LCTRL in mod do return true
            case .Q:
                if !player.airborne do player.checkpoint = get_player_translation(player)
            case .E:
                reset_player_pos(&player)
                player.noclip = false
            case .N: player.noclip = !player.noclip
        }
    }
    new_ticks := sdl.GetTicks();
    dt := f32(new_ticks - g.last_ticks) / 1000
    g.last_ticks = new_ticks
    update_player(state, dt)
    update_camera(&player)

    debug_info.player_speed = linalg.length(player.speed)
    renderer.r3.light.position = {
        player.position.x,
        player.bbox.max.y,
        player.position.z
    }
    return
}


toggle_mode :: proc(state: ^AppState) {
    switch g.mode {
        case .PLAY:
            assert(state.editor.dragging == false)
            g.mode = .EDIT
            ok := sdl.SetWindowRelativeMouseMode(g.window, false); assert(ok)
            win_size := get_window_size() / 2
            sdl.WarpMouseInWindow(g.window, win_size.x, win_size.y)
        case .EDIT:
            g.mode = .PLAY
            if state.editor.dragging do stop_dragging(&state.editor)
            ok := sdl.SetWindowRelativeMouseMode(g.window, true); assert(ok)

            // Update ticks so next call to update doesn't have a massive dt
            g.last_ticks = sdl.GetTicks()

            // Poll mouse state to prevent stutters after exiting edit mode
            _ = sdl.GetRelativeMouseState(nil, nil)
    }
}

reset_player_pos :: proc(player: ^Player, at_origin := false) {
    if at_origin do player.position = 0; 
    else if player.checkpoint.x == 0 {
        player.position = player.checkpoint.x
    } else {
        player.position = player.checkpoint.x
        player.rotation = player.checkpoint.y
    }
    player.speed = 0
    player.bbox = AABB {
        min = player.position + {-0.3, 0, -0.3},
        max = player.position + {0.3, 2, 0.3}
    }
}