package obj_viewer

import "core:mem"
import "core:math/linalg"
import "core:log"
import "core:strings"
import "core:c"
import "core:os"
import "core:path/filepath"
import "core:encoding/json"
import sdl "vendor:sdl3"

Renderer :: struct {

    obj_pipeline:       ^sdl.GPUGraphicsPipeline,
    bbox_pipeline:      ^sdl.GPUGraphicsPipeline,
    skybox_pipeline:    ^sdl.GPUGraphicsPipeline,
    heightmap_pipeline: ^sdl.GPUGraphicsPipeline,
    depth_texture:      ^sdl.GPUTexture,
    fallback_texture:   ^sdl.GPUTexture,
    skybox_texture:     ^sdl.GPUTexture,
    default_sampler:    ^sdl.GPUSampler,
    fullscreen:         bool,
    light:              PointLight,
    r2d:                R2D,
}



PointLight :: struct {
    position: vec3,
    power:    f32,
    color:    vec3,
    _:        f32
}

FragUBOGlobal :: struct {
    light_pos: vec3,
    _: f32,
    light_color: vec3,
    light_intensity: f32,
    view_pos: vec3,
    _: f32
}

VertUBOGlobal :: struct {
	vp,
	inv_view_mat,
	inv_projection_mat: mat4,
}

VertUBOLocal :: struct {
    model_mat,
    normal_mat: mat4
}

Frame :: struct {
    cmd_buff:           ^sdl.GPUCommandBuffer,
    swapchain:          ^sdl.GPUTexture,
    render_pass:        ^sdl.GPURenderPass,
    win_size:           vec2,
    vert_ubo_global:    VertUBOGlobal,
    frag_ubo_global:    FragUBOGlobal,
    frustum_planes:     [6]vec4,
}

RND_Init :: proc() -> Renderer {
    renderer: Renderer
    pixels, size := load_pixels("assets/err_tex.jpg")
    size_u32: [2]u32 = {u32(size.x), u32(size.y)}
    defer free_pixels(pixels)

    copy_commands := sdl.AcquireGPUCommandBuffer(g.gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)
    renderer.skybox_texture = load_cubemap_texture(copy_pass, {
        .POSITIVEX = "assets/skybox/right.png",
        .NEGATIVEX = "assets/skybox/left.png",
        .POSITIVEY = "assets/skybox/top.png",
        .NEGATIVEY = "assets/skybox/bottom.png",
        .POSITIVEZ = "assets/skybox/front.png",
        .NEGATIVEZ = "assets/skybox/back.png",
    })
    renderer.fallback_texture = upload_texture(copy_pass, pixels, size_u32)

    sdl.EndGPUCopyPass(copy_pass)
    ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)

    width, height: i32
    ok = sdl.GetWindowSize(g.window, &width, &height); assert(ok)
    depth_texture := sdl.CreateGPUTexture(g.gpu, {
        type = .D2,
        width = u32(width),
        height = u32(height),
        layer_count_or_depth = 1,
        num_levels = 1,
        format = .D32_FLOAT,
        usage = {.SAMPLER, .DEPTH_STENCIL_TARGET}
    })
    renderer.depth_texture = depth_texture

    swapchain_format := sdl.GetGPUSwapchainTextureFormat(g.gpu, g.window)
    renderer.obj_pipeline = create_render_pipeline(
        "shader.vert",
        "shader.frag",
        OBJVertex,
        {.FLOAT3, .FLOAT3, .FLOAT2, .UINT},
        true,
        swapchain_format
    )
    renderer.bbox_pipeline = create_render_pipeline(
        "bbox.vert",
        "bbox.frag",
        vec3,
        {.FLOAT3},
        true,
        swapchain_format,
        primitive_type = sdl.GPUPrimitiveType.LINELIST
    )
    renderer.heightmap_pipeline = create_render_pipeline(
        "heightmap.vert",
        "heightmap.frag",
        HeightMapVertex,
        {.FLOAT3, .FLOAT3},
        true,
        swapchain_format
    )
    renderer.skybox_pipeline = create_skybox_pipeline()

    renderer.default_sampler = sdl.CreateGPUSampler(g.gpu, {})
    assert(renderer.default_sampler != nil)

    renderer.light = PointLight {
        position = vec3{0, 10, 25},
        color = 1,
        power = 50
    }
    init_r2d(renderer)
    return renderer
}

