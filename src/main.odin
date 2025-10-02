package obj_viewer

import "base:runtime"
import "core:log"
import "core:math"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:math/linalg"
import "core:math/rand"
import "core:path/filepath"
import "core:time"
import sdl "vendor:sdl3"
import im "shared:imgui"
import im_sdl "shared:imgui/imgui_impl_sdl3"
import im_sdlgpu "shared:imgui/imgui_impl_sdlgpu3"

// Constants
WORLD_SIZE: vec3 = {100, 40, 100}
DEBUG_GPU :: true
PRESENT_MODE: sdl.GPUPresentMode = .VSYNC

// Globals
default_context: runtime.Context
FRAMES := 0
last_ticks := sdl.GetTicks();

main :: proc() {
    fmt.println("MAIN: initing")
    state: AppState
    init(&state)
    fmt.println("MAIN: init done")
    run(&state)
    fmt.println("MAIN: Exiting")
}

Model:: struct {
    format: ModelFormat,
    data: struct #raw_union {
        gltf: GLTFNode,
        obj:  OBJModel,
    },
}

AppState :: struct {
    player:             Player,
    renderer:           Renderer,
    debug_info:         DebugInfo,
    ui_context:         ^im.Context,
    models:             [dynamic]Model,
    gltf_meshes:        [dynamic]GLTFMesh,
    entities:           #soa[dynamic]Entity,
    checkpoint:         [2]vec3,                // Position, Rotation
    props:              Props,
}

// Replace with bit set
Props :: struct {
    ui_visible,
    attatch_light_to_player,
    lmb_pressed: bool
}

DebugInfo :: struct {
    frame_time:     time.Duration,
    rendered:       u32,
    player_speed:   f32,
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
    
    renderer = RND_Init({})
    player = create_player()
    ground := load_object("assets/ref_tris"); defer delete_obj(ground)
    slab   := load_object("assets/ref_cube"); defer delete_obj(slab)
    add_model(ground, state)
    add_model(slab, state)
    create_entity(state, 0, "ground")
    for i in 1..<(1<<11) do create_entity(state, 1, "slab")
    randomize_tile_positions(state)
    state.props.attatch_light_to_player = true
    init_imgui(state)
}

init_imgui :: proc(state: ^AppState) {
    assert(state.renderer.window != nil)
    if state.ui_context != nil {
        im_sdlgpu.Shutdown()
        im_sdl.Shutdown()
        im.Shutdown()
        im.DestroyContext(state.ui_context)
    }
    im.CHECKVERSION()
    state.ui_context = im.CreateContext()
    using state.renderer
    im_sdl.InitForSDLGPU(window)
    im_sdlgpu.Init(&{
        Device = state.renderer.gpu,
        ColorTargetFormat = sdl.GetGPUSwapchainTextureFormat(gpu, window)
    })
    style := im.GetStyle()
    for &color in style.Colors {
        color.rgb = linalg.pow(color.rgb, 2.2)
    }
}

run :: proc(state: ^AppState) {
    assert(state.gltf_meshes == nil)
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
                        toggle_ui(state)
                    case .Q:
                        if !state.player.airborne do state.checkpoint = get_player_translation(state.player)
                    case .E:
                        reset_player_pos(state)
                    case .F:
                        RND_ToggleFullscreen(state)
                    case .C:
                        if .LCTRL in ev.key.mod do break main_loop
                    case .N: state.player.noclip = !state.player.noclip
                }
                case .MOUSE_BUTTON_DOWN: if !state.props.ui_visible {
                    switch ev.button.button {
                        case 1:
                            state.props.lmb_pressed = true
                        case 3:
                            new := create_entity(state, 1, "slab")
                            set_entity_position(state, new, state.player.position)
                    }
                }
            }
        }

        update_camera(&state.player)
        update_vp(state)
        update(state)
        RND_FrameBegin(state)
        render_obj(state)
        RND_DrawGLTF(state)
        wireframe := .WIREFRAME in state.renderer.props
        RND_DrawUI(state)
        if wireframe != .WIREFRAME in state.renderer.props {
            build_obj_pipeline(&state.renderer)
            build_gltf_pipeline(&state.renderer)
        }
        state.debug_info.frame_time = time.since(now)
        ok := RND_FrameSubmit(&state.renderer); assert(ok)
    }
}

toggle_ui :: proc(state: ^AppState) {
    using state, state.props
    ui_visible = !ui_visible
    if ui_visible {
        ok := sdl.ShowCursor(); assert(ok)
        ok = sdl.SetWindowRelativeMouseMode(state.renderer.window, false); assert(ok)
        sdl.WarpMouseInWindow(state.renderer.window, 700, 90)
    } else {
        ok := sdl.HideCursor(); assert(ok)
        ok = sdl.SetWindowRelativeMouseMode(state.renderer.window, true); assert(ok)
    }
}

randomize_tile_positions :: proc(state: ^AppState) {
    static_collider_index := 0
    for &entity, i in state.entities {
        if i < 1 do continue
        entity.transform.translation = {
            random_range(-WORLD_SIZE.x, WORLD_SIZE.x),
            random_range(0, WORLD_SIZE.y),
            random_range(-WORLD_SIZE.z, WORLD_SIZE.z)
        }
    }
}

reset_player_pos :: proc(state: ^AppState, at_origin := false) {
    using state
    if at_origin do player.position = 0; 
    else if checkpoint.x == 0 {
        player.position = checkpoint.x
    } else {
        player.position = checkpoint.x
        player.rotation = checkpoint.y
    }
    player.speed = 0
    player.bbox = AABB {
        min = player.position + {-0.3, 0, -0.3},
        max = player.position + {0.3, 2, 0.3}
    }
}

update :: proc(state: ^AppState) {
    using state
    new_ticks := sdl.GetTicks();
    dt := f32(new_ticks - last_ticks) / 1000
    last_ticks = new_ticks
    if !props.ui_visible {
        update_player(state, dt)
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
