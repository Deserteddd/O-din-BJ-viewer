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
FRAMES := 0
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
    entities:       [dynamic]Entity,
    entity_physics: [dynamic]Physics,
    point_light: vec4, // Pos.xyz, intensity 0..1
    noclip: bool
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
    
    renderer := RND_Init({.FULLSCREEN})
    state.renderer = renderer
    state.point_light.w = 2
    player_entity := Entity { id = 0 }
    player_physics := Physics{flags = {.COLLIDER, .DYNAMIC}}
    append(&state.entities, player_entity)
    append(&state.entity_physics, player_physics)

    data := load_object("assets/box_world"); defer delete_obj(data)
    CreateEntity(data, state, {.COLLIDER, .STATIC})
    print_entities(state.entities,state.entity_physics)
}   

run :: proc(state: ^AppState) {
    main_loop: for {
        defer FRAMES += 1
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
        RND_DrawEntities(state)
        ok := RND_FrameSubmit(&state.renderer); assert(ok)
        if FRAMES % 240 == 0 {
            fmt.printfln("Position:\t{}\nSpeed:\t{}", 
                state.entity_physics[0].position,
                state.entity_physics[0].speed
            )
            fmt.println("Player is airborne:", .AIRBORNE in state.entity_physics[0].flags)
            fmt.println()
        }
    }
}

update :: proc(state: ^AppState) {
    using state
    assert(renderer.camera.position == state.entity_physics[0].position)
    new_ticks := sdl.GetTicks();
    dt := f32(new_ticks - last_ticks) / 1000
    last_ticks = new_ticks
    update_entity_physics(&entity_physics, dt)
    process_keyboard(state, dt)
    update_camera(&renderer.camera, &state.entity_physics[0])
}

update_entity_physics :: proc(physics_components: ^[dynamic]Physics, dt: f32) {
    for &physics, i in physics_components {
        using physics
        if .DYNAMIC in flags {
            g: f32 = 25
            speed.y += g*dt
            position += speed * dt
            if position.y > 10 {
                speed.y = 0
                position.y = 10
                flags -= {.AIRBORNE}
            } else if position.y < 10 {
                flags += {.AIRBORNE}
            }
        }
    }
}

process_keyboard :: proc(state: ^AppState, dt: f32) {
    using sdl.Scancode
    key_state := sdl.GetKeyboardState(nil)
    f, b, l, r, u: f32
    yaw_r, yaw_l, pitch_u, pitch_d : f32
    if !(.AIRBORNE in state.entity_physics[0].flags) {
        if key_state[W] do f = 1
        if key_state[S] do b = 1
        if key_state[A] do l = 1
        if key_state[D] do r = 1
    }
    if key_state[SPACE] do u = 1
    if key_state[RIGHT] do yaw_r = 1
    if key_state[LEFT] do yaw_l = 1
    if key_state[UP] do pitch_u = 1
    if key_state[DOWN] do pitch_d = 1
    fb := f-b; lr := l-r

    using state
    player_speed    := &entity_physics[0].speed
    player_rotation := &entity_physics[0].rotation
    yaw_cos := math.cos(math.to_radians(player_rotation.y))
    yaw_sin := math.sin(math.to_radians(player_rotation.y))

    player_rotation.x += (pitch_d-pitch_u) * dt * 100
    player_rotation.y += (yaw_r-yaw_l) * dt * 100
    if !(.AIRBORNE in entity_physics[0].flags) {
        if u == 1 do player_speed.y = -8
        move_speed: f32      = 75
        friction: f32 = 0.1
        player_speed.x += ((lr * yaw_cos) + (-fb * yaw_sin)) * dt * move_speed
        player_speed.z += ((fb * yaw_cos) + ( lr * yaw_sin)) * dt * move_speed
        player_speed.xz *= 1-friction
    }
    if key_state[E] do point_light.w += 0.005
    if key_state[Q] && point_light.w >= 0 do point_light.w -= 0.005 


}

