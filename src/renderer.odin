package obj_viewer

import "core:mem"
import "core:math"
import "core:math/linalg"
import "core:log"
import "core:strings"
import "core:c"
import "core:time"
import "core:os"
import "core:path/filepath"
import "core:encoding/json"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"

Renderer :: struct {
    window:             ^sdl.Window,
    gpu:                ^sdl.GPUDevice,
    obj_pipeline:       ^sdl.GPUGraphicsPipeline,
    gltf_pipeline:      ^sdl.GPUGraphicsPipeline,
    bbox_pipeline:      ^sdl.GPUGraphicsPipeline,
    ui_pipeline:        ^sdl.GPUGraphicsPipeline,
    depth_texture:      ^sdl.GPUTexture,
    fallback_texture:   ^sdl.GPUTexture,
    swapchain_texture:  ^sdl.GPUTexture,
    cmd_buff:           ^sdl.GPUCommandBuffer,
    samplers:           [4]^sdl.GPUSampler,
    view_projection:    matrix[4,4]f32,
    props:              RND_Props,
    light:              PointLight,
    draw_distance:      f32,
    ui:                 UI,
}

PointLight :: struct #packed {
    position: vec3,
    power:    f32,
    color:    vec3,
}

FragUBO :: struct #packed {
    light_pos: vec3,
    _: f32,
    light_color: vec3,
    light_intensity: f32,
    view_pos: vec3

}

RND_Props :: distinct bit_set[RND_Prop; u8]

RND_Prop :: enum u8 {
    FULLSCREEN = 0,
    WIREFRAME = 1,
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
    gpu := sdl.CreateGPUDevice({.SPIRV}, DEBUG_GPU, nil); assert(gpu != nil)
    ok = sdl.ClaimWindowForGPUDevice(gpu, window); assert(ok)
    ok = sdl.SetGPUSwapchainParameters(gpu, window, .SDR_LINEAR, PRESENT_MODE); assert(ok)

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
    build_obj_pipeline(&renderer)
    build_gltf_pipeline(&renderer)
    build_bbox_pipeline(&renderer)
    build_ui_pipeline(&renderer)
    for i in 0..<4 {
        sampler := sdl.CreateGPUSampler(gpu, {}); assert(sampler != nil)
        renderer.samplers[i] = sampler
    }
    renderer.light = PointLight {
        position = vec3{0, 10, 25},
        color = 1,
        power = 50
    }
    renderer.draw_distance = 250
    return renderer
}

RND_Destroy :: proc(renderer: ^Renderer) {
    using renderer
    sdl.ReleaseGPUGraphicsPipeline(gpu, obj_pipeline)
    sdl.ReleaseGPUGraphicsPipeline(gpu, gltf_pipeline)
    sdl.ReleaseGPUGraphicsPipeline(gpu, bbox_pipeline)
    sdl.ReleaseGPUGraphicsPipeline(gpu, ui_pipeline)
    sdl.ReleaseGPUTexture(gpu, depth_texture)
    sdl.ReleaseGPUTexture(gpu, fallback_texture)
    sdl.ReleaseGPUTexture(gpu, swapchain_texture)
    for sampler in samplers {
        sdl.ReleaseGPUSampler(gpu, sampler)
    }
    sdl.ReleaseWindowFromGPUDevice(gpu, window)
    sdl.DestroyWindow(window)
}

RND_ToggleFullscreen :: proc(state: ^AppState) {
    using state.renderer
    if .FULLSCREEN in props do props -= {.FULLSCREEN}
    else do props += {.FULLSCREEN}
    ok: bool
    window_bounds: sdl.Rect
    if !sdl.GetDisplayBounds(1, &window_bounds) {
        log.log(.Error, sdl.GetError())
    }
    sdl.ReleaseWindowFromGPUDevice(gpu, window)
    sdl.DestroyWindow(window)
    width, height: i32
    if .FULLSCREEN in props {
        width = window_bounds.w
        height = window_bounds.h
        new_window := sdl.CreateWindow("Demo window", width, height, {.FULLSCREEN}); assert(new_window != nil)
        window = new_window
        ok = sdl.ClaimWindowForGPUDevice(gpu, window)
        if !ok do log.log(.Error, sdl.GetError())
    } else {
        width = 1280
        height = 720
        new_window := sdl.CreateWindow("Demo window", width, height, {}); assert(window != nil)
        window = new_window
        ok = sdl.ClaimWindowForGPUDevice(gpu, window)
    }

    ok = sdl.SetGPUSwapchainParameters(gpu, window, .SDR_LINEAR, PRESENT_MODE); assert(ok)
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
    if state.props.ui_visible {
        ok = sdl.ShowCursor(); assert(ok)
        ok = sdl.SetWindowRelativeMouseMode(window, false); assert(ok)
    } else {
        ok = sdl.SetWindowRelativeMouseMode(window, true)
        ok = sdl.HideCursor(); assert(ok)
    }
    assert(ok)
    init_imgui(state)
}



