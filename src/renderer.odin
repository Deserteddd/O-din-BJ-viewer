package obj_viewer

import "core:mem"
import "core:math"
import "core:math/linalg"
import "core:fmt"
import "core:c"
import "core:time"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"
import im "shared:imgui"
import im_sdl "shared:imgui/imgui_impl_sdl3"
import im_sdlgpu "shared:imgui/imgui_impl_sdlgpu3"

vert_shader_code := #load("../shaders/spv/shader.vert.spv")
frag_shader_code := #load("../shaders/spv/shader.frag.spv")
bbox_vert_shader := #load("../shaders/spv/bbox.vert.spv")
bbox_frag_shader := #load("../shaders/spv/bbox.frag.spv")
shadow_shader_code := #load("../shaders/spv/shadow.vert.spv")
bias: f32

light_proj := linalg.matrix_ortho3d_f32(WORLD_SIZE.x, -WORLD_SIZE.x, WORLD_SIZE.z, -WORLD_SIZE.z, 0.001, 1000);

Renderer :: struct {
    window:             ^sdl.Window,
    gpu:                ^sdl.GPUDevice,
    pipeline3D:         ^sdl.GPUGraphicsPipeline,
    bbox_pipeline:      ^sdl.GPUGraphicsPipeline,
    depth_texture:      ^sdl.GPUTexture,
    fallback_texture:   ^sdl.GPUTexture,
    swapchain_texture:  ^sdl.GPUTexture,
    shadow_map:         ^sdl.GPUTexture,
    shadow_sampler:     ^sdl.GPUSampler,
    cmd_buff:           ^sdl.GPUCommandBuffer,
    shadow_pipeline:    ^sdl.GPUGraphicsPipeline,
    samplers:           [4]^sdl.GPUSampler,
    props:              RND_Props,
    light:              PointLight,
    light_orientation:  vec3,
    draw_distance:      f32
}

PointLight :: struct #packed {
    position: vec3,
    power:    f32,
    color:    vec4,
}

VertUniforms :: struct {
    modelview: matrix[4,4]f32,
    model: matrix[4,4]f32,
    position_offset: vec4,
}

RND_Props :: distinct bit_set[RND_Prop; u16]

RND_Prop :: enum u16 {
    FULLSCREEN = 0,
    SHADOWS = 1,
    WIREFRAME = 2,
}


RND_Init :: proc(props: RND_Props) -> Renderer {
    renderer: Renderer
    renderer.props = props
    ok := sdl.Init({.VIDEO}); assert(ok)
    window_flags: sdl.WindowFlags
    w, h: c.int = 1280, 720
    if .FULLSCREEN in props {
        window_flags += {.FULLSCREEN}
        w = 1920
        h = 1080
    } 
    window  := sdl.CreateWindow("Demo window", w, h, window_flags); assert(ok)
    ok = sdl.HideCursor(); assert(ok)
    ok = sdl.SetWindowRelativeMouseMode(window, true); assert(ok)
    width, height: i32
    sdl.GetWindowSize(window, &width, &height)
    gpu := sdl.CreateGPUDevice({.SPIRV}, false, nil); assert(gpu != nil)
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

    shadow_map := sdl.CreateGPUTexture(gpu, {
        type = .D2,
        width = 2048,
        height = 2048,
        layer_count_or_depth = 1,
        num_levels = 1,
        format = .D32_FLOAT,
        usage = {.SAMPLER, .DEPTH_STENCIL_TARGET}

    })
    renderer.shadow_map = shadow_map

    shadow_sampler := sdl.CreateGPUSampler(gpu, {
        enable_compare = true,
        address_mode_u = .CLAMP_TO_EDGE,
        address_mode_v = .CLAMP_TO_EDGE,
        address_mode_w = .CLAMP_TO_EDGE,
        compare_op = .LESS_OR_EQUAL,
    }); assert(shadow_sampler != nil)
    renderer.shadow_sampler = shadow_sampler

    build_bbox_pipeline(&renderer)
    build_3D_pipeline(&renderer)
    build_shadow_pipeline(&renderer)
    for i in 0..<4 {
        sampler := sdl.CreateGPUSampler(gpu, {}); assert(sampler != nil)
        renderer.samplers[i] = sampler
    }
    assert(renderer.bbox_pipeline != nil)
    renderer.light = PointLight {
        position = vec3{0, 50, 0},
        color = 1,
        power = 2000
    }
    renderer.light_orientation = {90, 0, 0}
    renderer.draw_distance = 100
    renderer.props += {.SHADOWS}
    return renderer
}

