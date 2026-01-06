package obj_viewer

import "base:runtime"
import "core:log"
import "core:math/linalg"
import "core:time"
import sa "core:container/small_array"
import sdl "vendor:sdl3"
import im_sdl "shared:imgui/imgui_impl_sdl3"

VSYNC :: true
default_context: runtime.Context

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
            level: log.Level
            #partial switch priority {
                case .DEBUG: level = .Debug
                case .INFO: level = .Info
                case .WARN: level = .Warning
                case .ERROR: level = .Error
                case .CRITICAL: level = .Fatal
            }
            log.logf(level, "SDL %v:\t%v (%v)", category, message, level)
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

    init_editor({1280, 720})

    g.player = create_player()
    // g.ocean  = load_height_map("")
}

run :: proc(scene: ^Scene) {
    main_loop: for {
        defer {
            free_all(context.temp_allocator)
            g.mb_click = .NONE
            g.editor.tab_flag = false
        }
        now := time.now()
        key_presses: KeyboardEvents
        ev: sdl.Event
        for sdl.PollEvent(&ev) {
            if !(ev.type == .KEY_DOWN && (ev.key.repeat || ev.key.scancode == .TAB)) {
                im_sdl.ProcessEvent(&ev)
            }
            #partial switch ev.type {
                case .QUIT: 
                    break main_loop
                case .KEY_DOWN: 
                    #partial switch ev.key.scancode {
                        case .F11: toggle_fullscreen()
                    }
                    sa.append(&key_presses, KeyEvent{ev.key.scancode, ev.key.mod, ev.key.repeat})
                case .MOUSE_BUTTON_DOWN: switch ev.button.button {
                    case 1: g.mb_click = .LEFT
                    case 3: g.mb_click = .RIGHT
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
        render_plane(g.ocean, frame)
        submit_3d(&frame)

        begin_2d(&frame)
        if g.mode == .EDIT {
            draw_active_aabb(scene^, frame)
            draw_editor(frame)
        } else {
            draw_crosshair(frame)
        }

        submit_2d(&frame)
        draw_imgui(scene, frame)

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
    if g.mb_click == .RIGHT {
        spawn(scene, true)
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