RND_FrameBegin :: proc(state: ^AppState) {
    using state
    assert(renderer.cmd_buff == nil)
    assert(renderer.swapchain_texture == nil)
    cmd_buff := sdl.AcquireGPUCommandBuffer(renderer.gpu); assert(cmd_buff != nil)
    renderer.cmd_buff = cmd_buff
    debug_info.rendered = 0
    ok := sdl.WaitAndAcquireGPUSwapchainTexture(cmd_buff, renderer.window, &renderer.swapchain_texture, nil, nil)
    assert(ok)
}

update_vp :: proc(state: ^AppState) {
    using state
    proj_matrix := create_proj_matrix(renderer)
    view_matrix := create_view_matrix(player)
    state.renderer.view_projection = proj_matrix * view_matrix;
}

RND_FrameSubmit :: proc(renderer: ^Renderer) -> bool {
    ok := sdl.SubmitGPUCommandBuffer(renderer.cmd_buff)
    renderer.cmd_buff = nil
    renderer.swapchain_texture = nil
    return ok
}

create_frag_ubo :: proc(state: ^AppState) -> FragUBO {
    using state
    return FragUBO {
        light_pos = renderer.light.position,
        light_color = renderer.light.color,
        light_intensity = renderer.light.power,
        view_pos = get_camera_position(player)
    }
}


create_model_matrix :: proc(transform: Transform, position_offset: vec3 = 0) -> matrix[4,4]f32 {
    model_transform := transform
    if model_transform.scale == 0 do model_transform.scale = 1
    model_transform.translation += position_offset
    return linalg.matrix4_translate_f32(model_transform.translation) *
    linalg.matrix4_from_quaternion_f32(model_transform.rotation) *
    linalg.matrix4_scale(model_transform.scale)
}

RND_DrawGLTF :: proc(state: ^AppState) {
    using state
    vp := renderer.view_projection
    assert(renderer.cmd_buff != nil)
    assert(renderer.swapchain_texture != nil)
    color_target := sdl.GPUColorTargetInfo {
        texture = renderer.swapchain_texture,
        load_op = .LOAD,
        store_op = .STORE,
        clear_color = 0,
    }
    depth_target_info := sdl.GPUDepthStencilTargetInfo {
        texture = renderer.depth_texture,
        clear_depth = 1,
        load_op = .LOAD,
        store_op = .STORE,
        stencil_load_op = .LOAD,
        stencil_store_op = .STORE,
        cycle = false,
        clear_stencil = 1,
    }

    furstum_planes := create_furstum_planes(vp)
    render_pass := sdl.BeginGPURenderPass(renderer.cmd_buff, &color_target, 1, &depth_target_info)
    assert(render_pass != nil)
    frag_ubo := create_frag_ubo(state)
    sdl.BindGPUGraphicsPipeline(render_pass, renderer.gltf_pipeline)
    sdl.PushGPUVertexUniformData(renderer.cmd_buff, 0, &vp, size_of(matrix[4,4]f32))
    sdl.PushGPUFragmentUniformData(renderer.cmd_buff, 0, &frag_ubo, size_of(FragUBO))
    for entity, i in entities {
        if entity.model.format != .GLTF do continue
        draw_gltf_node(
            render_pass, 
            state, 
            entity.model.data.gltf, 
            linalg.matrix4_translate(entity.transform.translation), 
            entity.transform.translation, 
            furstum_planes
        )
    }
    sdl.EndGPURenderPass(render_pass)

    // Renders AABBs as 
    if !DEBUG_GPU do return
    bbox_pass := sdl.BeginGPURenderPass(renderer.cmd_buff, &color_target, 1, nil)
    sdl.BindGPUGraphicsPipeline(render_pass, renderer.bbox_pipeline)
    sdl.PushGPUVertexUniformData(renderer.cmd_buff, 0, &vp, size_of(matrix[4,4]f32))
    for entity, i in state.entities {
        if entity.model.format != .GLTF do continue
        draw_gltf_aabb(
            render_pass, 
            state, 
            entity.model.data.gltf, 
            linalg.matrix4_translate(entity.transform.translation), 
        )
    }
    sdl.EndGPURenderPass(bbox_pass)
}

