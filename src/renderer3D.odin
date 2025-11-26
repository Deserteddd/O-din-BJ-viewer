package obj_viewer

import "core:fmt"
import "core:reflect"
import "core:mem"
import "core:math/linalg"
import "core:log"
import "core:strings"
import "core:c"
import "core:os"
import "core:path/filepath"
import "core:encoding/json"
import "base:runtime"
import sdl "vendor:sdl3"

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
    using renderer
    pixels, size := load_pixels_byte("assets/err_tex.jpg")
    defer free_pixels(pixels)

    copy_commands := sdl.AcquireGPUCommandBuffer(g.gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)

    renderer.fallback_texture = upload_texture(copy_pass, pixels, {u32(size.x), u32(size.y)})
    renderer.default_sampler = sdl.CreateGPUSampler(g.gpu, {})
    assert(renderer.default_sampler != nil)
    pipelines[.QUAD] = create_render_pipeline(
        "ui.vert",
        "ui.frag",
        Vertex2D,
        false,
    )
    pipelines[.SPRITESHEET] = create_render_pipeline(
        "spritesheet.vert",
        "spritesheet.frag",
        Vertex2D,
        false,
    )
    pipelines[.OBJ] = create_render_pipeline(
        "shader.vert",
        "shader.frag",
        OBJVertex,
    )
    pipelines[.AABB] = create_render_pipeline(
        "bbox.vert",
        "bbox.frag",
        vec3,
        primitive_type = sdl.GPUPrimitiveType.LINELIST
    )
    pipelines[.HEIGHTMAP] = create_render_pipeline(
        "heightmap.vert",
        "heightmap.frag",
        HeightMapVertex,
        wireframe = true
    )
    pipelines[.SKYBOX] = create_skybox_pipeline()
    crosshair = load_sprite("assets/crosshair.png", copy_pass)
    quad = init_quad(copy_pass)
    skybox_texture = load_cubemap_texture(copy_pass, {
        .POSITIVEX = "assets/skybox/right.png",
        .NEGATIVEX = "assets/skybox/left.png",
        .POSITIVEY = "assets/skybox/top.png",
        .NEGATIVEY = "assets/skybox/bottom.png",
        .POSITIVEZ = "assets/skybox/front.png",
        .NEGATIVEZ = "assets/skybox/back.png",
    })

    width, height: i32
    ok := sdl.GetWindowSize(g.window, &width, &height); assert(ok)
    depth_texture = sdl.CreateGPUTexture(g.gpu, {
        type = .D2,
        width = u32(width),
        height = u32(height),
        layer_count_or_depth = 1,
        num_levels = 1,
        format = .D32_FLOAT,
        usage = {.SAMPLER, .DEPTH_STENCIL_TARGET}
    })

    light = PointLight {
        position = vec3{0, 10, 25},
        color = 1,
        power = 50
    }
    sdl.EndGPUCopyPass(copy_pass)
    ok = sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)
    return renderer
}