RND_Destroy :: proc(renderer: ^Renderer) {
    using renderer
    sdl.ReleaseGPUGraphicsPipeline(g.gpu, obj_pipeline)
    sdl.ReleaseGPUGraphicsPipeline(g.gpu, bbox_pipeline)
    sdl.ReleaseGPUGraphicsPipeline(g.gpu, heightmap_pipeline)
    sdl.ReleaseGPUGraphicsPipeline(g.gpu, r2d.ui_pipeline)
    sdl.ReleaseGPUTexture(g.gpu, depth_texture)
    sdl.ReleaseGPUTexture(g.gpu, fallback_texture)
    sdl.ReleaseGPUSampler(g.gpu, default_sampler)
    sdl.ReleaseWindowFromGPUDevice(g.gpu, g.window)
    sdl.DestroyWindow(g.window)
    sdl.DestroyGPUDevice(g.gpu)
}

RND_ToggleFullscreen :: proc(state: ^AppState) {
    using state.renderer
    fullscreen = !fullscreen
    ok: bool
    window_bounds: sdl.Rect
    if !sdl.GetDisplayBounds(1, &window_bounds) {
        log.log(.Error, sdl.GetError())
    }
    sdl.ReleaseWindowFromGPUDevice(g.gpu, g.window)
    sdl.DestroyWindow(g.window)
    width, height: i32
    if fullscreen {
        width = window_bounds.w
        height = window_bounds.h
        g.window = sdl.CreateWindow("Demo window", width, height, {.FULLSCREEN})
        assert(g.window != nil)
        ok = sdl.ClaimWindowForGPUDevice(g.gpu, g.window); assert(ok)
    } else {
        width = 1280
        height = 720
        g.window = sdl.CreateWindow("Demo window", width, height, {}); assert(g.window != nil)
        ok = sdl.ClaimWindowForGPUDevice(g.gpu, g.window); assert(ok)
    }

    ok = sdl.SetGPUSwapchainParameters(g.gpu, g.window, .SDR_LINEAR, PRESENT_MODE); assert(ok)
    depth := sdl.CreateGPUTexture(g.gpu, {
        type = .D2,
        width = u32(width),
        height = u32(height),
        layer_count_or_depth = 1,
        num_levels = 1,
        format = .D32_FLOAT,
        usage = {.SAMPLER, .DEPTH_STENCIL_TARGET}
    })
    sdl.ReleaseGPUTexture(g.gpu, depth_texture)
    depth_texture = depth
    if state.props.ui_visible {
        ok = sdl.ShowCursor(); assert(ok)
        ok = sdl.SetWindowRelativeMouseMode(g.window, false); assert(ok)
    } else {
        ok = sdl.SetWindowRelativeMouseMode(g.window, true)
        ok = sdl.HideCursor(); assert(ok)
    }
    assert(ok)
    init_imgui(state)
}


frame_begin :: proc(
    vert_ubo: VertUBOGlobal, 
    frag_ubo: FragUBOGlobal
) -> Frame {
    cmd_buff := sdl.AcquireGPUCommandBuffer(g.gpu); assert(cmd_buff != nil)
    swapchain: ^sdl.GPUTexture
    ok := sdl.WaitAndAcquireGPUSwapchainTexture(cmd_buff, g.window, &swapchain, nil, nil)
    win_size := get_window_size()
    frustum_planes := create_frustum_planes(vert_ubo.vp)
    assert(ok)
    assert(cmd_buff  != nil)
    assert(swapchain != nil)
    return Frame {
        cmd_buff,
        swapchain,
        nil,
        win_size,
        vert_ubo,
        frag_ubo,
        frustum_planes
    }
}

get_vertex_ubo_global :: proc(player: Player) -> VertUBOGlobal {
    proj_matrix := create_proj_matrix(90)
    view_matrix := create_view_matrix(player)
    return VertUBOGlobal {
        vp = proj_matrix * view_matrix,
        inv_view_mat = linalg.inverse(view_matrix),
        inv_projection_mat = linalg.inverse(proj_matrix)
    }
}

frame_submit :: proc(frame: Frame) {
    ok := sdl.SubmitGPUCommandBuffer(frame.cmd_buff)
    assert(ok)
}

