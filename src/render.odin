package obj_viewer

import sdl "vendor:sdl3"
import stbi "vendor:stb/image"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:fmt"

Renderer :: struct {
    window: ^sdl.Window,
    gpu: ^sdl.GPUDevice,
    pipeline: ^sdl.GPUGraphicsPipeline,
    model: Model,
    depth_texture: ^sdl.GPUTexture,
    camera: Camera,
    tex_sampler: ^sdl.GPUSampler,
    texture: ^sdl.GPUTexture,
    fullscreen: bool
}

vec2 :: [2]f32
vec3 :: [3]f32

Vertex :: struct {
    position: vec3,
    normal: vec3,
    uv: vec2,
}

Mesh :: struct {
    vertices: []Vertex,
    vbo: ^sdl.GPUBuffer,
}

UBO :: struct {
    view: matrix[4,4]f32,
    proj: matrix[4,4]f32,
    model: matrix[4,4]f32,
    instance: u32
}

Camera :: struct {
    position: vec3,
    yaw: f32,
    pitch: f32
}

Model :: struct {
    rotation: f32,
    mesh: Mesh,
    mesh_instances: [27]vec3,
    indices: []u32,
    ibo: ^sdl.GPUBuffer,
}

create_renderer :: proc(renderer: ^Renderer) {
    win_flags: sdl.WindowFlags
    if renderer.fullscreen {win_flags = {.MOUSE_GRABBED, .FULLSCREEN}} else do win_flags = {.MOUSE_GRABBED}
    window := sdl.CreateWindow("Hello Odin", 1280, 720, win_flags); assert(window != nil)
    ok := sdl.HideCursor(); assert(ok)
    ok = sdl.SetWindowRelativeMouseMode(window, true); assert(ok)
    width, height: i32
    sdl.GetWindowSize(window, &width, &height)

    gpu := sdl.CreateGPUDevice({.SPIRV}, true, nil); assert(gpu != nil)
    ok = sdl.ClaimWindowForGPUDevice(gpu, window); assert(ok)

    renderer.window = window
    renderer.gpu = gpu

    load_rubiks_cube(renderer)

    depth_texture := sdl.CreateGPUTexture(gpu, {
        type = .D2,
        width = u32(width),
        height = u32(height),
        layer_count_or_depth = 1,
        num_levels = 1,
        format = .D32_FLOAT,
        usage = {.SAMPLER, .DEPTH_STENCIL_TARGET}
    })
    renderer.depth_texture = depth_texture

    build_pipeline(renderer, false)

    i := 0
    for x in 0..<3 {
        for y in 0..<3 {
            for z in 0..<3 {
                renderer.model.mesh_instances[i] = vec3{f32(x), f32(y), f32(z)}

                i += 1
            }
        }
    }

    renderer.camera = Camera {
        position = {0, 0, -5},
        pitch = 0,
        yaw = 0
    }
}

load_rubiks_cube :: proc(renderer: ^Renderer) {
    img_size: [2]i32
    pixels := stbi.load("assets/castle_brick.jpg", &img_size.x, &img_size.y, nil, 4); assert(pixels != nil); defer stbi.image_free(pixels)
    pixels_byte_size := img_size.x * img_size.y * 4
    texture := sdl.CreateGPUTexture(renderer.gpu, {
        type = .D2,
        format = .R8G8B8A8_UNORM,
        usage = {.SAMPLER},
        width = u32(img_size.x),
        height = u32(img_size.y),
        layer_count_or_depth = 1,
        num_levels = 1
    })

    tex_transfer_buffer := sdl.CreateGPUTransferBuffer(renderer.gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = u32(pixels_byte_size),
    }); assert(tex_transfer_buffer != nil)
    tex_transfer_mem := sdl.MapGPUTransferBuffer(renderer.gpu, tex_transfer_buffer, false)
    mem.copy(tex_transfer_mem, pixels, int(pixels_byte_size))
    sdl.UnmapGPUTransferBuffer(renderer.gpu, tex_transfer_buffer)

    cube: Model
    load_cube(&cube)

    // Acquire copy_commands and transferbuffer
    len_bytes := max(
        len(cube.indices) * size_of(u32),
        len(cube.mesh.vertices) * size_of(Vertex),
    )
    transfer_buffer := sdl.CreateGPUTransferBuffer(renderer.gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = u32(len_bytes),
    }); assert(transfer_buffer != nil)

    copy_commands := sdl.AcquireGPUCommandBuffer(renderer.gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)
    cube.mesh.vbo = create_buffer_with_data(renderer.gpu, transfer_buffer, copy_pass, {.VERTEX}, cube.mesh.vertices[:])
    cube.ibo = create_buffer_with_data(renderer.gpu, transfer_buffer, copy_pass, {.INDEX}, cube.indices[:])
    sdl.UploadToGPUTexture(copy_pass, 
        {transfer_buffer = tex_transfer_buffer},
        {texture = texture, w = u32(img_size.x), h = u32(img_size.y), d = 1},
        false
    )

    // End copy pass
    sdl.ReleaseGPUTransferBuffer(renderer.gpu, transfer_buffer)
    sdl.ReleaseGPUTransferBuffer(renderer.gpu, tex_transfer_buffer)
    sdl.EndGPUCopyPass(copy_pass)

    // Create texture sampler
    sampler := sdl.CreateGPUSampler(renderer.gpu, {}); assert(sampler != nil)

    ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)
    renderer.tex_sampler = sampler
    renderer.texture = texture
    renderer.model = cube
}