RND_Destroy :: proc(renderer: ^Renderer) {
    using renderer
    sdl.ReleaseGPUGraphicsPipeline(gpu, shadow_pipeline)
    sdl.ReleaseGPUGraphicsPipeline(gpu, pipeline3D)
    sdl.ReleaseGPUTexture(gpu, depth_texture)
    sdl.ReleaseGPUTexture(gpu, fallback_texture)
    sdl.ReleaseGPUTexture(gpu, swapchain_texture)
    sdl.ReleaseGPUTexture(gpu, shadow_map)
    for sampler in samplers {
        sdl.ReleaseGPUSampler(gpu, sampler)
    }
    sdl.ReleaseWindowFromGPUDevice(gpu, window)
    sdl.DestroyWindow(window)
    sdl.DestroyGPUDevice(gpu)
}

RND_ToggleFullscreen :: proc(state: ^AppState) {
    using state.renderer
    if .FULLSCREEN in props do props -= {.FULLSCREEN}
    else do props += {.FULLSCREEN}
    ok: bool
    sdl.ReleaseWindowFromGPUDevice(gpu, window)
    sdl.DestroyWindow(window)
    width, height: i32
    if .FULLSCREEN in props {
        width = 1920
        height = 1080
        new_window := sdl.CreateWindow("Demo window", width, height, {.FULLSCREEN}); assert(new_window != nil)
        window = new_window
        ok = sdl.ClaimWindowForGPUDevice(gpu, window)
        if !ok do fmt.println(sdl.GetError())
    } else {
        width = 1280
        height = 720
        new_window := sdl.CreateWindow("Demo window", width, height, {}); assert(window != nil)
        window = new_window
        ok = sdl.ClaimWindowForGPUDevice(gpu, window)
    }
    depth := sdl.CreateGPUTexture(gpu, {
        type = .D2,
        width = u32(width),
        height = u32(height),
        layer_count_or_depth = 1,
        num_levels = 1,
        format = .D32_FLOAT,
        usage = {.SAMPLER, .DEPTH_STENCIL_TARGET}
    })
    sdl.ReleaseGPUTexture(gpu, depth_texture)
    depth_texture = depth
    if state.mode == .MENU {
        ok = sdl.ShowCursor(); assert(ok)
        ok = sdl.SetWindowRelativeMouseMode(window, false); assert(ok)
    } else {
        ok = sdl.SetWindowRelativeMouseMode(window, true)
        ok = sdl.HideCursor(); assert(ok)
    }
    assert(ok)
    init_imgui(state)
}

