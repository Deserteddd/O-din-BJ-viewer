package obj_viewer

import "base:runtime"
import "core:log"
import "core:math/linalg"
import "core:time"
import sa "core:container/small_array"
import sdl "vendor:sdl3"
import im_sdl "shared:imgui/imgui_impl_sdl3"
import "core:fmt"
VSYNC :: false
default_context: runtime.Context

My_Union :: union {
	f32,
	int,
	Person_Data,
}

Person_Data :: struct {
	health: int,
	age: int,
}

main :: proc() {
    context.logger = log.create_console_logger()
    init()
    log.debugf("Program initialized successfully")
    scene := load_scene("savefile")
    run(&scene)
}

init :: proc() {
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

    g.renderer = RND_Init()
    for pipeline, i in g.renderer.pipelines do assert(pipeline != nil || i == .NONE)
    init_imgui()
    g.editor = {
        sidebar_left  = {{0, 0, 300, 720}},
        sidebar_right = {{1280-300, 0, 300, 720}}
    }

    g.player = create_player()

    g.heightmap = load_height_map("assets/height_map")
}

run :: proc(scene: ^Scene) {
    context.allocator = runtime.panic_allocator()
    free_all(context.temp_allocator)
    main_loop: for {
        defer {
            free_all(context.temp_allocator)
            g.lmb_down = false
            g.rmb_down = false
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
                        case .F11: toggle_fullscreen()
                    }
                    sa.append(&key_presses, KeyEvent{ev.key.scancode, ev.key.mod})
                case .MOUSE_BUTTON_DOWN: switch ev.button.button {
                    case 1: g.lmb_down = true
                    case 3: g.rmb_down = true
                }
                case .MOUSE_BUTTON_UP: switch ev.button.button {
                    case 1: stop_dragging()
                }
            }
        }

        if update(scene, key_presses) do break main_loop
        g.debug_info.draw_call_count = 0

        frame := frame_begin()
        defer frame_submit(frame)

        begin_3d(&frame)
        render_3D(scene^, frame)
        render_heightmap(frame)
        submit_3d(&frame)

        begin_2d(&frame)
        if g.mode == .EDIT {
            draw_editor(frame)
        } else {
            draw_crosshair(frame)
        }

        submit_2d(&frame)

        dragging := g.editor.dragging
        draw_imgui(scene, frame)
        if !dragging && g.editor.dragging do start_dragging()


        g.debug_info.frame_time = time.since(now)
        g.total_time += time.duration_seconds(g.debug_info.frame_time)
    }
}

update :: proc(scene: ^Scene, keys: KeyboardEvents) -> (exit: bool) {
    switch g.mode {
        case .PLAY:
            exit = update_game(scene, keys)
        case .EDIT:
            exit = update_editor(scene, keys)
    }
    return
}

update_game :: proc(scene: ^Scene, keys: KeyboardEvents) -> (exit: bool) {
    for elem in 0..<keys.len {
        key := keys.data[elem].key
        mod := keys.data[elem].mod
        #partial switch key {
            case .ESCAPE:
                toggle_mode()
            case .C:
                if .LCTRL in mod do return true
            case .Q:
                if !g.player.airborne do g.player.checkpoint = get_player_translation()
            case .E:
                reset_player_pos()
                g.player.noclip = false
            case .N: g.player.noclip = !g.player.noclip
        }
    }
    new_ticks := sdl.GetTicks();
    dt := f32(new_ticks - g.last_ticks) / 1000
    g.last_ticks = new_ticks
    update_player(scene^, dt)
    update_camera()

    g.debug_info.player_speed = linalg.length(g.player.speed)
    g.renderer.light.position = {
        g.player.position.x,
        g.player.bbox.max.y,
        g.player.position.z
    }
    return
}


toggle_mode :: proc() {
    switch g.mode {
        case .PLAY:
            assert(g.editor.dragging == false)
            g.mode = .EDIT
            ok := sdl.SetWindowRelativeMouseMode(g.window, false); assert(ok)
            win_size := get_window_size() / 2
            sdl.WarpMouseInWindow(g.window, win_size.x, win_size.y)
        case .EDIT:
            g.mode = .PLAY
            if g.editor.dragging do stop_dragging()
            ok := sdl.SetWindowRelativeMouseMode(g.window, true); assert(ok)

            // Update ticks so next call to update doesn't have a massive dt
            g.last_ticks = sdl.GetTicks()

            // Poll mouse state to prevent stutters after exiting edit mode
            _ = sdl.GetRelativeMouseState(nil, nil)
    }
}

reset_player_pos :: proc(at_origin := false) {
    if at_origin do g.player.position = 0; 
    else if g.player.checkpoint.x == 0 {
        g.player.position = g.player.checkpoint.x
    } else {
        g.player.position = g.player.checkpoint.x
        g.player.rotation = g.player.checkpoint.y
    }
    g.player.speed = 0
    g.player.bbox = AABB {
        min = g.player.position + {-0.3, 0, -0.3},
        max = g.player.position + {0.3, 2, 0.3}
    }
}