render :: proc(renderer: ^Renderer, cube: ^Cube) {
    for i in renderer.model.mesh_instances {
        fmt.println(cube[u32(i.x)][u32(i.y)][u32(i.z)])
    }
    cmd_buff := sdl.AcquireGPUCommandBuffer(renderer.gpu); assert(cmd_buff != nil)
    swapchain_texture: ^sdl.GPUTexture
    ok := sdl.WaitAndAcquireGPUSwapchainTexture(cmd_buff, renderer.window, &swapchain_texture, nil, nil); assert(ok)
    
    color_target := sdl.GPUColorTargetInfo {
        texture = swapchain_texture,
        load_op = .CLEAR,
        store_op = .STORE,
        clear_color = {0.1, 0.1, 0.1, 1},
    }
    
    depth_target_info := sdl.GPUDepthStencilTargetInfo {
        texture = renderer.depth_texture,
        clear_depth = 1,
        load_op = .CLEAR,
        store_op = .STORE,
        stencil_load_op = .CLEAR,
        stencil_store_op = .STORE,
        cycle = true,
        clear_stencil = 0,
    }
    render_pass := sdl.BeginGPURenderPass(cmd_buff, &color_target, 1, &depth_target_info); assert(render_pass != nil)
    sdl.BindGPUGraphicsPipeline(render_pass, renderer.pipeline)

    bindings: [1]sdl.GPUBufferBinding
    bindings[0] = sdl.GPUBufferBinding { buffer = renderer.model.mesh.vbo }

    sdl.BindGPUFragmentSamplers(render_pass, 0, 
        &(sdl.GPUTextureSamplerBinding{texture = renderer.texture, sampler = renderer.tex_sampler}), 1
    )
    sdl.BindGPUIndexBuffer(render_pass, { buffer = renderer.model.ibo }, ._32BIT)
    sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)

    for i in 0..<len(renderer.model.mesh_instances) {
        ubo := create_ubo(
            renderer.window,
            &renderer.model,
            u32(i), 
            &renderer.camera)
        sdl.PushGPUVertexUniformData(cmd_buff, 0, &ubo, size_of(UBO))
        sdl.DrawGPUIndexedPrimitives(render_pass, u32(len(renderer.model.indices)), 1, 0, 0, 0)
    }


    sdl.EndGPURenderPass(render_pass)

    ok = sdl.SubmitGPUCommandBuffer(cmd_buff); assert(ok)
}

build_pipeline :: proc(renderer: ^Renderer, wireframe: bool) {
    sdl.ReleaseGPUGraphicsPipeline(renderer.gpu, renderer.pipeline)
    vert_shader := load_shader(renderer.gpu, vert_shader_code, .VERTEX, 1, 0); defer sdl.ReleaseGPUShader(renderer.gpu, vert_shader)
    frag_shader := load_shader(renderer.gpu, frag_shader_code, .FRAGMENT, 0, 1); defer sdl.ReleaseGPUShader(renderer.gpu, frag_shader)

    vb_descriptions: [1]sdl.GPUVertexBufferDescription
    vb_descriptions[0] = sdl.GPUVertexBufferDescription {
        slot = u32(0),
        pitch = size_of(Vertex),
        input_rate = .VERTEX,
        instance_step_rate = 0
    }     

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
        sdl.GPUVertexAttribute {
            location = 3,
            buffer_slot = 0,
            format = .UINT,
            offset = size_of(vec3) * 2 + size_of(vec2)
        },
    }

    fill_mode: sdl.GPUFillMode;
    cull_mode: sdl.GPUCullMode; 
    if wireframe {fill_mode = .LINE; cull_mode = .NONE} else {fill_mode = .FILL; cull_mode = .BACK}
    renderer.pipeline = sdl.CreateGPUGraphicsPipeline(renderer.gpu, {
        vertex_shader = vert_shader,
        fragment_shader = frag_shader,
        primitive_type = .TRIANGLELIST,
        target_info = {
            num_color_targets = 1,
            color_target_descriptions = &(sdl.GPUColorTargetDescription {
                format = sdl.GetGPUSwapchainTextureFormat(renderer.gpu, renderer.window)
            }),
            has_depth_stencil_target = true,
            depth_stencil_format = .D32_FLOAT
        },
        vertex_input_state = {
            vertex_buffer_descriptions = &vb_descriptions[0],
            num_vertex_buffers = 1,
            vertex_attributes = &vb_attributes[0],
            num_vertex_attributes = 4
        },
        rasterizer_state = {
            fill_mode = fill_mode,
            cull_mode = cull_mode,
        },
        depth_stencil_state = {
            enable_depth_test = true,
            enable_depth_write = true,
            compare_op = .LESS,
        }
    })
}

create_view_matrix :: proc(camera: ^Camera) -> linalg.Matrix4f32 {
    yaw_matrix := linalg.matrix4_rotate_f32(math.to_radians(camera.yaw), {0, 1, 0})
    pitch_matrix := linalg.matrix4_rotate_f32(math.to_radians(camera.pitch), {1, 0, 0})
    position_matrix := linalg.matrix4_translate_f32(camera.position)
    return pitch_matrix * yaw_matrix * position_matrix
}

create_ubo :: proc(window: ^sdl.Window, model: ^Model, instance: u32, camera: ^Camera) -> UBO {
    x, y: i32;
    ok := sdl.GetWindowSize(window, &x, &y)
    aspect := f32(x) / f32(y)
    projection_matrix := linalg.matrix4_perspective_f32(linalg.to_radians(f32(70)), aspect, 0.0001, 1000)
    model_matrix := linalg.matrix4_translate_f32(model.mesh_instances[instance] * 2.1)
    view := create_view_matrix(camera)
    return UBO {
        view = view,
        proj = projection_matrix,
        model = model_matrix,
        instance = instance
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