RND_DrawUI :: proc(state: ^AppState) {
    using state
    im_sdlgpu.NewFrame()
    im_sdl.NewFrame()
    im.NewFrame()
    if state.mode == .MENU {
        if im.Begin("Properties") {
            im.LabelText("", "Light")
            im.DragFloat3("position", &renderer.light.position, 0.5, -200, 200)
            im.DragFloat3("orientation", &renderer.light_orientation, 0.5, -180, 200)
            im.DragFloat("intensity", &renderer.light.power, 10, 0, 10000)
            im.ColorPicker3("color", transmute(^vec3)&renderer.light.color, {.InputRGB})
            im.DragFloat("Depth bias", &bias, 0.001, -1, 1)
            im.LabelText("", "General")
            im.DragFloat3("Player position", &state.player.position, 0.25, 0, 60)
            im.DragFloat("Draw distance", &state.renderer.draw_distance, 0.5, 10, 250)
            if im.Button("Random tiles") do randomize_tile_positions(state)
            wireframe := .WIREFRAME in renderer.props
            im.Checkbox("Wireframe", &wireframe)
            if wireframe do renderer.props += {.WIREFRAME}
            else do renderer.props -= {.WIREFRAME}
        }
        im.End()
    }
    if im.Begin("info", nil, {.NoTitleBar, .NoMouseInputs}) {
        w, h: i32
        sdl.GetWindowSize(state.renderer.window, &w, &h)
        im.SetWindowPos(vec2{f32(w-120), 0})
        im.SetWindowSize(vec2{120, 0})
        frame_time_float := i32(math.round(1/f32(time.duration_seconds(debug_info.frame_time))))
        im.SetNextItemWidth(50)
        im.DragInt("FPS", &frame_time_float)
        rendered := i32(debug_info.rendered)
        im.SetNextItemWidth(50)
        im.DragInt("Slabs", &rendered)
        im.SetNextItemWidth(50)
        im.DragFloat("Speed", &debug_info.player_speed)
    }
    im.End()
    im.Render()
    im_draw_data := im.GetDrawData()
    im_sdlgpu.PrepareDrawData(im_draw_data, renderer.cmd_buff)
    im_color_target := sdl.GPUColorTargetInfo {
        texture = renderer.swapchain_texture,
        load_op = .LOAD,
        store_op = .STORE
    }
    im_render_pass := sdl.BeginGPURenderPass(renderer.cmd_buff, &im_color_target, 1, nil)
    assert(im_render_pass != nil)
    im_sdlgpu.RenderDrawData(im_draw_data, renderer.cmd_buff, im_render_pass)
    sdl.EndGPURenderPass(im_render_pass)
}

RND_FrameBegin :: proc(renderer: ^Renderer) {
    assert(renderer.cmd_buff == nil)
    assert(renderer.swapchain_texture == nil)
    cmd_buff := sdl.AcquireGPUCommandBuffer(renderer.gpu); assert(cmd_buff != nil)
    ok := sdl.WaitAndAcquireGPUSwapchainTexture(cmd_buff, renderer.window, &renderer.swapchain_texture, nil, nil)
    if !ok do fmt.println(sdl.GetError())
    renderer.cmd_buff = cmd_buff
}

RND_FrameSubmit :: proc(renderer: ^Renderer) -> bool {
    ok := sdl.SubmitGPUCommandBuffer(renderer.cmd_buff)
    renderer.cmd_buff = nil
    renderer.swapchain_texture = nil
    return ok
}