update_camera :: proc(camera: ^Camera, player_physics: ^Physics) {
    x, y: f32
    _flags := sdl.GetRelativeMouseState(&x, &y)
    camera.rotation = player_physics.rotation
    camera.rotation.y   += x * 0.05
    camera.rotation.x += y * 0.05
    if camera.rotation.x >  90 do camera.rotation.x =  90
    if camera.rotation.x < -90 do camera.rotation.x = -90
    camera.position = player_physics.position
    player_physics.rotation = vec3{camera.rotation.x, camera.rotation.y, 0}
}

CreateEntity :: proc(data: ObjectData, state: ^AppState, physics_flags: PhysicsFlags) {
    entity: Entity
    entity.id = u32(len(state.entities))
    physics: Physics
    physics.flags = physics_flags
    append(&state.entity_physics, physics)

    // Create and upload texture
    using state.renderer
    tex_transfer_buffers: [4]^sdl.GPUTransferBuffer
    img_sizes: [4][2]i32
    i: int
    textures: [dynamic]^sdl.GPUTexture; defer if len(textures) == 0 do delete(textures)

    for i<len(data.texture_data.textures) {
        defer i += 1
        img_sizes[i] = data.texture_data.sizes[i]
        size := img_sizes[i]
        assert(size.x >= 1)
        assert(size.y >= 1)
        pixels := data.texture_data.textures[i]
        
        pixels_byte_size := u32(size.x * size.y * 4)
        texture := sdl.CreateGPUTexture(gpu, {
            type = .D2,
            format = .R8G8B8A8_UNORM,
            usage = {.SAMPLER},
            width = u32(size.x),
            height = u32(size.y),
            layer_count_or_depth = 1,
            num_levels = 1
        })

        append(&textures, texture)
        tex_transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
            usage = sdl.GPUTransferBufferUsage.UPLOAD,
            size = pixels_byte_size,
        }); assert(tex_transfer_buffer != nil)

        tex_transfer_mem := sdl.MapGPUTransferBuffer(gpu, tex_transfer_buffer, false); assert(tex_transfer_mem != nil)
        mem.copy(tex_transfer_mem, pixels, int(pixels_byte_size))
        sdl.UnmapGPUTransferBuffer(gpu, tex_transfer_buffer)
        tex_transfer_buffers[i] = tex_transfer_buffer
    }
    entity.model.textures = textures[:]

    // Create and upload buffers
    len_bytes, num_vertices: u32
    vertices: [dynamic]Vertex; defer delete(vertices)
    mesh_bounds := make([]u32, len(data.vertex_groups))
    for group, i in data.vertex_groups {
        len_bytes += u32(len(group)*size_of(Vertex))
        for vert in group {
            num_vertices += 1
            append(&vertices, vert)
        }
        mesh_bounds[i] = num_vertices
    }

    material_matrices := make([dynamic][4]vec4, 0, len(data.materials)); defer delete(material_matrices)
    for material in data.materials do append(&material_matrices, material_matrix(material))

    transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = len_bytes,
    }); assert(transfer_buffer != nil)
    copy_commands := sdl.AcquireGPUCommandBuffer(gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)
    vbo := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.VERTEX}, vertices[:])
    material_buffer := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.GRAPHICS_STORAGE_READ}, material_matrices[:])
    for j in 0..<i {
        sdl.UploadToGPUTexture(copy_pass, 
            {transfer_buffer = tex_transfer_buffers[j]},
            {texture = entity.model.textures[j], w = u32(img_sizes[j].x), h = u32(img_sizes[j].y), d = 1},
            false
        )
    }

    // End copy pass
    sdl.ReleaseGPUTransferBuffer(gpu, transfer_buffer)
    for j in 0..<i do sdl.ReleaseGPUTransferBuffer(gpu, tex_transfer_buffers[j])
    sdl.EndGPUCopyPass(copy_pass)
    ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)

    // Assignments
    entity.model.vbo = vbo
    entity.model.material_buffer = material_buffer
    entity.model.mesh_bounds = mesh_bounds
    append(&state.entities, entity)
}