draw_gltf_aabb :: proc(
    render_pass: ^sdl.GPURenderPass,
    state: ^AppState, 
    node: GLTFNode,
    parent_matrix: matrix[4,4]f32,
){
    using node, state
    model_matrix := parent_matrix

    if bbox_vbo != nil {
        bindings: [1]sdl.GPUBufferBinding = { 
            sdl.GPUBufferBinding { buffer = bbox_vbo },
        } 
        sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)
        sdl.PushGPUVertexUniformData(renderer.cmd_buff, 1, &model_matrix, size_of(matrix[4,4]f32))
        sdl.DrawGPUPrimitives(render_pass, 24, 1, 0, 0)
    }

    for &child in node.children {
        draw_gltf_aabb(render_pass, state, child, model_matrix)
    }
}

draw_gltf_node :: proc(
    render_pass: ^sdl.GPURenderPass,
    state: ^AppState, 
    node: GLTFNode,
    parent_matrix: matrix[4,4]f32,
    entity_pos: vec3,
    frustum_planes: [6]vec4,
){
    using node, state

    offset: vec3
    model_matrix := parent_matrix * create_model_matrix(node.transform)

    visible := true
    if node.mesh != nil {
        aabb_transformed := AABB {min = node.aabb.min + entity_pos, max = node.aabb.max + entity_pos}
        visible = aabb_intersects_frustum(frustum_planes, aabb_transformed)
    }
    if mesh != nil && visible {
        bindings: [2]sdl.GPUBufferBinding = { 
            sdl.GPUBufferBinding { buffer = mesh.vbo },
            sdl.GPUBufferBinding { buffer = mesh.ibo }
        } 
        sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)
        sdl.BindGPUIndexBuffer(render_pass, bindings[1], ._16BIT)
        sdl.PushGPUVertexUniformData(renderer.cmd_buff, 1, &model_matrix, size_of(matrix[4,4]f32))
        using mesh
        for primitive in data.primitives {
            frag_ubo: GLTF_fragUBO
            frag_ubo.base_color = primitive.material.base_color_factor
            frag_ubo.metallic_factor = primitive.material.metallic_factor
            frag_ubo.roughness_factor = primitive.material.roughness_factor
            tex_bindings: [3]sdl.GPUTextureSamplerBinding
            if primitive.material.base_color_texture.texture != nil {
                tex_bindings[0] = sdl.GPUTextureSamplerBinding {
                    texture = primitive.material.base_color_texture.texture,
                    sampler = primitive.material.base_color_texture.sampler
                }
                frag_ubo.has_albedo_tex = true
            } else {
                tex_bindings[0] = sdl.GPUTextureSamplerBinding {
                    texture = renderer.fallback_texture,
                    sampler = renderer.samplers[0]
                }
            }
            if primitive.material.metallic_roughness_texture.texture != nil {
                tex_bindings[1] = (sdl.GPUTextureSamplerBinding {
                    texture = primitive.material.metallic_roughness_texture.texture,
                    sampler = primitive.material.metallic_roughness_texture.sampler
                })
                frag_ubo.has_metallic_roughness_tex = true
            } else {
                tex_bindings[1] = sdl.GPUTextureSamplerBinding {
                    texture = renderer.fallback_texture,
                    sampler = renderer.samplers[1]
                }
            }
            if primitive.material.normal_map.texture != nil {
                tex_bindings[2] = (sdl.GPUTextureSamplerBinding {
                    texture = primitive.material.normal_map.texture,
                    sampler = primitive.material.normal_map.sampler
                })
                frag_ubo.has_normal_map = true
            } else {
                tex_bindings[2] = sdl.GPUTextureSamplerBinding {
                    texture = renderer.fallback_texture,
                    sampler = renderer.samplers[2]
                }
            }
            sdl.BindGPUFragmentSamplers(render_pass, 0, raw_data(tex_bindings[:]), 3)
            sdl.PushGPUFragmentUniformData(renderer.cmd_buff, 1, &frag_ubo, size_of(GLTF_fragUBO))
            num_indices := u32(primitive.end - primitive.start)
            sdl.DrawGPUIndexedPrimitives(render_pass, num_indices, 1, u32(primitive.start), 0, 0)
            debug_info.rendered += 1
        }
    }

    for &child in node.children {
        draw_gltf_node(render_pass, state, child, model_matrix, entity_pos, frustum_planes)
    }
}
GLTF_fragUBO :: struct {
    base_color: vec4,
    has_albedo_tex: bool,
    has_metallic_roughness_tex: bool,
    has_normal_map: bool,
    _pad: bool,
    roughness_factor: f32,
    metallic_factor: f32,
    _pad2: f32
}

