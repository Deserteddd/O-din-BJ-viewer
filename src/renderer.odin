package obj_viewer

import sdl "vendor:sdl3"
import stbi "vendor:stb/image"
import "core:mem"
import "core:math/linalg"
import "core:fmt"

vert_shader_code := #load("../shaders/spv/shader.vert.spv")
frag_shader_code := #load("../shaders/spv/shader.frag.spv")
vert_code_2D := #load("../shaders/spv/shader2D.vert.spv")
frag_code_2D := #load("../shaders/spv/shader2D.frag.spv")

Renderer :: struct {
    window: ^sdl.Window,
    gpu: ^sdl.GPUDevice,
    pipeline3D: ^sdl.GPUGraphicsPipeline,
    pipeline2D: ^sdl.GPUGraphicsPipeline,
    depth_texture: ^sdl.GPUTexture,
    fallback_texture: ^sdl.GPUTexture,
    camera: Camera,
    cmd_buff: ^sdl.GPUCommandBuffer,
    swapchain_texture: ^sdl.GPUTexture,
    wireframe: bool,
    samplers: [4]^sdl.GPUSampler,
}

UBO3 :: struct {
    modelview: matrix[4,4]f32,
    proj: matrix[4,4]f32,
}

Camera :: struct {
    position: vec3,
    yaw: f32,
    pitch: f32
}

Object :: struct {
    position: vec3,
    rotation: vec3,
    textures: []^sdl.GPUTexture,
    vbo: ^sdl.GPUBuffer,
    material_buffer: ^sdl.GPUBuffer,
    mesh_bounds: []u32,

}

RND_InitFlags :: distinct bit_set[RND_Flag; uint]

RND_Flag :: enum uint {
    FULLSCREEN = 0,
    WIREFRAME  = 1,
}

RND_Init :: proc(flags: RND_InitFlags) -> Renderer {
    renderer: Renderer
    ok := sdl.Init({.VIDEO}); assert(ok)
    window_flags: sdl.WindowFlags
    if .FULLSCREEN in flags do window_flags += {.FULLSCREEN}
    window  := sdl.CreateWindow("Hello Odin", 1280, 720, window_flags); assert(ok)
    ok = sdl.HideCursor(); assert(ok)
    ok = sdl.SetWindowRelativeMouseMode(window, true); assert(ok)
    width, height: i32
    sdl.GetWindowSize(window, &width, &height)
    gpu := sdl.CreateGPUDevice({.SPIRV}, true, nil); assert(gpu != nil)
    ok = sdl.ClaimWindowForGPUDevice(gpu, window); assert(ok)

    renderer.window = window
    renderer.gpu = gpu

    img_size: [2]i32
    pixels := stbi.load("assets/err_tex.jpg", &img_size.x, &img_size.y, nil, 4); assert(pixels != nil); defer stbi.image_free(pixels)
    pixels_byte_size := img_size.x * img_size.y * 4
    fallback_texture := sdl.CreateGPUTexture(gpu, {
        type = .D2,
        format = .R8G8B8A8_UNORM,
        usage = {.SAMPLER},
        width = u32(img_size.x),
        height = u32(img_size.y),
        layer_count_or_depth = 1,
        num_levels = 1
    })
    tex_transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = u32(pixels_byte_size),
    }); assert(tex_transfer_buffer != nil)
    tex_transfer_mem := sdl.MapGPUTransferBuffer(gpu, tex_transfer_buffer, false)
    mem.copy(tex_transfer_mem, pixels, int(pixels_byte_size))
    sdl.UnmapGPUTransferBuffer(gpu, tex_transfer_buffer)
    copy_commands := sdl.AcquireGPUCommandBuffer(gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)
    sdl.UploadToGPUTexture(copy_pass, 
        {transfer_buffer = tex_transfer_buffer},
        {texture = fallback_texture, w = u32(img_size.x), h = u32(img_size.y), d = 1},
        false
    )
    sdl.ReleaseGPUTransferBuffer(gpu, tex_transfer_buffer)
    sdl.EndGPUCopyPass(copy_pass)
    ok = sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)
    renderer.fallback_texture = fallback_texture

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
    if .WIREFRAME in flags do renderer.wireframe = true
    build_3D_pipeline(&renderer)
    for i in 0..<4 {
        sampler := sdl.CreateGPUSampler(gpu, {}); assert(sampler != nil)
        renderer.samplers[i] = sampler
    }

    renderer.camera = Camera {
        position = {5, -3, -6},
        yaw = 45,
        pitch = 25

    }
    return renderer
}