RND_DrawEntities :: proc(state: ^AppState) {
    using state
    if .SHADOWS in renderer.props {
        shadow_pass(state)
        renderer.props -= {.SHADOWS}
    }
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
        clear_stencil = 1,
    }
    debug_info.rendered = 0

    proj_matrix := create_proj_matrix(renderer)
    view_matrix := create_view_matrix(player.position, player.rotation)
    frustum_planes := create_furstum_planes(proj_matrix * view_matrix)

    light_view := create_view_matrix({0, WORLD_SIZE.y, 0}, renderer.light_orientation)
    light_viewproj := light_proj * light_view

    render_pass := sdl.BeginGPURenderPass(renderer.cmd_buff, &color_target, 1, &depth_target_info); assert(render_pass != nil)
    sdl.BindGPUGraphicsPipeline(render_pass, renderer.pipeline3D)
    sdl.PushGPUFragmentUniformData(renderer.cmd_buff, 0, &renderer.light, size_of(PointLight))
    sdl.PushGPUFragmentUniformData(renderer.cmd_buff, 1, &bias, size_of(f32))
    sdl.PushGPUVertexUniformData(renderer.cmd_buff, 2, &proj_matrix, size_of(matrix[4,4]f32))
    sdl.PushGPUVertexUniformData(renderer.cmd_buff, 1, &light_viewproj, size_of(matrix[4,4]f32))
    for &model, model_index in models {
        bindings: [1]sdl.GPUBufferBinding = { sdl.GPUBufferBinding { buffer = model.vbo } } 
        sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)
        texture_count := len(model.textures)+1
        sdl.BindGPUFragmentSamplers(render_pass, 0, 
            &(sdl.GPUTextureSamplerBinding{texture = renderer.shadow_map, sampler = renderer.shadow_sampler}), u32(texture_count)
        )
        for tex, i in model.textures {
            sdl.BindGPUFragmentSamplers(render_pass, u32(i+1), 
                &(sdl.GPUTextureSamplerBinding{texture = tex, sampler = renderer.samplers[i]}), u32(texture_count)
            )
        }
        for i in texture_count..<4 {
            if texture_count == 1 do texture_count = 2
            sdl.BindGPUFragmentSamplers(render_pass, u32(i), 
                &(sdl.GPUTextureSamplerBinding{texture = renderer.fallback_texture, sampler = renderer.samplers[i]}), u32(texture_count)
            )
        }

        sdl.BindGPUFragmentStorageBuffers(render_pass, 0, &model.material_buffer, 1)
        for &entity, i in entities {
            if entity.model.vbo != model.vbo do continue
            if linalg.distance(player.position, entity.position) > renderer.draw_distance - 1 &&
                model_index != 0 { continue }
            if !aabb_intersects_frustum(frustum_planes, state.aabbs[i]) do continue
            debug_info.rendered += 1
            vert_ubo := create_vertex_UBO(entity, view_matrix)
            sdl.PushGPUVertexUniformData(renderer.cmd_buff, 0, &vert_ubo, size_of(VertUniforms))
            sdl.DrawGPUPrimitives(render_pass, model.num_vertices, 1, 0, 0)
        }
    }
    sdl.EndGPURenderPass(render_pass)
}

shadow_pass :: proc(state: ^AppState) {
    using state
    assert(renderer.cmd_buff != nil)
    assert(renderer.swapchain_texture != nil)

    depth_target_info := sdl.GPUDepthStencilTargetInfo {
        texture = renderer.shadow_map,
        clear_depth = 1,
        load_op = .CLEAR,
        store_op = .STORE,
        stencil_load_op = .CLEAR,
        stencil_store_op = .STORE,
        cycle = true,
        clear_stencil = 0,
    }


    using state.renderer
    light_view := create_view_matrix({0, WORLD_SIZE.y, 0}, renderer.light_orientation)
    light_viewproj := light_proj * light_view

    render_pass := sdl.BeginGPURenderPass(renderer.cmd_buff, nil, 0, &depth_target_info); assert(render_pass != nil)
    sdl.BindGPUGraphicsPipeline(render_pass, renderer.shadow_pipeline)
    for &model, model_index in models {
        bindings: [1]sdl.GPUBufferBinding = { sdl.GPUBufferBinding { buffer = model.vbo } } 
        sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)
        for &entity, i in entities {
            if entity.model.vbo != model.vbo || !(.SHADOW_CASTER in entity.flags) || 
            linalg.distance(entity.position, player.position) > renderer.draw_distance { continue }
            model_mat := linalg.matrix4_translate_f32(entity.position)
            position_offset := to_vec4(entity.position, 1)
            shadow_ubo := ShadowUBO {light_viewproj = light_viewproj, position_offset = position_offset}
            sdl.PushGPUVertexUniformData(renderer.cmd_buff, 0, &shadow_ubo, size_of(ShadowUBO))
            assert(entity.model.vbo != state.models[0].vbo)
            sdl.DrawGPUPrimitives(render_pass, model.num_vertices, 1, 0, 0)
        }
    }
    sdl.EndGPURenderPass(render_pass)
}

ShadowUBO :: struct {
    light_viewproj: matrix[4,4]f32,
    position_offset: vec4
}



