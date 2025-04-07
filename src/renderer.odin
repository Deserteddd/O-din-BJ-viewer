package obj_viewer

import "core:mem"
import "core:math/linalg"
import "core:fmt"
import "core:c"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"

vert_shader_code := #load("../shaders/spv/shader.vert.spv")
frag_shader_code := #load("../shaders/spv/shader.frag.spv")
vert_code_2D := #load("../shaders/spv/shader2D.vert.spv")
frag_code_2D := #load("../shaders/spv/shader2D.frag.spv")
bbox_vert_shader := #load("../shaders/spv/bbox.vert.spv")
bbox_frag_shader := #load("../shaders/spv/bbox.frag.spv")

Renderer :: struct {
    window: ^sdl.Window,
    gpu: ^sdl.GPUDevice,
    pipeline3D: ^sdl.GPUGraphicsPipeline,
    bbox_pipeline: ^sdl.GPUGraphicsPipeline,
    depth_texture: ^sdl.GPUTexture,
    fallback_texture: ^sdl.GPUTexture,
    cmd_buff: ^sdl.GPUCommandBuffer,
    swapchain_texture: ^sdl.GPUTexture,
    wireframe: bool,
    samplers: [4]^sdl.GPUSampler,
    gui: GUI,
}

VertUniforms :: struct {
    modelview: matrix[4,4]f32,
    proj: matrix[4,4]f32,
    position_offset: vec4,
}

FragUniforms :: struct {
    player_pos: vec4,
}

RND_InitFlags :: distinct bit_set[RND_InitFlag; uint]

RND_InitFlag :: enum uint {
    FULLSCREEN = 0,
    WIREFRAME  = 1,
    DRAW_UI    = 2,
}

