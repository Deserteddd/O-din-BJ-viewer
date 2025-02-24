package obj_viewer

import "base:runtime"
import "core:log"
import "core:math/linalg"
import "core:math"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"

default_context: runtime.Context

vert_shader_code := #load("../shaders/spv/triangle.vert.spv")
frag_shader_code := #load("../shaders/spv/triangle.frag.spv")

main :: proc() {
    state := init(true) // param: Fullscreen
    run(&state)
    sdl.ReleaseGPUBuffer(state.gpu, state.vbo)
    sdl.ReleaseGPUBuffer(state.gpu, state.ibo)
}

AppState :: struct {
    gpu: ^sdl.GPUDevice,
    window: ^sdl.Window,
    pipeline: ^sdl.GPUGraphicsPipeline,
    vbo: ^sdl.GPUBuffer,
    ibo: ^sdl.GPUBuffer,
    num_indices: u32,
    object_props: ObjectProps,
    active: uint,
    depth_texture: ^sdl.GPUTexture,
    wireframe: bool,
    camera: Camera,
    tex_sampler: ^sdl.GPUSampler,
    texture: ^sdl.GPUTexture
}

vec2 :: [2]f32
vec3 :: [3]f32

Vertex :: struct {
    position: vec3,
    normal: vec3,
    uv: vec2
}
ObjectData :: struct {
    vertices: []Vertex,
    indices: []u32
}

ObjectProps :: struct {
    position: [3]f32,
    rotation: f32,
}

UBO :: struct {
    view: matrix[4,4]f32,
    proj: matrix[4,4]f32,
    model: matrix[4,4]f32
}

Camera :: struct {
    position: vec3,
    yaw: f32,
    pitch: f32
}

init :: proc(fullscreen: bool) -> AppState {
    state: AppState
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
    win_flags: sdl.WindowFlags
    if fullscreen {win_flags = {.MOUSE_GRABBED, .FULLSCREEN}} else do win_flags = {.MOUSE_GRABBED}
    window := sdl.CreateWindow("Hello Odin", 1920, 1080, win_flags); assert(window != nil)
    ok = sdl.HideCursor(); assert(ok)
    ok = sdl.SetWindowRelativeMouseMode(window, true); assert(ok)
    width, height: i32
    sdl.GetWindowSize(window, &width, &height)
    gpu := sdl.CreateGPUDevice({.SPIRV}, false, nil); assert(gpu != nil)
    ok = sdl.ClaimWindowForGPUDevice(gpu, window); assert(ok)

    state.window = window
    state.gpu = gpu

    load_next_obj(&state)
    
    depth_texture := sdl.CreateGPUTexture(gpu, {
        type = .D2,
        width = u32(width),
        height = u32(height),
        layer_count_or_depth = 1,
        num_levels = 1,
        format = .D16_UNORM,
        usage = {.SAMPLER, .DEPTH_STENCIL_TARGET}
    })
    state.depth_texture = depth_texture

    build_pipeline(&state)

    state.object_props.position = {0, 0, -3}

    state.camera = Camera {
        position = {0, 0, 0},
        pitch = 0,
        yaw = 0
    }
    return state
}

run :: proc(state: ^AppState) {
    last_ticks := sdl.GetTicks();
    main_loop: for {
        ev: sdl.Event
        for sdl.PollEvent(&ev) {
            #partial switch ev.type {
                case .QUIT: 
                    break main_loop
                case .KEY_DOWN: #partial switch ev.key.scancode {
                    case .ESCAPE: break main_loop
                    case .E: load_next_obj(state)
                    case .Q: 
                        state.wireframe = !state.wireframe
                        build_pipeline(state)
                }
            }
        }
        new_ticks := sdl.GetTicks();
        delta_time := f32(new_ticks - last_ticks) / 1000
        last_ticks = new_ticks
        update(state, delta_time)
        render(state)
    }
}

update :: proc(state: ^AppState, dt: f32) {
    process_keyboard(&state.camera, dt)
    process_mouse(&state.camera, dt)
}