toggle_fullscreen :: proc() {
    g.fullscreen = !g.fullscreen
    ok: bool
    window_bounds: sdl.Rect
    if !sdl.GetDisplayBounds(1, &window_bounds) {
        log.log(.Error, sdl.GetError())
    }
    sdl.ReleaseWindowFromGPUDevice(g.gpu, g.window)
    sdl.DestroyWindow(g.window)
    width, height: i32
    if g.fullscreen {
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
    present_mode: sdl.GPUPresentMode = VSYNC? .VSYNC : .IMMEDIATE
    ok = sdl.SetGPUSwapchainParameters(g.gpu, g.window, .SDR_LINEAR, present_mode); assert(ok)
    depth := sdl.CreateGPUTexture(g.gpu, {
        type = .D2,
        width = u32(width),
        height = u32(height),
        layer_count_or_depth = 1,
        num_levels = 1,
        format = .D32_FLOAT,
        usage = {.SAMPLER, .DEPTH_STENCIL_TARGET}
    })
    sdl.ReleaseGPUTexture(g.gpu, g.renderer.depth_texture)
    g.renderer.depth_texture = depth
    switch g.mode {
        case .EDIT:
            ok = sdl.SetWindowRelativeMouseMode(g.window, false); assert(ok)
        case .PLAY:
            ok = sdl.SetWindowRelativeMouseMode(g.window, true)
    }
    assert(ok)
    init_imgui()
    g.editor.sidebar_left.rect.h  = f32(height)
    g.editor.sidebar_right.rect.h = f32(height)
    g.editor.sidebar_right.rect.x = f32(width-300)
    _ = sdl.GetTicks()
}


frame_begin :: proc(
) -> Frame {
    cmd_buff := sdl.AcquireGPUCommandBuffer(g.gpu); assert(cmd_buff != nil)
    assert(cmd_buff  != nil)
    swapchain: ^sdl.GPUTexture
    ok := sdl.WaitAndAcquireGPUSwapchainTexture(cmd_buff, g.window, &swapchain, nil, nil)
    assert(swapchain != nil)
    assert(ok)
    win_size := get_window_size()
    vert_ubo := get_vertex_ubo_global()
    frag_ubo := get_fragment_ubo_global()
    frustum_planes := create_frustum_planes(vert_ubo.vp)
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

get_vertex_ubo_global :: proc() -> VertUBOGlobal {
    proj_matrix := create_proj_matrix()
    view_matrix := create_view_matrix()
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

get_fragment_ubo_global :: proc() -> FragUBOGlobal {
    return FragUBOGlobal {
        light_pos = g.renderer.light.position,
        light_color = g.renderer.light.color,
        light_intensity = g.renderer.light.power,
        view_pos = get_camera_position()
    }
}

render_heightmap :: proc (frame: Frame) {
    bind_pipeline(frame, .HEIGHTMAP)
    time := f32(g.total_time)
    sdl.PushGPUVertexUniformData(frame.cmd_buff, 1, &time, size_of(f32))
    bindings: [2]sdl.GPUBufferBinding = {
        sdl.GPUBufferBinding{buffer = g.heightmap.vbo},
        sdl.GPUBufferBinding{buffer = g.heightmap.ibo}
    }
    sdl.BindGPUVertexBuffers(frame.render_pass, 0, &bindings[0], 1)
    sdl.BindGPUIndexBuffer(frame.render_pass, bindings[1], ._32BIT)
    sdl.DrawGPUIndexedPrimitives(frame.render_pass, g.heightmap.num_indices, 1, 0, 0, 0)
}

begin_3d :: proc(frame: ^Frame) {
    assert(frame.cmd_buff != nil)
    assert(frame.swapchain != nil)
    color_target := sdl.GPUColorTargetInfo {
        texture = frame.swapchain,
        load_op = .CLEAR,
        store_op = .STORE,
        clear_color = 0,
    }
    depth_target_info := sdl.GPUDepthStencilTargetInfo {
        texture = g.renderer.depth_texture,
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

render_3D :: proc(scene: Scene, frame: Frame) {
    assert(frame.cmd_buff  != nil)
    assert(frame.swapchain != nil)
    assert(frame.render_pass != nil)

    // Entities
    fallback_binding := sdl.GPUTextureSamplerBinding {
        texture = g.renderer.fallback_texture,
        sampler = g.renderer.default_sampler
    }
    bind_pipeline(frame, .OBJ)
    for &model in scene.models {
        bindings: [1]sdl.GPUBufferBinding = {{buffer = model.vbo}}
        sdl.BindGPUVertexBuffers(frame.render_pass, 0, &bindings[0], 1)
        sdl.BindGPUFragmentStorageBuffers(frame.render_pass, 0, &model.material_buffer, 1)
        tex_bindings: [8]sdl.GPUTextureSamplerBinding
        for tex, i in 0..<8 {
            tex_bindings[i] = len(model.textures) > i ? {
                texture = model.textures[i].texture, sampler = g.renderer.default_sampler
            } : {
                texture = g.renderer.fallback_texture, sampler = g.renderer.default_sampler
            }
        }
        sdl.BindGPUFragmentSamplers(frame.render_pass, 0, raw_data(tex_bindings[:]), len(tex_bindings))
        for entity in scene.entities {
            if &model != entity.model do continue
            if !is_visible(entity, frame.frustum_planes) do continue

            model_matrix := linalg.matrix4_from_trs_f32(
                entity.transform.translation, 
                entity.transform.rotation,
                entity.transform.scale
            )
            normal_matrix := linalg.inverse_transpose(model_matrix)
            vert_ubo_local := VertUBOLocal {
                model_mat = model_matrix,
                normal_mat = normal_matrix
            }
            sdl.PushGPUVertexUniformData(frame.cmd_buff, 1, &vert_ubo_local, size_of(VertUBOLocal))
            g.debug_info.draw_call_count += 1
            sdl.DrawGPUPrimitives(frame.render_pass, model.num_vertices, 1, 0, 0)           
        }
    }

    // Bounding Box
    if g.mode == .EDIT {
        for entity in scene.entities {
            if entity.model == nil do continue
            if entity.id != g.editor.selected_entity do continue
            if !is_visible(entity, frame.frustum_planes) do continue
            bind_pipeline(frame, .AABB)
            bindings: [1]sdl.GPUBufferBinding = { sdl.GPUBufferBinding { buffer = entity.model.aabb_vbo } } 
            sdl.BindGPUVertexBuffers(frame.render_pass, 0, &bindings[0], 1)
            model_matrix := linalg.matrix4_from_trs(
                entity.transform.translation,
                entity.transform.rotation,
                entity.transform.scale
            )
            sdl.PushGPUVertexUniformData(frame.cmd_buff, 1, &model_matrix, size_of(mat4))
            g.debug_info.draw_call_count += 1
            sdl.DrawGPUPrimitives(frame.render_pass, u32(24*len(entity.model.aabbs)), 1, 0, 0)
            break
        }
    }

    // Skybox
    {
        bind_pipeline(frame, .SKYBOX)
        sdl.BindGPUFragmentSamplers(frame.render_pass, 0, &(sdl.GPUTextureSamplerBinding  {
            texture = g.renderer.skybox_texture,
            sampler = g.renderer.default_sampler
        }), 1)
        g.debug_info.draw_call_count += 1
        sdl.DrawGPUPrimitives(frame.render_pass, 3, 1, 0, 0)
    }

}

get_camera_position :: proc() -> (camera_position: vec3) {
    camera_position = -g.player.position
    camera_position.y -= 2
    return
}

create_view_matrix :: proc() -> linalg.Matrix4f32 {
    using linalg, g.player
    pitch_matrix := matrix4_rotate_f32(to_radians(rotation.x), {1, 0, 0})
    yaw_matrix := matrix4_rotate_f32(to_radians(rotation.y), {0, 1, 0})
    position_matrix := matrix4_translate_f32(get_camera_position())
    return pitch_matrix * yaw_matrix * position_matrix
}

create_proj_matrix :: proc() -> mat4 {
    using linalg
    win_size := get_window_size()
    aspect := win_size.x / win_size.y
    return matrix4_perspective_f32(
        to_radians(g.fov), 
        aspect, 
        0.01, 
        1000
    )
}

get_window_size :: proc() -> vec2 {
    x, y: i32
    ok := sdl.GetWindowSize(g.window, &x, &y); assert(ok)
    return {f32(x), f32(y)}
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
    }); assert(texture != nil)

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
            aabb.min * entity.transform.scale + entity.transform.translation,
            aabb.max * entity.transform.scale + entity.transform.translation
        }) { return true }
    }
    return false
}

