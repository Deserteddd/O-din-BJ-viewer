package obj_viewer

import "base:runtime"
import "core:log"
import "core:fmt"
import "core:math/linalg"
import "core:time"
import "core:math/rand"
import sdl "vendor:sdl3"
import im "shared:imgui"
import im_sdl "shared:imgui/imgui_impl_sdl3"
import im_sdlgpu "shared:imgui/imgui_impl_sdlgpu3"

// Constants
PRESENT_MODE: sdl.GPUPresentMode = .IMMEDIATE

// Globals
default_context: runtime.Context
g: Globals = {
    debug_draw = false,
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
    player:             Player,
    debug_info:         DebugInfo,
    renderer:           Renderer,
    ui_context:        ^im.Context,
    models:             [dynamic]OBJModel,
    entities:       #soa[dynamic]Entity,
    props:              Props,
    slabs:              u32,
    sprites:            [dynamic]Sprite,
    height_map:         ^HeightMap,
}

Props :: struct {
    ui_visible,
    attatch_light_to_player,
    draw_aabbs,
    lmb_pressed: bool
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
    ok = sdl.HideCursor(); assert(ok)
    ok = sdl.SetWindowRelativeMouseMode(g.window, true); assert(ok)

    g.gpu = sdl.CreateGPUDevice({.SPIRV}, g.debug_draw, nil); assert(g.gpu != nil)
    ok = sdl.ClaimWindowForGPUDevice(g.gpu, g.window); assert(ok)
    ok = sdl.SetGPUSwapchainParameters(g.gpu, g.window, .SDR_LINEAR, PRESENT_MODE); assert(ok)

    renderer = RND_Init()
    init_imgui(state)
    player = create_player()

    // load_scene(state, "savefile")
    slab := load_obj_model("assets/slab")
    append(&state.models, slab)

    for i in 0..<10000 {
        entity, ok := entity_from_model(state, "slab"); assert(ok)
        pos: vec3 = {
            rand.float32_range(-50, 50),
            rand.float32_range(0, 100),
            rand.float32_range(-50, 50)
        }
        
        set_entity_position(state, entity, pos)
    }

    state.props.attatch_light_to_player = true
    crosshair := load_sprite("assets/crosshair.png")
    append(&sprites, crosshair)
}

load_scene :: proc(state: ^AppState, save_file: string) {
    save_file := load_save_file("savefile")
    defer free_save_file(save_file)
    for asset in save_file.assets {
        model := load_obj_model(save_file.assets[asset])
        append(&state.models, model)
        for instance in save_file.instances {
            if instance.asset == asset {
                entity, ok := entity_from_model(state, asset); assert(ok)
                set_entity_position(state, entity, instance.position)
            }
        }
    }
}

init_imgui :: proc(state: ^AppState) {
    assert(g.window != nil)
    if state.ui_context != nil {
        im_sdlgpu.Shutdown()
        im_sdl.Shutdown()
        im.Shutdown()
        im.DestroyContext(state.ui_context)
    }
    im.CHECKVERSION()
    state.ui_context = im.CreateContext()
    using state.renderer
    im_sdl.InitForSDLGPU(g.window)
    im_sdlgpu.Init(&{
        Device = g.gpu,
        ColorTargetFormat = sdl.GetGPUSwapchainTextureFormat(g.gpu, g.window)
    })
    style := im.GetStyle()
    for &color in style.Colors {
        color.rgb = linalg.pow(color.rgb, 2.2)
    }
}

run :: proc(state: ^AppState) {
    paused: bool
    free_all(context.temp_allocator)
    using state

    main_loop: for {
        defer free_all(context.temp_allocator)
        defer g.frames += 1
        now := time.now()
        ev: sdl.Event
        for sdl.PollEvent(&ev) {
            im_sdl.ProcessEvent(&ev)
            #partial switch ev.type {
                case .QUIT: 
                    break main_loop
                case .KEY_DOWN: #partial switch ev.key.scancode {
                    case .ESCAPE:
                        toggle_ui(state)
                        if props.ui_visible do paused = true
                    case .Q:
                        if !player.airborne do player.checkpoint = get_player_translation(player)
                    case .E:
                        reset_player_pos(&player)
                    case .F:
                        RND_ToggleFullscreen(state)
                    case .C:
                        if .LCTRL in ev.key.mod do break main_loop
                    case .N: player.noclip = !player.noclip
                }
                case .MOUSE_BUTTON_DOWN: if !state.props.ui_visible {
                    switch ev.button.button {
                        case 1:
                            state.props.lmb_pressed = true
                        case 3:
                            new, ok := entity_from_model(state, "slab"); assert(ok)
                            set_entity_position(state, new, player.position)
                    }
                }
            }
        }
        vert_ubo := get_vertex_ubo_global(player)
        frag_ubo := create_frag_ubo(state)
        if !props.ui_visible {
            update_camera(&player)
            update(state, paused, vert_ubo.vp)
            paused = false
        }

        frame := frame_begin(vert_ubo, frag_ubo)
        defer frame_submit(frame)

        begin_3d(renderer, &frame)
        render_3D(state, &frame)
        submit_3d(&frame)
        assert(frame.render_pass == nil)

        begin_2d(state.renderer, &frame)
        for sprite in state.sprites {
            draw_sprite(sprite, frame)
        } 
        submit_2d(&frame)
        draw_imgui(state, frame)

        state.debug_info.frame_time = time.since(now)
    }
}

toggle_ui :: proc(state: ^AppState) {
    using state, state.props
    ui_visible = !ui_visible
    if ui_visible {
        ok := sdl.ShowCursor(); assert(ok)
        ok = sdl.SetWindowRelativeMouseMode(g.window, false); assert(ok)
        sdl.WarpMouseInWindow(g.window, 700, 90)
    } else {
        ok := sdl.HideCursor(); assert(ok)
        ok = sdl.SetWindowRelativeMouseMode(g.window, true); assert(ok)
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


update :: proc(state: ^AppState, unpaused: bool, vp: mat4) {
    using state
    debug_info.draw_call_count = 0
    new_ticks := sdl.GetTicks();
    dt := f32(new_ticks - g.last_ticks) / 1000
    if unpaused do dt = 0.01666
    g.last_ticks = new_ticks
    if !props.ui_visible {
        update_player(state, dt, vp)
    }
    debug_info.player_speed = linalg.length(player.speed)
    if props.attatch_light_to_player {
        renderer.light.position = {
            player.position.x,
            player.bbox.max.y,
            player.position.z
        }
    }
}
