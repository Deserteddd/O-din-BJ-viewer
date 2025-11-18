package obj_viewer

import "base:runtime"
import "core:log"
import "core:fmt"
import "core:math/linalg"
import "core:time"
import "core:mem"
import "core:math"
import sdl "vendor:sdl3"
import im "shared:imgui"
import im_sdl "shared:imgui/imgui_impl_sdl3"

// Constants
PRESENT_MODE: sdl.GPUPresentMode = .IMMEDIATE

// Globals
default_context: runtime.Context
g: Globals = {
    fov = 90
}

main :: proc() {
    fmt.println("MAIN: initing")
    state: AppState = {}
    init(&state)
    fmt.println("MAIN: init done")
    run(&state)
    fmt.println("MAIN: Exiting")
}

AppState :: struct {
    editor:             Editor,
    player:             Player,
    debug_info:         DebugInfo,
    renderer:           Renderer,
    ui_context:        ^im.Context,
    height_map:        ^HeightMap,
    sprites:            [dynamic]Sprite,
    models:             [dynamic]OBJModel,
    entities:       #soa[dynamic]Entity,
}

Editor :: struct {
    selected_entity: i32,
    sidebar:         Rect,
    dragging:        bool,
    drag_position:   vec2,
    drag_start:      vec2
}

DebugInfo :: struct {
    frame_time:         time.Duration,
    draw_call_count:    u32,
    player_speed:       f32,
}

init :: proc(state: ^AppState) {
    using state
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
    window_flags: sdl.WindowFlags
    g.window = sdl.CreateWindow("Demo window", 1280, 720, window_flags); assert(g.window != nil)
    ok = sdl.SetWindowRelativeMouseMode(g.window, true); assert(ok)

    g.gpu = sdl.CreateGPUDevice({.SPIRV}, ODIN_DEBUG, nil); assert(g.gpu != nil)
    ok = sdl.ClaimWindowForGPUDevice(g.gpu, g.window); assert(ok)
    ok = sdl.SetGPUSwapchainParameters(g.gpu, g.window, .SDR_LINEAR, PRESENT_MODE); assert(ok)

    renderer = RND_Init()
    init_imgui(state)
    editor.sidebar = {0, 0, 300, 720}
    player = create_player()

    load_scene(state, "savefile")
}



start_dragging :: proc(editor: ^Editor) {
    editor.dragging = true
    x, y: f32
    _ = sdl.GetMouseState(&x, &y)
    editor.drag_position = {x, y}
    editor.drag_start    = {x, y}
    ok := sdl.SetWindowRelativeMouseMode(g.window, true); assert(ok)
    _ = sdl.GetRelativeMouseState(nil, nil)
}

stop_dragging :: proc(editor: ^Editor) {
    if editor.dragging == false do return
    editor.dragging = false
    editor.drag_position = 0
    ok := sdl.SetWindowRelativeMouseMode(g.window, false); assert(ok)
    sdl.WarpMouseInWindow(g.window, editor.drag_start.x, editor.drag_start.y)
}

run :: proc(state: ^AppState) {
    when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				for _, entry in track.allocation_map {
					fmt.eprintf("%v leaked %v bytes\n", entry.location, entry.size)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

    free_all(context.temp_allocator)
    using state
    main_loop: for {
        defer {
            free_all(context.temp_allocator)
            g.lmb_down = false
            g.rmb_down = false
        }
        now := time.now()
        dragging := editor.dragging
        ev: sdl.Event
        for sdl.PollEvent(&ev) {
            im_sdl.ProcessEvent(&ev)
            #partial switch ev.type {
                case .QUIT: 
                    break main_loop
                case .KEY_DOWN: #partial switch ev.key.scancode {
                    case .ESCAPE:
                        if editor.dragging {
                            stop_dragging(&editor) 
                        } else {
                            toggle_ui(state)
                        }
                    case .Q:
                        if !player.airborne do player.checkpoint = get_player_translation(player)
                    case .E:
                        reset_player_pos(&player)
                        player.noclip = false
                    case .F:
                        RND_ToggleFullscreen(state)
                    case .C:
                        if .LCTRL in ev.key.mod do break main_loop
                    case .N: player.noclip = !player.noclip
                    case .DELETE:
                        if g.mode == .EDIT do remove_selected_entity(state)
                    case .RETURN:
                        if editor.dragging do stop_dragging(&editor)
                }
                case .MOUSE_BUTTON_DOWN: switch ev.button.button {
                    case 1: g.lmb_down = true
                    case 3: g.rmb_down = true
                }
                case .MOUSE_BUTTON_UP: switch ev.button.button {
                    case 1: stop_dragging(&state.editor)
                }
            }
        }
        update(state)

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
            draw_rect(editor.sidebar, frame)
        } else {
            draw_crosshair(renderer, frame)
        }
        submit_2d(&frame)

        draw_imgui(state, frame)

        if !dragging && editor.dragging do start_dragging(&state.editor)
        state.debug_info.frame_time = time.since(now)
    }
    write_save_file(state^)
}

update :: proc(state: ^AppState) {
    using state
    switch g.mode {
        case .PLAY:
            update_game(state)
        case .EDIT:
            update_editor(state)
    }
}

update_editor :: proc(state: ^AppState) {
    using state
    m_pos: vec2
    if g.lmb_down {
        win_size := get_window_size()
        _ = sdl.GetMouseState(&m_pos.x, &m_pos.y)
        if m_pos.x > editor.sidebar.width {
            ray_origin, ray_dir := ray_from_screen(player, m_pos, win_size)
            closest_hit: f32 = math.F32_MAX
            closest_entity: i32 = -1
            for &entity in entities {
                aabbs := entity_aabbs(entity)
                for aabb in aabbs {
                    intersection := ray_intersect_aabb(ray_origin, ray_dir, aabb)
                    if intersection != -1 && intersection < closest_hit {
                        closest_hit = intersection
                        closest_entity = entity.id
                    }

                }
            }
            editor.selected_entity = closest_entity
        }
    }
    if editor.dragging {
        m_pos: vec2
        _ = sdl.GetRelativeMouseState(&m_pos.x, &m_pos.y)
        editor.drag_position += m_pos
        io := im.GetIO()
        im.IO_AddMousePosEvent(io, editor.drag_position.x, editor.drag_position.y)
    }
}

update_game :: proc(state: ^AppState) {
    using state
    new_ticks := sdl.GetTicks();
    dt := f32(new_ticks - g.last_ticks) / 1000
    g.last_ticks = new_ticks
    update_player(state, dt)
    update_camera(&player)

    if g.rmb_down {
        new, ok := entity_from_model(state, "slab"); assert(ok)
        set_entity_transform(state, new, player.position)
    }

    debug_info.player_speed = linalg.length(player.speed)
    renderer.light.position = {
        player.position.x,
        player.bbox.max.y,
        player.position.z
    }
}


toggle_ui :: proc(state: ^AppState) {
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