create_frag_ubo :: proc(state: ^AppState) -> FragUBOGlobal {
    using state
    return FragUBOGlobal {
        light_pos = renderer.light.position,
        light_color = renderer.light.color,
        light_intensity = renderer.light.power,
        view_pos = get_camera_position(player)
    }
}

render_heightmap :: proc (height_map: HeightMap, frame: Frame) {
    scale := height_map.scale
    sdl.PushGPUVertexUniformData(frame.cmd_buff, 1, &scale, size_of(vec3))
    bindings: [2]sdl.GPUBufferBinding = {
        sdl.GPUBufferBinding{buffer = height_map.vbo},
        sdl.GPUBufferBinding{buffer = height_map.ibo}
    }
    sdl.BindGPUVertexBuffers(frame.render_pass, 0, &bindings[0], 1)
    sdl.BindGPUIndexBuffer(frame.render_pass, bindings[1], ._32BIT)
    sdl.DrawGPUIndexedPrimitives(frame.render_pass, height_map.num_indices, 1, 0, 0, 0)
}

begin_3d :: proc(renderer: Renderer, frame: ^Frame) {
    assert(frame.cmd_buff != nil)
    assert(frame.swapchain != nil)
    color_target := sdl.GPUColorTargetInfo {
        texture = frame.swapchain,
        load_op = .CLEAR,
        store_op = .STORE,
        clear_color = 0,
    }
    depth_target_info := sdl.GPUDepthStencilTargetInfo {
        texture = renderer.depth_texture,
        clear_depth = 1,
        load_op = .CLEAR,
        store_op = .STORE,
        stencil_load_op = .CLEAR,
        stencil_store_op = .STORE,
        cycle = true,
        clear_stencil = 1,
    }
    frame.render_pass = sdl.BeginGPURenderPass(frame.cmd_buff, &color_target, 1, &depth_target_info)
    assert(frame.render_pass != nil)
    sdl.PushGPUVertexUniformData(frame.cmd_buff, 0, &frame.vert_ubo_global, size_of(VertUBOGlobal))
    sdl.PushGPUFragmentUniformData(frame.cmd_buff, 0, &frame.frag_ubo_global, size_of(FragUBOGlobal))

}

submit_3d :: proc(frame: ^Frame) {
    sdl.EndGPURenderPass(frame.render_pass)
    frame.render_pass = nil
}

render_3D :: proc(state: ^AppState, frame: ^Frame) {
    using state, frame

    assert(cmd_buff  != nil)
    assert(swapchain != nil)
    assert(render_pass != nil)

    // Heightmap
    if height_map != nil {
        assert(renderer.heightmap_pipeline != nil)
        sdl.BindGPUGraphicsPipeline(render_pass, renderer.heightmap_pipeline)
        debug_info.draw_call_count += 1
        render_heightmap(height_map^, frame^)
    }

    // Entities
    fallback_binding := sdl.GPUTextureSamplerBinding {
        texture = renderer.fallback_texture,
        sampler = renderer.default_sampler
    }
    sdl.BindGPUGraphicsPipeline(render_pass, renderer.obj_pipeline)
    for &model in state.models {
        bindings: [1]sdl.GPUBufferBinding = {{buffer = model.vbo}}
        sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)
        sdl.BindGPUFragmentStorageBuffers(render_pass, 0, &model.material_buffer, 1)
        tex_bindings: [8]sdl.GPUTextureSamplerBinding
        for tex, i in 0..<8 {
            tex_bindings[i] = len(model.textures) > i ? {
                texture = model.textures[i].texture, sampler = renderer.default_sampler
            } : {
                texture = renderer.fallback_texture, sampler = renderer.default_sampler
            }
        }
        sdl.BindGPUFragmentSamplers(frame.render_pass, 0, raw_data(tex_bindings[:]), len(tex_bindings))
        for entity in state.entities {
            if &model != entity.model do continue
            if !is_visible(entity, frustum_planes) do continue

            model_matrix := linalg.matrix4_from_trs_f32(entity.transform.translation, entity.transform.rotation, 1)
            normal_matrix := linalg.inverse_transpose(model_matrix)
            vert_ubo_local := VertUBOLocal {
                model_mat = model_matrix,
                normal_mat = normal_matrix
            }
            sdl.PushGPUVertexUniformData(cmd_buff, 1, &vert_ubo_local, size_of(VertUBOLocal))
            debug_info.draw_call_count += 1
            sdl.DrawGPUPrimitives(render_pass, model.num_vertices, 1, 0, 0)           
        }
    }

    // Bounding Box
    if g.debug_draw {
        sdl.BindGPUGraphicsPipeline(render_pass, renderer.bbox_pipeline)
        for &model in models {
            bindings: [1]sdl.GPUBufferBinding = { sdl.GPUBufferBinding { buffer = model.aabb_vbo } } 
            sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)
            for entity in entities {
                if entity.model != &model do continue
                if !is_visible(entity, frustum_planes) do continue
                model_matrix := linalg.matrix4_translate_f32(entity.transform.translation)
                sdl.PushGPUVertexUniformData(cmd_buff, 1, &model_matrix, size_of(mat4))
                debug_info.draw_call_count += 1
                sdl.DrawGPUPrimitives(render_pass, u32(24*len(model.aabbs)), 1, 0, 0)
            }
            // using model
        }
    }

    // Skybox
    {
        sdl.BindGPUGraphicsPipeline(render_pass, renderer.skybox_pipeline)
        sdl.BindGPUFragmentSamplers(render_pass, 0, &(sdl.GPUTextureSamplerBinding  {
            texture = renderer.skybox_texture,
            sampler = renderer.default_sampler
        }), 1)
        debug_info.draw_call_count += 1
        sdl.DrawGPUPrimitives(render_pass, 3, 1, 0, 0)
    }

}