create_view_matrix :: proc(position: vec3, rotation: vec3) -> linalg.Matrix4f32 {
    using linalg
    pitch_matrix := matrix4_rotate_f32(to_radians(rotation.x), {1, 0, 0})
    yaw_matrix := matrix4_rotate_f32(to_radians(rotation.y), {0, 1, 0})
    roll_matrix := matrix4_rotate_f32(to_radians(rotation.z), {0, 0, 1})
    camera_position := -position
    camera_position.y -= 2
    position_matrix := matrix4_translate_f32(camera_position)

    return pitch_matrix * yaw_matrix * roll_matrix * position_matrix
}

create_proj_matrix :: proc(renderer: Renderer) -> matrix[4,4]f32 {
    using linalg
    x, y: i32;
    ok := sdl.GetWindowSize(renderer.window, &x, &y)
    aspect := f32(x) / f32(y)
    return matrix4_perspective_f32(linalg.to_radians(f32(90)), aspect, 0.0001, renderer.draw_distance)
}

create_vertex_UBO :: proc(entity: Entity, view_matrix: matrix[4,4]f32) -> VertUniforms {
    using linalg
    model_translation_matrix := matrix4_translate_f32(entity.position)
    model_matrix: matrix[4, 4]f32 = view_matrix * model_translation_matrix
    return VertUniforms {
        modelview = model_matrix,
        model = model_translation_matrix,
        position_offset = to_vec4(entity.position, 1)
    }
}
build_shadow_pipeline :: proc(renderer: ^Renderer) {
    using renderer
    sdl.ReleaseGPUGraphicsPipeline(gpu, shadow_pipeline)
    vert_shader := load_shader(renderer.gpu, shadow_shader_code, .VERTEX, 1, 0, 0); defer sdl.ReleaseGPUShader(renderer.gpu, vert_shader)
    frag_shader := load_shader(renderer.gpu, bbox_frag_shader, .FRAGMENT, 0, 0, 0); defer sdl.ReleaseGPUShader(renderer.gpu, frag_shader)
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
        }
    }
    shadow_pipeline = sdl.CreateGPUGraphicsPipeline(gpu, {
        vertex_shader = vert_shader,
        fragment_shader = frag_shader,
        primitive_type = .TRIANGLELIST,
        vertex_input_state = {
            vertex_buffer_descriptions = &vb_descriptions[0],
            num_vertex_buffers = 1,
            vertex_attributes = &vb_attributes[0],
            num_vertex_attributes = 1
        },
        target_info = {
            has_depth_stencil_target = true,
            depth_stencil_format = .D32_FLOAT
        },
        rasterizer_state = {
            fill_mode = .FILL,
            cull_mode = .BACK,
            // enable_depth_bias = true,
            // depth_bias_constant_factor = 1.25,
            // depth_bias_slope_factor = 1,

        },
        depth_stencil_state = {
            enable_depth_test = true,
            enable_depth_write = true,
            compare_op = .LESS_OR_EQUAL,
        }
    })
}

@(private="file")
build_3D_pipeline :: proc(renderer: ^Renderer) {
    using renderer
    sdl.ReleaseGPUGraphicsPipeline(gpu, pipeline3D)
    vert_shader := load_shader(gpu, vert_shader_code, .VERTEX, 3, 0, 0); defer sdl.ReleaseGPUShader(renderer.gpu, vert_shader)
    frag_shader := load_shader(gpu, frag_shader_code, .FRAGMENT, 2, 5, 1); defer sdl.ReleaseGPUShader(renderer.gpu, frag_shader)

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
    if .WIREFRAME in renderer.props {fill_mode = .LINE; cull_mode = .NONE} else {fill_mode = .FILL; cull_mode = .BACK}

    format := sdl.GetGPUSwapchainTextureFormat(gpu, window)
    renderer.pipeline3D = sdl.CreateGPUGraphicsPipeline(gpu, {
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

RND_ToggleWireframe :: proc(renderer: ^Renderer) {
    build_3D_pipeline(renderer)
}