process_keyboard :: proc(camera: ^Camera, dt: f32) {
    using sdl.Scancode
    speed: f32 = 3
    key_state := sdl.GetKeyboardState(nil)
    f, b, l, r, u, d: f32
    pitch_u, pitch_d, yaw_r, yaw_l: f32
    if key_state[W]     {f = 1}
    if key_state[S]     {b = 1}
    if key_state[A]     {l = 1}
    if key_state[D]     {r = 1}
    if key_state[LSHIFT]{u = 1}
    if key_state[SPACE] {d = 1}
    if key_state[RIGHT] {yaw_r = 1}
    if key_state[LEFT]  {yaw_l = 1}
    if key_state[UP]    {pitch_u = 1}
    if key_state[DOWN]  {pitch_d = 1}
    fb := f-b
    lr := l-r
    ud := u-d
    yaw := yaw_r - yaw_l
    pitch := pitch_d - pitch_u
    yaw_cos := math.cos(math.to_radians(camera.yaw))
    yaw_sin := math.sin(math.to_radians(camera.yaw))
    camera.position +=  {
        ((lr * yaw_cos) + (-fb * yaw_sin)) * dt * speed, 
        ud * dt * speed,
        ((fb*yaw_cos) + (lr * yaw_sin)) * dt * speed
    }
    camera.pitch += pitch * dt * 100
    camera.yaw += yaw * dt * 100
}

process_mouse :: proc(camera: ^Camera, dt: f32) {
    x, y: f32
    _flags := sdl.GetRelativeMouseState(&x, &y)
    camera.yaw   += x * dt * 10
    camera.pitch += y * dt * 10
    if camera.pitch >  90 do camera.pitch =  90
    if camera.pitch < -90 do camera.pitch = -90
}

render :: proc(state: ^AppState) {
    cmd_buff := sdl.AcquireGPUCommandBuffer(state.gpu); assert(cmd_buff != nil)
    
    swapchain_texture: ^sdl.GPUTexture
    ok := sdl.WaitAndAcquireGPUSwapchainTexture(cmd_buff, state.window, &swapchain_texture, nil, nil); assert(ok)
    
    color_target := sdl.GPUColorTargetInfo {
        texture = swapchain_texture,
        load_op = .CLEAR,
        store_op = .STORE,
        clear_color = {0.1, 0.1, 0.1, 1},
    }

    ubo := create_ubo(state)
    depth_target_info := sdl.GPUDepthStencilTargetInfo {
        texture = state.depth_texture,
        clear_depth = 1,
        load_op = .CLEAR,
        store_op = .STORE,
        stencil_load_op = .CLEAR,
        stencil_store_op = .STORE,
        cycle = true,
        clear_stencil = 0,
    }
    render_pass := sdl.BeginGPURenderPass(cmd_buff, &color_target, 1, &depth_target_info); assert(render_pass != nil)
    sdl.BindGPUGraphicsPipeline(render_pass, state.pipeline)

    bindings: []sdl.GPUBufferBinding = {
        sdl.GPUBufferBinding { buffer = state.vbo },
    } 

    sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)
    sdl.BindGPUIndexBuffer(render_pass, { buffer = state.ibo }, ._32BIT)
    sdl.PushGPUVertexUniformData(cmd_buff, 0, &ubo, size_of(UBO))
    sdl.BindGPUFragmentSamplers(render_pass, 0, &(sdl.GPUTextureSamplerBinding{texture = state.texture, sampler = state.tex_sampler}), 1)
    sdl.DrawGPUIndexedPrimitives(render_pass, state.num_indices, 1, 0, 0, 0)
    sdl.EndGPURenderPass(render_pass)

    ok = sdl.SubmitGPUCommandBuffer(cmd_buff); assert(ok)
}