create_render_pipeline :: proc(
    vert_shader: string,
    frag_shader: string,
    $vertex_type: typeid,
    use_depth_buffer := true,
    primitive_type := sdl.GPUPrimitiveType.TRIANGLELIST,
    wireframe := false
) -> ^sdl.GPUGraphicsPipeline {
    vert_shader := load_shader(vert_shader); defer sdl.ReleaseGPUShader(g.gpu, vert_shader)
    frag_shader := load_shader(frag_shader); defer sdl.ReleaseGPUShader(g.gpu, frag_shader)

    vb_descriptions: []sdl.GPUVertexBufferDescription = {sdl.GPUVertexBufferDescription {
        slot = 0,
        pitch = u32(size_of(vertex_type)),
        input_rate = .VERTEX,
        instance_step_rate = 0
    }}
    vb_attribute_data := get_vb_layout(vertex_type)
    vb_attributes := make([]sdl.GPUVertexAttribute, len(vb_attribute_data), context.temp_allocator)
    offset: u32
    for info, i in vb_attribute_data {
        vb_attributes[i] = sdl.GPUVertexAttribute {
            location = u32(i),
            buffer_slot = 0,
            format = info.format,
            offset = offset
        }
        offset += info.size
    }
    swapchain_format := sdl.GetGPUSwapchainTextureFormat(g.gpu, g.window)
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
                    enable_blend = true
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
            fill_mode = wireframe ? .LINE : .FILL,
            cull_mode = .BACK
        },
        depth_stencil_state = {
            enable_depth_test = use_depth_buffer,
            enable_depth_write = use_depth_buffer,
            compare_op = .LESS,
        }
    }); assert(pipeline != nil)
    return pipeline
}

vbElementInfo :: struct {
    format: sdl.GPUVertexElementFormat,
    size: u32
}

get_vb_layout :: proc($vertex_type: typeid) -> []vbElementInfo {
    element_info_from_type :: proc(type: ^runtime.Type_Info) -> vbElementInfo {
        switch type {
            case type_info_of(vec2): return {.FLOAT2, size_of(vec2)}
            case type_info_of(vec3): return {.FLOAT3, size_of(vec3)}
            case type_info_of(vec4): return {.FLOAT4, size_of(vec4)}
            case type_info_of(u32):  return {.UINT,   size_of(uint)}
            case:
                return {.INVALID, 0}
        }
    }
    fields := reflect.struct_field_types(vertex_type)
    data := make([]vbElementInfo, len(fields) > 0 ? len(fields) : 1, context.temp_allocator)
    if len(data) == 1 {
        data[0] = element_info_from_type(type_info_of(vertex_type))
        return data
    }
    for field, i in fields {
        data[i] = element_info_from_type(field)
    }
    return data
}