RND_ToggleWireframe :: proc(renderer: ^Renderer) {
    renderer.wireframe = !renderer.wireframe
    build_3D_pipeline(renderer)
}

RND_FrameBegin :: proc(renderer: ^Renderer) {
    assert(renderer.cmd_buff == nil)
    assert(renderer.swapchain_texture == nil)
    cmd_buff := sdl.AcquireGPUCommandBuffer(renderer.gpu); assert(cmd_buff != nil)
    swapchain_texture: ^sdl.GPUTexture
    ok := sdl.WaitAndAcquireGPUSwapchainTexture(cmd_buff, renderer.window, &swapchain_texture, nil, nil); assert(ok)
    renderer.cmd_buff = cmd_buff
    renderer.swapchain_texture = swapchain_texture
}

RND_FrameSubmit :: proc(renderer: ^Renderer) -> bool {
    ok := sdl.SubmitGPUCommandBuffer(renderer.cmd_buff)
    renderer.cmd_buff = nil
    renderer.swapchain_texture = nil
    return ok
}

RND_DrawObjects :: proc(renderer: ^Renderer, objects: []Object) {
    assert(renderer.cmd_buff != nil)
    assert(renderer.swapchain_texture != nil)
    color_target := sdl.GPUColorTargetInfo {
        texture = renderer.swapchain_texture,
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
    render_pass := sdl.BeginGPURenderPass(renderer.cmd_buff, &color_target, 1, &depth_target_info)
    assert(render_pass != nil)
    sdl.BindGPUGraphicsPipeline(render_pass, renderer.pipeline3D)
    for &object in objects {
        bindings: [1]sdl.GPUBufferBinding = {
            sdl.GPUBufferBinding { buffer = object.vbo },
        } 
        sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)
        texture_count := len(object.textures)
        for tex, i in object.textures {
            sdl.BindGPUFragmentSamplers(render_pass, u32(i), 
                &(sdl.GPUTextureSamplerBinding{texture = tex, sampler = renderer.samplers[i]}), u32(texture_count)
            )
        }
        // Bind remaining to 0
        for i in texture_count..<4 {
            if texture_count == 0 do texture_count = 1
            sdl.BindGPUFragmentSamplers(render_pass, u32(i), 
                &(sdl.GPUTextureSamplerBinding{texture = renderer.fallback_texture, sampler = renderer.samplers[i]}), u32(texture_count)
            )
        }

        sdl.BindGPUFragmentStorageBuffers(render_pass, 0, &object.material_buffer, 1)
        ubo := create_ubo3(
            renderer.window,
            &object,
            &renderer.camera,
        )
        sdl.PushGPUVertexUniformData(renderer.cmd_buff, 0, &ubo, size_of(UBO3))
        start: u32 = 0
        for end in object.mesh_bounds {
            sdl.DrawGPUPrimitives(render_pass, end-start, 1, start, 0)
            start = end
        }
        // sdl.DrawGPUPrimitives(render_pass, 100, 1, 0, 0)
    }

    sdl.EndGPURenderPass(render_pass)
}