build_pipeline :: proc(state: ^AppState) {
    sdl.ReleaseGPUGraphicsPipeline(state.gpu, state.pipeline)
    vert_shader := load_shader(state.gpu, vert_shader_code, .VERTEX, 1, 0); defer sdl.ReleaseGPUShader(state.gpu, vert_shader)
    frag_shader := load_shader(state.gpu, frag_shader_code, .FRAGMENT, 0, 1); defer sdl.ReleaseGPUShader(state.gpu, frag_shader)

    vb_descriptions: []sdl.GPUVertexBufferDescription = {
        sdl.GPUVertexBufferDescription {
            slot = 0,
            pitch = size_of(Vertex),
            input_rate = .VERTEX,
            instance_step_rate = 0
        },
    };

    vb_attributes: []sdl.GPUVertexAttribute = {
        sdl.GPUVertexAttribute {
            location = 0,
            buffer_slot = 0,
            format = .FLOAT3,
            offset = 0
        },
        sdl.GPUVertexAttribute {
            location = 1,
            buffer_slot = 0,
            format = .FLOAT3,
            offset = size_of(vec3)
        },
        sdl.GPUVertexAttribute {
            location = 2,
            buffer_slot = 0,
            format = .FLOAT2,
            offset = size_of(vec3) * 2
        },
    }

    fill_mode: sdl.GPUFillMode;
    cull_mode: sdl.GPUCullMode; 
    if state.wireframe {fill_mode = .LINE; cull_mode = .NONE} else {fill_mode = .FILL; cull_mode = .BACK}
    pipeline := sdl.CreateGPUGraphicsPipeline(state.gpu, {
        vertex_shader = vert_shader,
        fragment_shader = frag_shader,
        primitive_type = .TRIANGLELIST,
        target_info = {
            num_color_targets = 1,
            color_target_descriptions = &(sdl.GPUColorTargetDescription {
                format = sdl.GetGPUSwapchainTextureFormat(state.gpu, state.window)
            }),
            has_depth_stencil_target = true,
            depth_stencil_format = .D16_UNORM
        },
        vertex_input_state = {
            vertex_buffer_descriptions = &vb_descriptions[0],
            num_vertex_buffers = 1,
            vertex_attributes = &vb_attributes[0],
            num_vertex_attributes = 3
        },
        rasterizer_state = {
            fill_mode = fill_mode,
            cull_mode = cull_mode
        },
        depth_stencil_state = {
            enable_depth_test = true,
            enable_depth_write = true,
            compare_op = .LESS
        }
    })
    state.pipeline = pipeline
}

load_next_obj :: proc(state: ^AppState) {
    sdl.ReleaseGPUSampler(state.gpu, state.tex_sampler)
    assets_handle := os.open("assets") or_else panic("Assets folder not found")
    assets_dir := os.read_dir(assets_handle, 0) or_else panic("Failed to read asset directory"); defer delete(assets_dir)
    next := strings.concatenate({"assets/", assets_dir[state.active].name}); defer delete(next)
    object_data, ok := load_obj(next); defer {
        delete(object_data.indices)
        delete(object_data.vertices)
    }
    for !ok {
        state.active = (state.active + 1) % len(assets_dir)
        next = strings.concatenate({"assets/", assets_dir[state.active].name})
        delete(object_data.indices)
        delete(object_data.vertices)
        object_data, ok = load_obj(next)
    }
    state.active = (state.active + 1) % len(assets_dir)
    sdl.ReleaseGPUBuffer(state.gpu, state.vbo)
    sdl.ReleaseGPUBuffer(state.gpu, state.ibo)

    // Texture
    img_size: [2]i32
    pixels := stbi.load("castle_brick.jpg", &img_size.x, &img_size.y, nil, 4); assert(pixels != nil); defer stbi.image_free(pixels)
    sdl.ReleaseGPUTexture(state.gpu, state.texture)
    pixels_byte_size := img_size.x * img_size.y * 4
    texture := sdl.CreateGPUTexture(state.gpu, {
        type = .D2,
        format = .R8G8B8A8_UNORM,
        usage = {.SAMPLER},
        width = u32(img_size.x),
        height = u32(img_size.y),
        layer_count_or_depth = 1,
        num_levels = 1
    })

    tex_transfer_buffer := sdl.CreateGPUTransferBuffer(state.gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = u32(pixels_byte_size),
    }); assert(tex_transfer_buffer != nil)
    tex_transfer_mem := sdl.MapGPUTransferBuffer(state.gpu, tex_transfer_buffer, false)
    mem.copy(tex_transfer_mem, pixels, int(pixels_byte_size))
    sdl.UnmapGPUTransferBuffer(state.gpu, tex_transfer_buffer)

    // Acquire copy_commands and transferbuffer
    len_bytes := max(
        len(object_data.indices) * size_of(u32),
        len(object_data.vertices) * size_of(Vertex),
    )
    transfer_buffer := sdl.CreateGPUTransferBuffer(state.gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = u32(len_bytes),
    }); assert(transfer_buffer != nil)

    copy_commands := sdl.AcquireGPUCommandBuffer(state.gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)
    vbo :=  create_buffer_with_data(state.gpu, transfer_buffer, copy_pass, {.VERTEX}, object_data.vertices[:])
    ibo := create_buffer_with_data(state.gpu, transfer_buffer, copy_pass, {.INDEX}, object_data.indices[:])
    sdl.UploadToGPUTexture(copy_pass, 
        {transfer_buffer = tex_transfer_buffer},
        {texture = texture, w = u32(img_size.x), h = u32(img_size.y), d = 1},
        false
    )

    // End copy pass
    sdl.ReleaseGPUTransferBuffer(state.gpu, transfer_buffer)
    sdl.ReleaseGPUTransferBuffer(state.gpu, tex_transfer_buffer)

    // Create texture sampler
    sampler := sdl.CreateGPUSampler(state.gpu, {}); assert(sampler != nil)

    sdl.EndGPUCopyPass(copy_pass)
    ok = sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)
    state.num_indices = u32(len(object_data.indices))
    state.vbo = vbo
    state.ibo = ibo
    state.tex_sampler = sampler
    state.texture = texture
}