render_obj :: proc(state: ^AppState) {
    using state
    vp := renderer.view_projection
    assert(renderer.cmd_buff != nil)
    assert(renderer.swapchain_texture != nil)

    color_target := sdl.GPUColorTargetInfo {
        texture = renderer.swapchain_texture,
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

    frustum_planes := create_furstum_planes(vp)

    frag_ubo := create_frag_ubo(state);
    render_pass := sdl.BeginGPURenderPass(renderer.cmd_buff, &color_target, 1, &depth_target_info); assert(render_pass != nil)
    sdl.BindGPUGraphicsPipeline(render_pass, renderer.obj_pipeline)
    sdl.PushGPUFragmentUniformData(renderer.cmd_buff, 0, &frag_ubo, size_of(FragUBO))
    sdl.PushGPUVertexUniformData(renderer.cmd_buff, 0, &vp, size_of(matrix[4,4]f32))
    for &model, model_index in models {
        if model.format == .GLTF do continue
        using model.data.obj
        bindings: [1]sdl.GPUBufferBinding = { sdl.GPUBufferBinding { buffer = vbo } } 
        sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)
        texture_count := len(textures)
        for tex, i in textures {
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

        sdl.BindGPUFragmentStorageBuffers(render_pass, 0, &material_buffer, 1)
        for &entity, i in entities {
            if entity.model.format == .GLTF do continue
            if entity.model != &model do continue
            if linalg.distance(player.position, entity.transform.translation) > renderer.draw_distance - 1 &&
                model_index != 0 { continue }
            if !aabb_intersects_frustum(frustum_planes, entity_aabb(entity)) do continue
            debug_info.rendered += 1
            model_matrix := linalg.matrix4_translate_f32(entity.transform.translation)
            sdl.PushGPUVertexUniformData(renderer.cmd_buff, 1, &model_matrix, size_of(matrix[4,4]f32))
            sdl.DrawGPUPrimitives(render_pass, num_vertices, 1, 0, 0)
        }
    }
    sdl.EndGPURenderPass(render_pass)
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



create_proj_matrix :: proc(renderer: Renderer) -> matrix[4,4]f32 {
    using linalg
    win_size := get_window_size(renderer)
    aspect := win_size.x / win_size.y
    return matrix4_perspective_f32(
        89.75, 
        aspect, 
        0.01, 
        renderer.draw_distance
    )
}

get_window_size :: proc(renderer: Renderer) -> vec2 {
    x, y: i32
    ok := sdl.GetWindowSize(renderer.window, &x, &y)
    if ok do return {f32(x), f32(y)}
    sdl.ClearError()
    log.logf(.Error, "SDL Error: {}", sdl.GetError())
    panic("")
}

build_bbox_pipeline :: proc(renderer: ^Renderer) {
    sdl.ReleaseGPUGraphicsPipeline(renderer.gpu, renderer.bbox_pipeline)
    vert_shader := load_shader(renderer.gpu, "bbox.vert"); defer sdl.ReleaseGPUShader(renderer.gpu, vert_shader)
    frag_shader := load_shader(renderer.gpu, "bbox.frag"); defer sdl.ReleaseGPUShader(renderer.gpu, frag_shader)

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


build_obj_pipeline :: proc(renderer: ^Renderer) {
    using renderer
    sdl.ReleaseGPUGraphicsPipeline(gpu, obj_pipeline)
    vert_shader := load_shader(gpu, "shader.vert"); defer sdl.ReleaseGPUShader(renderer.gpu, vert_shader)
    frag_shader := load_shader(gpu, "shader.frag"); defer sdl.ReleaseGPUShader(renderer.gpu, frag_shader)

    vb_descriptions: [1]sdl.GPUVertexBufferDescription
    vb_descriptions = {
        sdl.GPUVertexBufferDescription {
            slot = u32(0),
            pitch = size_of(OBJVertex),
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
    renderer.obj_pipeline = sdl.CreateGPUGraphicsPipeline(gpu, {
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

load_shader :: proc(device: ^sdl.GPUDevice, shaderfile: string) -> ^sdl.GPUShader {
    stage: sdl.GPUShaderStage
    switch filepath.ext(shaderfile) {
        case ".vert":
            stage = .VERTEX
        case ".frag":
            stage = .FRAGMENT
    }

    shaderfile := filepath.join({"shaders", "out", shaderfile})
    filename := strings.concatenate({shaderfile, ".spv"}, context.temp_allocator)
    code, ok := os.read_entire_file_from_filename(filename, context.temp_allocator); assert(ok)
    info := load_shader_info(shaderfile)
    return sdl.CreateGPUShader(device, {
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