RND_Init :: proc(flags: RND_InitFlags) -> Renderer {
    renderer: Renderer
    ok := sdl.Init({.VIDEO}); assert(ok)
    window_flags: sdl.WindowFlags
    w, h: c.int = 1280, 720
    if .FULLSCREEN in flags {
        window_flags += {.FULLSCREEN}
        w = 1920
        h = 1080
    } 
    window  := sdl.CreateWindow("Hello Odin", w, h, window_flags); assert(ok)
    ok = sdl.HideCursor(); assert(ok)
    ok = sdl.SetWindowRelativeMouseMode(window, true); assert(ok)
    width, height: i32
    sdl.GetWindowSize(window, &width, &height)
    gpu := sdl.CreateGPUDevice({.SPIRV}, true, nil); assert(gpu != nil)
    ok = sdl.ClaimWindowForGPUDevice(gpu, window); assert(ok)

    renderer.window = window
    renderer.gpu = gpu

    img_size: [2]i32
    pixels := stbi.load("assets/err_tex.jpg", &img_size.x, &img_size.y, nil, 4); assert(pixels != nil)
    defer stbi.image_free(pixels)
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
    build_bbox_pipeline(&renderer)
    build_3D_pipeline(&renderer)
    for i in 0..<4 {
        sampler := sdl.CreateGPUSampler(gpu, {}); assert(sampler != nil)
        renderer.samplers[i] = sampler
    }
    assert(renderer.bbox_pipeline != nil)
    return renderer
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

RND_DrawBounds :: proc(state: ^AppState) {
    using state
    assert(renderer.cmd_buff != nil)
    assert(renderer.swapchain_texture != nil)

    bbox_color_target := sdl.GPUColorTargetInfo {
        texture = renderer.swapchain_texture,
        load_op = .LOAD,
        store_op = .STORE,
    }
    bbox_pass := sdl.BeginGPURenderPass(renderer.cmd_buff, &bbox_color_target, 1, nil)
    assert(bbox_pass != nil)
    sdl.BindGPUGraphicsPipeline(bbox_pass, renderer.bbox_pipeline)
    for &entity, entity_index in entities {
        if entity.bbox_vbo == nil || !state.player_collisions[entity_index] do continue
        using entity
        bindings: [1]sdl.GPUBufferBinding = { sdl.GPUBufferBinding { buffer = bbox_vbo } } 
        sdl.BindGPUVertexBuffers(bbox_pass, 0, &bindings[0], 1)
        vert_ubo := create_vertex_UBO(renderer, entity_physics[:], entity_index)
        sdl.PushGPUVertexUniformData(renderer.cmd_buff, 0, &vert_ubo, size_of(VertUniforms))
        sdl.DrawGPUPrimitives(bbox_pass, 24, 1, 0, 0)

    }
    sdl.EndGPURenderPass(bbox_pass)
}

RND_DrawEntities :: proc(state: ^AppState) {
    using state
    player := entity_physics[0]
    assert(renderer.cmd_buff != nil)
    assert(renderer.swapchain_texture != nil)
    color_target := sdl.GPUColorTargetInfo {
        texture = renderer.swapchain_texture,
        load_op = .CLEAR,
        store_op = .STORE,
        clear_color = {0.2, 0.2, 0.2, 1},
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

    render_pass := sdl.BeginGPURenderPass(renderer.cmd_buff, &color_target, 1, &depth_target_info); assert(render_pass != nil)
    sdl.BindGPUGraphicsPipeline(render_pass, renderer.pipeline3D)
    assert(entities[0].model.vbo == nil)
    light_pos := player.position
    light_pos.y += 2
    frag_ubo := FragUniforms {player_pos = to_vec4(light_pos, 5)}

    sdl.PushGPUFragmentUniformData(renderer.cmd_buff, 0, &frag_ubo, size_of(FragUniforms))
    for &entity, entity_index in entities {
        if entity.model.vbo == nil do continue
        assert(entity_index>0)
        using entity
        bindings: [1]sdl.GPUBufferBinding = { sdl.GPUBufferBinding { buffer = model.vbo } } 
        sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)
        texture_count := len(model.textures)
        for tex, i in model.textures {
            sdl.BindGPUFragmentSamplers(render_pass, u32(i), 
                &(sdl.GPUTextureSamplerBinding{texture = tex, sampler = renderer.samplers[i]}), u32(texture_count)
            )
        }
        for i in texture_count..<4 {
            if texture_count == 0 do texture_count = 1
            sdl.BindGPUFragmentSamplers(render_pass, u32(i), 
                &(sdl.GPUTextureSamplerBinding{texture = renderer.fallback_texture, sampler = renderer.samplers[i]}), u32(texture_count)
            )
        }
        sdl.BindGPUFragmentStorageBuffers(render_pass, 0, &model.material_buffer, 1)
        vert_ubo := create_vertex_UBO(
            renderer, 
            entity_physics[:],
            entity_index
        )
        sdl.PushGPUVertexUniformData(renderer.cmd_buff, 0, &vert_ubo, size_of(VertUniforms))
        start: u32 = 0
        for end, i in model.mesh_boundary_indices {
            sdl.DrawGPUPrimitives(render_pass, end-start, 1, start, 0)
            start = end

        }
    }
    sdl.EndGPURenderPass(render_pass)
}

RND_ToggleWireframe :: proc(renderer: ^Renderer) {
    renderer.wireframe = !renderer.wireframe
    build_3D_pipeline(renderer)
}

@(private="file")
build_3D_pipeline :: proc(renderer: ^Renderer) {
    sdl.ReleaseGPUGraphicsPipeline(renderer.gpu, renderer.pipeline3D)
    vert_shader := load_shader(renderer.gpu, vert_shader_code, .VERTEX, 1, 0, 0); defer sdl.ReleaseGPUShader(renderer.gpu, vert_shader)
    frag_shader := load_shader(renderer.gpu, frag_shader_code, .FRAGMENT, 1, 4, 1); defer sdl.ReleaseGPUShader(renderer.gpu, frag_shader)

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

    format := sdl.GetGPUSwapchainTextureFormat(renderer.gpu, renderer.window)
    renderer.pipeline3D = sdl.CreateGPUGraphicsPipeline(renderer.gpu, {
        vertex_shader = vert_shader,
        fragment_shader = frag_shader,
        primitive_type = .TRIANGLELIST,
        target_info = {
            num_color_targets = 1,
            color_target_descriptions = &(sdl.GPUColorTargetDescription {
                format = format
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

create_view_matrix :: proc(player: Physics) -> linalg.Matrix4f32 {
    using linalg, player
    pitch_matrix := matrix4_rotate_f32(to_radians(rotation.x), {1, 0, 0})
    yaw_matrix := matrix4_rotate_f32(to_radians(rotation.y), {0, 1, 0})
    camera_position := -position
    camera_position.y -= 2
    position_matrix := matrix4_translate_f32(camera_position)

    return pitch_matrix * yaw_matrix * position_matrix
}

create_vertex_UBO :: proc(renderer: Renderer, entity_physics: []Physics, index: int) -> VertUniforms {
    using linalg
    x, y: i32;
    ok := sdl.GetWindowSize(renderer.window, &x, &y)
    aspect := f32(x) / f32(y)
    projection_matrix := matrix4_perspective_f32(linalg.to_radians(f32(90)), aspect, 0.00001, 1000)
    view_matrix := create_view_matrix(entity_physics[0])
    model_rotation_matrix := matrix4_rotate_f32(to_radians(entity_physics[index].rotation.y), {0, 1, 0})
    model_translation_matrix := matrix4_translate_f32(entity_physics[index].position)
    model_matrix: matrix[4, 4]f32 = view_matrix  * model_translation_matrix
    if index != 0 do model_matrix *= model_rotation_matrix
    return VertUniforms {
        modelview = model_matrix,
        proj = projection_matrix,
        position_offset = to_vec4(entity_physics[index].position, 1)
    }
}

create_bbox_UBO :: proc(renderer: Renderer, entity_physics: []Physics, index: int) -> VertUniforms {
    using linalg
    x, y: i32;
    ok := sdl.GetWindowSize(renderer.window, &x, &y)
    aspect := f32(x) / f32(y)
    projection_matrix := matrix4_perspective_f32(linalg.to_radians(f32(90)), aspect, 0.00001, 1000)
    view_matrix := create_view_matrix(entity_physics[0])
    model_rotation_matrix := matrix4_rotate_f32(to_radians(entity_physics[index].rotation.y), {0, 1, 0})
    model_translation_matrix := matrix4_translate_f32(entity_physics[index].position)
    model_matrix: matrix[4, 4]f32 = view_matrix  * model_translation_matrix * model_rotation_matrix
    if index != 0 do model_matrix *= model_rotation_matrix
    return VertUniforms {
        modelview = model_matrix,
        proj = projection_matrix,
        position_offset = to_vec4(entity_physics[index].position, 1)
    }
}

@(private="file")
build_bbox_pipeline :: proc(renderer: ^Renderer) {
    sdl.ReleaseGPUGraphicsPipeline(renderer.gpu, renderer.pipeline3D)
    vert_shader := load_shader(renderer.gpu, bbox_vert_shader, .VERTEX, 1, 0, 0); defer sdl.ReleaseGPUShader(renderer.gpu, vert_shader)
    frag_shader := load_shader(renderer.gpu, bbox_frag_shader, .FRAGMENT, 0, 0, 0); defer sdl.ReleaseGPUShader(renderer.gpu, frag_shader)

    vb_descriptions: [1]sdl.GPUVertexBufferDescription
    vb_descriptions = {
        sdl.GPUVertexBufferDescription {
            slot = u32(0),
            pitch = size_of(vec3),
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
        }
    }

    format := sdl.GetGPUSwapchainTextureFormat(renderer.gpu, renderer.window)
    renderer.bbox_pipeline = sdl.CreateGPUGraphicsPipeline(renderer.gpu, {
        vertex_shader = vert_shader,
        fragment_shader = frag_shader,
        primitive_type = .LINELIST,
        target_info = {
            num_color_targets = 1,
            color_target_descriptions = &(sdl.GPUColorTargetDescription {
                format = format
            }),
        },
        vertex_input_state = {
            vertex_buffer_descriptions = &vb_descriptions[0],
            num_vertex_buffers = 1,
            vertex_attributes = &vb_attributes[0],
            num_vertex_attributes = 1
        },
        rasterizer_state = {
            fill_mode = .LINE,
            cull_mode = .NONE,
        },
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