get_camera_position :: proc(player: Player) -> (camera_position: vec3) {
    camera_position = -player.position
    camera_position.y -= 2
    return
}

create_view_matrix :: proc(player: Player) -> linalg.Matrix4f32 {
    using linalg, player
    pitch_matrix := matrix4_rotate_f32(to_radians(rotation.x), {1, 0, 0})
    yaw_matrix := matrix4_rotate_f32(to_radians(rotation.y), {0, 1, 0})
    position_matrix := matrix4_translate_f32(get_camera_position(player))
    return pitch_matrix * yaw_matrix * position_matrix
}

create_proj_matrix :: proc(fov: f32) -> mat4 {
    using linalg
    win_size := get_window_size()
    aspect := win_size.x / win_size.y
    return matrix4_perspective_f32(
        to_radians(fov), 
        aspect, 
        0.01, 
        1000
    )
}

get_window_size :: proc() -> vec2 {
    x, y: i32
    ok := sdl.GetWindowSize(g.window, &x, &y)
    if ok do return {f32(x), f32(y)}
    sdl.ClearError()
    log.logf(.Error, "SDL Error: {}", sdl.GetError())
    panic("")
}

create_buffer_with_data :: proc(
    transfer_buffer: ^sdl.GPUTransferBuffer,
    copy_pass: ^sdl.GPUCopyPass,
    usage: sdl.GPUBufferUsageFlags,
    data: []$T
) -> ^sdl.GPUBuffer {
    len_bytes := len(data) * size_of(T)

    buffer := sdl.CreateGPUBuffer(g.gpu, {
        usage = usage,
        size = u32(len_bytes),
    });

    transfer_mem := cast([^]byte) sdl.MapGPUTransferBuffer(g.gpu, transfer_buffer, true)
    mem.copy(transfer_mem, raw_data(data), len_bytes)
    sdl.UnmapGPUTransferBuffer(g.gpu, transfer_buffer)
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

upload_texture :: proc(
    copy_pass: ^sdl.GPUCopyPass, 
    pixels: []byte, 
    size: [2]u32
) -> ^sdl.GPUTexture {

    texture := sdl.CreateGPUTexture(g.gpu, {
        type = .D2,
        format = .R8G8B8A8_UNORM_SRGB,
        usage = {.SAMPLER},
        width = u32(size.x),
        height = u32(size.y),
        layer_count_or_depth = 1,
        num_levels = 1
    })

    tex_transfer_buffer := sdl.CreateGPUTransferBuffer(g.gpu, {
        usage = .UPLOAD,
        size = u32(len(pixels)),
    }); assert(tex_transfer_buffer != nil)

    tex_transfer_mem := sdl.MapGPUTransferBuffer(g.gpu, tex_transfer_buffer, false)
    mem.copy(tex_transfer_mem, raw_data(pixels), len(pixels))
    sdl.UnmapGPUTransferBuffer(g.gpu, tex_transfer_buffer)
    sdl.UploadToGPUTexture(copy_pass, 
        {transfer_buffer = tex_transfer_buffer},
        {texture = texture, w = u32(size.x), h = u32(size.y), d = 1},
        false
    )

    sdl.ReleaseGPUTransferBuffer(g.gpu, tex_transfer_buffer)
    return texture
}

upload_cubemap_texture_sides :: proc(
    copy_pass: ^sdl.GPUCopyPass,
    pixels: [sdl.GPUCubeMapFace][]byte,
    size: u32
) -> ^sdl.GPUTexture {
	texture := sdl.CreateGPUTexture(g.gpu, {
		type = .CUBE,
		format = .R8G8B8A8_UNORM_SRGB, // pixels are in sRGB, converted to linear in shaders
		usage = {.SAMPLER},
		width = size,
		height = size,
		layer_count_or_depth = 6,
		num_levels = 1,
	})

	side_byte_size := int(size * size * 4) // 4 bytes per pixel
	for side_pixels in pixels do assert(len(side_pixels) == side_byte_size)

	tex_transfer_buf := sdl.CreateGPUTransferBuffer(g.gpu, {
		usage = .UPLOAD,
		size = u32(side_byte_size * 6)
	})
	defer sdl.ReleaseGPUTransferBuffer(g.gpu, tex_transfer_buf)

	tex_transfer_mem := cast([^]byte)sdl.MapGPUTransferBuffer(g.gpu, tex_transfer_buf, false)

	offset := 0
	for side_pixels in pixels {
		mem.copy(tex_transfer_mem[offset:], raw_data(side_pixels), side_byte_size)
		offset += side_byte_size
	}

	sdl.UnmapGPUTransferBuffer(g.gpu, tex_transfer_buf)

	offset = 0
	for side in 0..<len(pixels) {
		sdl.UploadToGPUTexture(copy_pass,
			{transfer_buffer = tex_transfer_buf, offset = u32(offset)},
			{texture = texture, layer = u32(side), w = size, h = size, d = 1},
			false
		)
		offset += side_byte_size
	}

	return texture
}

load_shader :: proc(shaderfile: string) -> ^sdl.GPUShader {
    stage: sdl.GPUShaderStage
    switch filepath.ext(shaderfile) {
        case ".vert":
            stage = .VERTEX
        case ".frag":
            stage = .FRAGMENT
    }

    shaderfile_path := filepath.join({"shaders", "out", shaderfile})
    filename := strings.concatenate({shaderfile_path, ".spv"}, context.temp_allocator)
    code, ok := os.read_entire_file_from_filename(filename, context.temp_allocator); assert(ok)
    info := load_shader_info(shaderfile_path)
    return sdl.CreateGPUShader(g.gpu, {
        code_size = len(code),
        code = raw_data(code),
        entrypoint = "main",
        format = {.SPIRV},
        stage = stage,
        num_uniform_buffers = info.uniform_buffers,
        num_samplers = info.samplers,
        num_storage_buffers = info.storage_buffers,
        num_storage_textures = info.storage_textures
    })
}

Shader_Info :: struct {
    samplers:           u32,
    storage_textures:   u32,
    storage_buffers:    u32,
    uniform_buffers:    u32
}

load_shader_info :: proc(shaderfile: string) -> Shader_Info {
    json_filename := strings.concatenate({shaderfile, ".json"}, context.temp_allocator)
    json_data, ok := os.read_entire_file_from_filename(json_filename, context.temp_allocator); assert(ok)
    result: Shader_Info
    err := json.unmarshal(json_data, &result, allocator = context.temp_allocator); assert(err == nil)
    return result
}

create_skybox_pipeline :: proc() -> ^sdl.GPUGraphicsPipeline {
    vert_shader := load_shader("skybox.vert"); defer sdl.ReleaseGPUShader(g.gpu, vert_shader)
    frag_shader := load_shader("skybox.frag"); defer sdl.ReleaseGPUShader(g.gpu, frag_shader)
    format := sdl.GetGPUSwapchainTextureFormat(g.gpu, g.window)
    pipeline := sdl.CreateGPUGraphicsPipeline(g.gpu, {
        vertex_shader = vert_shader,
        fragment_shader = frag_shader,
        primitive_type = .TRIANGLELIST,
        depth_stencil_state = {
            enable_depth_test = true,
            enable_depth_write = false,
            compare_op = .EQUAL,
        },
        rasterizer_state = {cull_mode = .BACK},
        target_info = {
            num_color_targets = 1,
            color_target_descriptions = &(sdl.GPUColorTargetDescription {
                format = format
            }),
            has_depth_stencil_target = true,
            depth_stencil_format = .D32_FLOAT
        }
    }); assert(pipeline != nil)
    return pipeline
}

is_visible :: proc(entity: Entity, frustum_planes: [6]vec4) -> bool {
    if entity.model == nil do return false
    for aabb in entity.model.aabbs {
        if aabb_intersects_frustum(frustum_planes, {
            aabb.min + entity.transform.translation,
            aabb.max + entity.transform.translation
        }) { return true }
    }
    return false
}

create_render_pipeline :: proc(
    vert_shader: string,
    frag_shader: string,
    $vertex_type: typeid,
    vb_attribute_formats: []sdl.GPUVertexElementFormat,
    use_depth_buffer: bool,
    swapchain_format := sdl.GPUTextureFormat.INVALID,
    cull_mode := sdl.GPUCullMode.BACK,
    primitive_type := sdl.GPUPrimitiveType.TRIANGLELIST,
    num_vertex_buffers := 1,
    alpha_blend := false
) -> ^sdl.GPUGraphicsPipeline {
    vert_shader := load_shader(vert_shader); defer sdl.ReleaseGPUShader(g.gpu, vert_shader)
    frag_shader := load_shader(frag_shader); defer sdl.ReleaseGPUShader(g.gpu, frag_shader)

    vb_descriptions := make([]sdl.GPUVertexBufferDescription, num_vertex_buffers, context.temp_allocator)
    for i in 0..<num_vertex_buffers {
        vb_descriptions[i] = sdl.GPUVertexBufferDescription {
            slot = u32(i),
            pitch = u32(size_of(vertex_type)),
            input_rate = .VERTEX,
            instance_step_rate = 0
        }
    }

    vb_attributes := make([]sdl.GPUVertexAttribute, len(vb_attribute_formats), context.temp_allocator)
    offset: u32
    for format, i in vb_attribute_formats {
        vb_attributes[i] = sdl.GPUVertexAttribute {
            location = u32(i),
            buffer_slot = 0,
            format = format,
            offset = offset
        }
        offset += attribute_size(format)
    }
    swapchain_format := swapchain_format
    if swapchain_format == .INVALID {
        swapchain_format = sdl.GetGPUSwapchainTextureFormat(g.gpu, g.window)
    }
    pipeline := sdl.CreateGPUGraphicsPipeline(g.gpu, {
        vertex_shader = vert_shader,
        fragment_shader = frag_shader,
        primitive_type = primitive_type,
        target_info = {
            num_color_targets = 1,
            color_target_descriptions = &(sdl.GPUColorTargetDescription {
                format = swapchain_format,
                blend_state = {
                    src_color_blendfactor = .SRC_ALPHA,
                    dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
                    color_blend_op = .ADD,
                    src_alpha_blendfactor = .ONE,
                    dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA,
                    alpha_blend_op = .ADD,
                    enable_blend = alpha_blend
                }
            }),
            has_depth_stencil_target = use_depth_buffer,
            depth_stencil_format = .D32_FLOAT,
        },
        vertex_input_state = {
            vertex_buffer_descriptions = &vb_descriptions[0],
            num_vertex_buffers = 1,
            vertex_attributes = &vb_attributes[0],
            num_vertex_attributes = u32(len(vb_attributes))
        },
        rasterizer_state = {
            fill_mode = primitive_type == .TRIANGLELIST ? .FILL : .LINE,
            cull_mode = cull_mode
        },
        depth_stencil_state = {
            enable_depth_test = use_depth_buffer,
            enable_depth_write = use_depth_buffer,
            compare_op = .LESS,
        }
    }); assert(pipeline != nil)
    return pipeline
}

attribute_size :: proc(a: sdl.GPUVertexElementFormat) -> u32 {
    #partial switch a {
        case .FLOAT2: return size_of(vec2)
        case .FLOAT3: return size_of(vec3)
        case .FLOAT4: return size_of(vec4)
        case .UINT:   return size_of(u32)
        case .UINT2:  return size_of(u32)*2
        case .UINT3:  return size_of(u32)*3
        case .UINT4:  return size_of(u32)*4
        case: {
            panic("Invalid attribute")
        }
    }
}