create_view_matrix :: proc(camera: ^Camera) -> linalg.Matrix4f32 {
    yaw_matrix := linalg.matrix4_rotate_f32(math.to_radians(camera.yaw), {0, 1, 0})
    pitch_matrix := linalg.matrix4_rotate_f32(math.to_radians(camera.pitch), {1, 0, 0})
    position_matrix := linalg.matrix4_translate_f32(camera.position)
    return pitch_matrix * yaw_matrix * position_matrix
}

create_ubo :: proc(state: ^AppState) -> UBO {
    x, y: i32;
    ok := sdl.GetWindowSize(state.window, &x, &y)
    aspect := f32(x) / f32(y)
    projection_matrix := linalg.matrix4_perspective_f32(linalg.to_radians(f32(50)), aspect, 0.0001, 10)
    model_matrix := linalg.matrix4_translate_f32(state.object_props.position) * linalg.matrix4_rotate_f32(state.object_props.rotation, {0,1,0})
    view := create_view_matrix(&state.camera)
    return UBO {
        view = view,
        proj = projection_matrix,
        model = model_matrix,
    }
}

create_buffer_with_data :: proc(
    gpu: ^sdl.GPUDevice, 
    transfer_buffer: ^sdl.GPUTransferBuffer,
    copy_pass: ^sdl.GPUCopyPass,
    usage: sdl.GPUBufferUsageFlags,
    data: []$T
) -> ^sdl.GPUBuffer {
    len_bytes := len(data) * size_of(T)

    buffer := sdl.CreateGPUBuffer(gpu, {
        usage = usage,
        size = u32(len_bytes),
    });

    transfer_mem := transmute([^]byte) sdl.MapGPUTransferBuffer(gpu, transfer_buffer, true)
    mem.copy(transfer_mem, raw_data(data), len_bytes)
    sdl.UnmapGPUTransferBuffer(gpu, transfer_buffer)
    sdl.UploadToGPUBuffer(copy_pass, 
        sdl.GPUTransferBufferLocation {
            offset = 0,
            transfer_buffer = transfer_buffer
        },
        sdl.GPUBufferRegion {
            offset = 0,
            size = u32(len_bytes),
            buffer = buffer
        }, true
    )

    return buffer
}

load_shader :: proc(device: ^sdl.GPUDevice, code: []u8,
    stage: sdl.GPUShaderStage, num_uniform_buffers: u32, num_samplers: u32
) -> ^sdl.GPUShader {
    return sdl.CreateGPUShader(device, {
        code_size = len(code),
        code = raw_data(code),
        entrypoint = "main",
        format = {.SPIRV},
        stage = stage,
        num_uniform_buffers = num_uniform_buffers,
        num_samplers = num_samplers
    })
}