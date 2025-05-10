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

default_context: runtime.Context
FRAMES := 0
last_ticks := sdl.GetTicks();

main :: proc() {
    state: AppState
    init(&state)
    fmt.println("MAIN: init done")
    run(&state)
    // fmt.println("MAIN: Exiting")
}

AppState :: struct {
    player:             Player,
    renderer:           Renderer,
    debug_info:         DebugInfo,
    ui_context:         ^im.Context,
    models:             [dynamic]Model,
    entities:           #soa[dynamic]Entity,
    checkpoint:         [2]vec3,                // Position, Rotation
    ui_visible:         bool,
    gltf_meshes:        []GLTFMesh,
    gltf_node:          GLTFNode
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
    meshes, root := load_gltf("assets/CesiumMilkTruck.glb", renderer.gpu)
    gltf_meshes = meshes
    gltf_node = root
    ground := load_object("assets/ref_tris"); defer delete_obj(ground)
    slab   := load_object("assets/ref_cube"); defer delete_obj(slab)
    add_obj_model(ground, state)
    add_obj_model(slab, state)
    create_entity(state, 0)
    init_imgui(state)
}

release :: proc(state: ^AppState) {
    using state
    for &model in models {
        sdl.ReleaseGPUBuffer(renderer.gpu, model.vbo)
        sdl.ReleaseGPUBuffer(renderer.gpu, model.material_buffer)
        for &texture in model.textures {
            sdl.ReleaseGPUTexture(renderer.gpu, texture)
        }
    }
    delete_soa(state.entities)
    delete(state.models)
    RND_Destroy(state)
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
                        if !state.player.airborne do state.checkpoint = {state.player.position, state.player.rotation}
                    case .E:
                        reset_player_pos(state)
                    case .F:
                        RND_ToggleFullscreen(state)
                    case .C:
                        if .LCTRL in ev.key.mod {
                            release(state)
                            return
                        }
                }
                case .MOUSE_BUTTON_DOWN: if ev.button.button == 1 && !state.ui_visible{
                    new := create_entity(state, 1)
                    set_entity_position(state, new, state.player.bbox.min)
                }
            }
        }
        update(state)
        RND_FrameBegin(state)
        RND_DrawEntities(state)
        RND_DrawGLTF(state)
        wireframe := .WIREFRAME in state.renderer.props
        RND_DrawUI(state)
        if wireframe != .WIREFRAME in state.renderer.props {
            build_3D_pipeline(&state.renderer)
        }
        state.debug_info.frame_time = time.since(now)
        ok := RND_FrameSubmit(&state.renderer); assert(ok)
    }
}

toggle_ui :: proc(state: ^AppState) {
    using state
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
    // assert(len(state.aabbs) == len(state.entities))
    static_collider_index := 0
    for &entity, i in state.entities {
        if i < 1 do continue
        entity.position = {
            random_range(-WORLD_SIZE.x, WORLD_SIZE.x),
            random_range(0, WORLD_SIZE.y),
            random_range(-WORLD_SIZE.z, WORLD_SIZE.z)
        }
        entity.aabb = AABB {
            min = entity.model.bbox.min + entity.position,
            max = entity.model.bbox.max + entity.position
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
        min = player.position + {-0.2, 0, -0.2},
        max = player.position + {0.2, 2.1, 0.2}
    }
}

update :: proc(state: ^AppState) {
    using state
    new_ticks := sdl.GetTicks();
    dt := f32(new_ticks - last_ticks) / 1000
    last_ticks = new_ticks
    if !ui_visible {
        update_camera(&state.player)
        wish_speed := player_wish_speed(state.player)
        update_player(state, &wish_speed, dt)
    }
    debug_info.player_speed = linalg.length(player.speed)
}

player_wish_speed :: proc(player: Player) -> vec3 {
    using sdl.Scancode
    key_state := sdl.GetKeyboardState(nil)
    wish_speed: vec3
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

    fb := b-f; lr := r-l

    yaw_cos := math.cos(math.to_radians(player.rotation.y))
    yaw_sin := math.sin(math.to_radians(player.rotation.y))

    if !player.airborne do wish_speed.y = u
    wish_speed.x += (lr * yaw_cos - fb * yaw_sin)
    wish_speed.z += (lr * yaw_sin + fb * yaw_cos)
    return wish_speed
}

update_camera :: proc(player: ^Player) {
    x, y: f32
    using player
    _ = sdl.GetRelativeMouseState(&x, &y)
    rotation.y += x * 0.03
    rotation.x += y * 0.03
    if rotation.x >  90 do rotation.x =  90
    if rotation.x < -90 do rotation.x = -90
}