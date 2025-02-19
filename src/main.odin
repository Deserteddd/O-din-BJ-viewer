package obj_viewer

import "base:runtime"
import "core:log"
import "core:math/linalg"
import "core:fmt"
import "core:mem"
import sdl "vendor:sdl3"

default_context: runtime.Context

vert_shader_code := #load("../shaders/spv/triangle.vert.spv");
frag_shader_code := #load("../shaders/spv/triangle.frag.spv");

AppState :: struct {
    gpu: ^sdl.GPUDevice,
    window: ^sdl.Window,
    pipeline: ^sdl.GPUGraphicsPipeline,
    vbo: ^sdl.GPUBuffer,
    ibo: ^sdl.GPUBuffer,
    win_size: [2]i32,
    object: Object,
}

UBO :: struct {
    mvp: matrix[4,4]f32
}


main :: proc() {
    state := init()
    run(&state)
    sdl.ReleaseGPUBuffer(state.gpu, state.vbo)
    sdl.ReleaseGPUBuffer(state.gpu, state.ibo)
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
    ROTATION_SPEED := linalg.to_radians(f32(90.0))
    state.object.rotation += ROTATION_SPEED * dt
}

render :: proc(state: ^AppState) {
    cmd_buff := sdl.AcquireGPUCommandBuffer(state.gpu); assert(cmd_buff != nil)
    
    swapchain_texture: ^sdl.GPUTexture
    ok := sdl.WaitAndAcquireGPUSwapchainTexture(cmd_buff, state.window, &swapchain_texture, nil, nil); assert(ok)
    
    color_target := sdl.GPUColorTargetInfo {
        texture = swapchain_texture,
        load_op = .CLEAR,
        store_op = .STORE,
        clear_color = {0.2, 0.2, 0.2, 1},
    }

    ubo := create_ubo(state)

    render_pass := sdl.BeginGPURenderPass(cmd_buff, &color_target, 1, nil); assert(render_pass != nil)
    sdl.BindGPUGraphicsPipeline(render_pass, state.pipeline)

    sdl.BindGPUVertexBuffers(render_pass, 0, &(sdl.GPUBufferBinding { buffer = state.vbo }), 1)
    sdl.BindGPUIndexBuffer(render_pass, { buffer = state.ibo }, ._16BIT)
    sdl.PushGPUVertexUniformData(cmd_buff, 0, &ubo, size_of(UBO))
    ibo_len := u32(len(state.object.mesh.indices))
    sdl.DrawGPUIndexedPrimitives(render_pass, ibo_len, 1, 0, 0, 0)
    sdl.EndGPURenderPass(render_pass)

    ok = sdl.SubmitGPUCommandBuffer(cmd_buff); assert(ok)
}

init :: proc() -> AppState {
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
    window := sdl.CreateWindow("Hello Odin", 1440, 960, {}); assert(window != nil)
    gpu := sdl.CreateGPUDevice({.SPIRV}, true, nil); assert(gpu != nil)
    ok = sdl.ClaimWindowForGPUDevice(gpu, window); assert(ok)

    vert_shader := load_shader(gpu, vert_shader_code, .VERTEX, 1)
    frag_shader := load_shader(gpu, frag_shader_code, .FRAGMENT, 0)
    
    // Pipeline creation
    vb_descriptions: []sdl.GPUVertexBufferDescription = {sdl.GPUVertexBufferDescription {
        slot = 0,
        pitch = size_of(Vertex),
        input_rate = .VERTEX,
        instance_step_rate = 0
    }}

    vb_attributes: []sdl.GPUVertexAttribute = {sdl.GPUVertexAttribute {
        location = 0,
        buffer_slot = 0,
        format = .FLOAT3,
        offset = 0
    }}

    pipeline := sdl.CreateGPUGraphicsPipeline(gpu, {
        vertex_shader = vert_shader,
        fragment_shader = frag_shader,
        primitive_type = .TRIANGLELIST,
        target_info = {
            num_color_targets = 1,
            color_target_descriptions = &(sdl.GPUColorTargetDescription {
                format = sdl.GetGPUSwapchainTextureFormat(gpu, window)
            })
        },
        vertex_input_state = {
            vertex_buffer_descriptions = &vb_descriptions[0],
            num_vertex_buffers = 1,
            vertex_attributes = &vb_attributes[0],
            num_vertex_attributes = 1
        },
        rasterizer_state = {
            fill_mode = .LINE,
            cull_mode = .NONE
        }
    })

    // Load object from obj-file
    object := load_obj("assets/monke.obj")
    
    // Acquire copy_commands and transferbuffer
    transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = u32(len(object.mesh.indices) * size_of(u16) + len(object.mesh.verts) * size_of(Vertex)),
    }); assert(transfer_buffer != nil)

    copy_commands := sdl.AcquireGPUCommandBuffer(gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)
    vbo := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.VERTEX}, object.mesh.verts[:])
    ibo := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.INDEX}, object.mesh.indices[:])

    // End copy pass
    sdl.EndGPUCopyPass(copy_pass)
    ok = sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)

    sdl.ReleaseGPUShader(gpu, vert_shader)
    sdl.ReleaseGPUShader(gpu, frag_shader)

    win_size: [2]i32
    ok = sdl.GetWindowSize(window, &win_size.x, &win_size.y); assert(ok)

    return AppState {
        gpu = gpu,
        window = window,
        pipeline = pipeline,
        win_size = win_size,
        vbo = vbo,
        ibo = ibo,
        object = object
    }
}

load_shader :: proc(device: ^sdl.GPUDevice, code: []u8,
    stage: sdl.GPUShaderStage, num_uniform_buffers: u32
) -> ^sdl.GPUShader {
    return sdl.CreateGPUShader(device, {
        code_size = len(code),
        code = raw_data(code),
        entrypoint = "main",
        format = {.SPIRV},
        stage = stage,
        num_uniform_buffers = num_uniform_buffers,
    })
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

Vertex :: struct {
    x: f32,
    y: f32,
    z: f32
}

Mesh :: struct {
    verts: [dynamic]Vertex,
    indices: [dynamic]u16
}

Object :: struct {
    mesh: Mesh,    
    position: [3]f32,
    rotation: f32,
}

create_triangle :: proc(object: ^Object)  {
    verticies: [dynamic]Vertex
    v: []Vertex = {
        Vertex {-1, -1, 0},
        Vertex { 1, -1, 0},
        Vertex { 0,  1, 0},
        Vertex { 1,  1, 0}
    }
    append(&verticies, ..v[:])

    indices: [dynamic]u16
    i: []u16 = {0, 1, 2, 2, 1, 3}
    append(&indices, ..i[:])

    object.mesh = Mesh {
        verts = verticies,
        indices = indices
    }
    object.position = {0, 0, -5}
    object.rotation = 0
}

create_ubo :: proc(state: ^AppState) -> UBO {
    aspect := f32(state.win_size.x) / f32(state.win_size.y)
    projection_matrix := linalg.matrix4_perspective_f32(linalg.to_radians(f32(70)), aspect, 0.0001, 1000)
    model_matrix := linalg.matrix4_translate_f32(state.object.position) * linalg.matrix4_rotate_f32(state.object.rotation, {0,1,0})
    return UBO {
        mvp = projection_matrix * model_matrix
    }
}