RND_CreateObject :: proc(data: ObjectData, gpu: ^sdl.GPUDevice) -> Object {
    object: Object
    // Create and upload texture
    // pixels_byte_size_total: u32
    tex_transfer_buffers: [4]^sdl.GPUTransferBuffer
    img_sizes: [4][2]i32
    i: int
    textures: [dynamic]^sdl.GPUTexture // try deleting
    for i<len(data.texture_data.textures) {
        defer i += 1
        img_sizes[i] = data.texture_data.sizes[i]
        size := img_sizes[i]
        assert(size.x >= 1)
        assert(size.y >= 1)
        pixels := data.texture_data.textures[i]
        
        pixels_byte_size := u32(size.x * size.y * 4)
        // pixels_byte_size_total += pixels_byte_size
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
    object.textures = textures[:]
    fmt.println("Model uses", i, "textures")
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
            {texture = object.textures[j], w = u32(img_sizes[j].x), h = u32(img_sizes[j].y), d = 1},
            false
        )
    }

    // End copy pass
    sdl.ReleaseGPUTransferBuffer(gpu, transfer_buffer)
    for j in 0..<i do sdl.ReleaseGPUTransferBuffer(gpu, tex_transfer_buffers[j])
    sdl.EndGPUCopyPass(copy_pass)
    ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)

    // Assignments
    object.vbo = vbo
    object.material_buffer = material_buffer
    object.mesh_bounds = mesh_bounds
    return object
}
@(private="file")
build_3D_pipeline :: proc(renderer: ^Renderer) {
    sdl.ReleaseGPUGraphicsPipeline(renderer.gpu, renderer.pipeline3D)
    vert_shader := load_shader(renderer.gpu, vert_shader_code, .VERTEX, 1, 0, 0); defer sdl.ReleaseGPUShader(renderer.gpu, vert_shader)
    frag_shader := load_shader(renderer.gpu, frag_shader_code, .FRAGMENT, 0, 4, 1); defer sdl.ReleaseGPUShader(renderer.gpu, frag_shader)

    vb_descriptions: [1]sdl.GPUVertexBufferDescription
    vb_descriptions = {
        sdl.GPUVertexBufferDescription {
            slot = u32(0),
            pitch = size_of(Vertex),
            input_rate = .VERTEX,
            instance_step_rate = 0
        },
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
            offset = size_of(vec3),
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
        }
    }
    fill_mode: sdl.GPUFillMode;
    cull_mode: sdl.GPUCullMode; 
    if renderer.wireframe {fill_mode = .LINE; cull_mode = .NONE} else {fill_mode = .FILL; cull_mode = .BACK}
    renderer.pipeline3D = sdl.CreateGPUGraphicsPipeline(renderer.gpu, {
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
    using linalg
    yaw_matrix := matrix4_rotate_f32(to_radians(camera.yaw), {0, 1, 0})
    pitch_matrix := matrix4_rotate_f32(to_radians(camera.pitch), {1, 0, 0})
    position_matrix := matrix4_translate_f32(camera.position)
    return pitch_matrix * yaw_matrix * position_matrix
}

create_ubo3 :: proc(window: ^sdl.Window, object: ^Object, camera: ^Camera) -> UBO3 {
    using linalg
    x, y: i32;
    ok := sdl.GetWindowSize(window, &x, &y)
    aspect := f32(x) / f32(y)
    projection_matrix := matrix4_perspective_f32(linalg.to_radians(f32(70)), aspect, 0.0001, 1000)
    model_matrix := create_view_matrix(camera) * matrix4_translate_f32(object.position) * matrix4_rotate_f32(object.rotation.y, {0, 1, 0})
    return UBO3 {
        modelview = model_matrix,
        proj = projection_matrix,
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
    stage: sdl.GPUShaderStage, num_uniform_buffers: u32, num_samplers: u32,
    num_storage_buffers: u32
) -> ^sdl.GPUShader {
    return sdl.CreateGPUShader(device, {
        code_size = len(code),
        code = raw_data(code),
        entrypoint = "main",
        format = {.SPIRV},
        stage = stage,
        num_uniform_buffers = num_uniform_buffers,
        num_samplers = num_samplers,
        num_storage_buffers = num_storage_buffers
    })
}