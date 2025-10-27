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
    window:             ^sdl.Window,
    gpu:                ^sdl.GPUDevice,
    obj_pipeline:       ^sdl.GPUGraphicsPipeline,
    bbox_pipeline:      ^sdl.GPUGraphicsPipeline,
    skybox_pipeline:    ^sdl.GPUGraphicsPipeline,
    heightmap_pipeline: ^sdl.GPUGraphicsPipeline,
    gltf_pipeline:      ^sdl.GPUGraphicsPipeline,
    depth_texture:      ^sdl.GPUTexture,
    fallback_texture:   ^sdl.GPUTexture,
    skybox_texture:     ^sdl.GPUTexture,
    samplers:           [4]^sdl.GPUSampler,
    default_sampler:    ^sdl.GPUSampler,
    props:              RND_Props,
    light:              PointLight,
    dir_light:          DirLight,
    draw_distance:      f32,
    r2d:                R2D,
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

VertUBO :: struct {
	vp: mat4,
	inv_view_mat: mat4,
	inv_projection_mat: mat4,
}

RND_Props :: distinct bit_set[RND_Prop; u8]

RND_Prop :: enum u8 {
    FULLSCREEN = 0,
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
    window  := sdl.CreateWindow("Demo window", w, h, window_flags)
    assert(ok); assert(window != nil)
    ok = sdl.HideCursor(); assert(ok)
    ok = sdl.SetWindowRelativeMouseMode(window, true); assert(ok)
    width, height: i32
    ok = sdl.GetWindowSize(window, &width, &height); assert(ok)
    gpu := sdl.CreateGPUDevice({.SPIRV}, DEBUG_GPU, nil); assert(gpu != nil)
    ok = sdl.ClaimWindowForGPUDevice(gpu, window); assert(ok)
    ok = sdl.SetGPUSwapchainParameters(gpu, window, .SDR_LINEAR, PRESENT_MODE); assert(ok)

    renderer.window = window
    renderer.gpu = gpu

    pixels, size := load_pixels("assets/err_tex.jpg")
    size_u32: [2]u32 = {u32(size.x), u32(size.y)}
    defer free_pixels(pixels)

    copy_commands := sdl.AcquireGPUCommandBuffer(gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)
    renderer.skybox_texture = load_cubemap_texture(gpu, copy_pass, {
        .POSITIVEX = "assets/skybox/right.png",
        .NEGATIVEX = "assets/skybox/left.png",
        .POSITIVEY = "assets/skybox/top.png",
        .NEGATIVEY = "assets/skybox/bottom.png",
        .POSITIVEZ = "assets/skybox/front.png",
        .NEGATIVEZ = "assets/skybox/back.png",
    })
    renderer.fallback_texture = upload_texture(gpu, copy_pass, pixels, size_u32)

    sdl.EndGPUCopyPass(copy_pass)
    ok = sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)

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

    swapchain_format := sdl.GetGPUSwapchainTextureFormat(gpu, window)
    renderer.obj_pipeline = create_render_pipeline(
        renderer,
        "shader.vert",
        "shader.frag",
        OBJVertex,
        {.FLOAT3, .FLOAT3, .FLOAT2, .UINT},
        true,
        swapchain_format
    )
    renderer.gltf_pipeline = create_render_pipeline(
        renderer,
        "pbr_metallic.vert",
        "pbr_metallic.frag",
        GLTFVertex,
        {.FLOAT3, .FLOAT3, .FLOAT2, .FLOAT3},
        true,
        swapchain_format
    )
    renderer.bbox_pipeline = create_render_pipeline(
        renderer,
        "bbox.vert",
        "bbox.frag",
        vec3,
        {.FLOAT3},
        true,
        swapchain_format,
        primitive_type = sdl.GPUPrimitiveType.LINELIST
    )
    renderer.heightmap_pipeline = create_render_pipeline(
        renderer,
        "heightmap.vert",
        "heightmap.frag",
        HeightMapVertex,
        {.FLOAT3, .FLOAT3},
        true,
        swapchain_format
    )
    renderer.skybox_pipeline = create_skybox_pipeline(renderer)
    renderer.default_sampler = sdl.CreateGPUSampler(gpu, {})
    assert(renderer.default_sampler != nil)

    for i in 0..<4 {
        sampler := sdl.CreateGPUSampler(gpu, {}); assert(sampler != nil)
        renderer.samplers[i] = sampler
    }
    renderer.light = PointLight {
        position = vec3{0, 10, 25},
        color = 1,
        power = 50
    }
    renderer.dir_light = DirLight {
        direction = 1,
        color     = 1
    }
    renderer.draw_distance = 2000
    init_r2d(renderer)
    return renderer
}

RND_Destroy :: proc(renderer: ^Renderer) {
    using renderer
    sdl.ReleaseGPUGraphicsPipeline(gpu, obj_pipeline)
    sdl.ReleaseGPUGraphicsPipeline(gpu, bbox_pipeline)
    sdl.ReleaseGPUGraphicsPipeline(gpu, r2d.ui_pipeline)
    sdl.ReleaseGPUTexture(gpu, depth_texture)
    sdl.ReleaseGPUTexture(gpu, fallback_texture)
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

Frame :: struct {
    cmd_buff:       ^sdl.GPUCommandBuffer,
    swapchain:      ^sdl.GPUTexture,
    render_pass:    ^sdl.GPURenderPass,
    win_size:       vec2,
    ubo_global:     VertUBO
}

frame_begin :: proc(renderer: Renderer, ubo: VertUBO) -> Frame {
    using renderer
    cmd_buff := sdl.AcquireGPUCommandBuffer(renderer.gpu); assert(cmd_buff != nil)
    swapchain: ^sdl.GPUTexture
    ok := sdl.WaitAndAcquireGPUSwapchainTexture(cmd_buff, renderer.window, &swapchain, nil, nil)
    win_size := get_window_size(renderer)
    assert(ok)
    assert(cmd_buff  != nil)
    assert(swapchain != nil)
    return Frame {
        cmd_buff,
        swapchain,
        nil,
        win_size,
        ubo
    }
}

get_vertex_ubo_global :: proc(state: AppState) -> VertUBO {
    using state
    proj_matrix := create_proj_matrix(renderer)
    view_matrix := create_view_matrix(player)
    return VertUBO {
        vp = proj_matrix * view_matrix,
        inv_view_mat = linalg.inverse(view_matrix),
        inv_projection_mat = linalg.inverse(proj_matrix)
    }
}

frame_submit :: proc(renderer: Renderer, frame: Frame) -> bool {
    ok := sdl.SubmitGPUCommandBuffer(frame.cmd_buff)
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

render_3D :: proc(state: ^AppState, frame: ^Frame) {
    using state, frame
    defer {
        sdl.EndGPURenderPass(render_pass)
        frame.render_pass = nil
    }
    assert(cmd_buff  != nil)
    assert(swapchain != nil)
    assert(render_pass == nil)

    color_target := sdl.GPUColorTargetInfo {
        texture = swapchain,
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
    frag_ubo := create_frag_ubo(state);
    frustum_planes := create_frustum_planes(frame.ubo_global.vp)

    render_pass = sdl.BeginGPURenderPass(cmd_buff, &color_target, 1, &depth_target_info); assert(render_pass != nil)
    sdl.PushGPUVertexUniformData(cmd_buff, 0, &frame.ubo_global, size_of(VertUBO))

    if height_map != nil {
        assert(renderer.heightmap_pipeline != nil)
        sdl.BindGPUGraphicsPipeline(render_pass, renderer.heightmap_pipeline)
        render_heightmap(height_map^, frame^)
    }

    sdl.BindGPUGraphicsPipeline(render_pass, renderer.obj_pipeline)
    sdl.PushGPUFragmentUniformData(cmd_buff, 0, &frag_ubo, size_of(FragUBO))
    for &model, model_index in models {
        using model
        bindings: [1]sdl.GPUBufferBinding = { sdl.GPUBufferBinding { buffer = vbo } } 
        sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)
        texture_count := len(textures)
        for tex, i in textures {
            sdl.BindGPUFragmentSamplers(render_pass, u32(i), 
                &(sdl.GPUTextureSamplerBinding{
                    texture = tex, 
                    sampler = renderer.samplers[i]
                }),
                u32(texture_count)
            )
        }
        for i in texture_count..<4 {
            if texture_count == 1 do texture_count = 2
            sdl.BindGPUFragmentSamplers(render_pass, u32(i), 
                &(sdl.GPUTextureSamplerBinding{
                    texture = renderer.fallback_texture, 
                    sampler = renderer.samplers[i]
                }), 
                u32(texture_count)
            )
        }
        sdl.BindGPUFragmentSamplers(render_pass, 4, &(sdl.GPUTextureSamplerBinding  {
            texture = renderer.skybox_texture,
            sampler = renderer.default_sampler
        }), u32(texture_count))

        sdl.BindGPUFragmentStorageBuffers(render_pass, 0, &material_buffer, 1)
        for &entity, i in entities {
            if entity.model != &model do continue
            if linalg.distance(player.position, entity.transform.translation) > renderer.draw_distance - 1 &&
                model_index != 0 { continue }
            if !aabb_intersects_frustum(frustum_planes, entity_aabb(entity)) do continue
            debug_info.objects_rendered += 1
            model_matrix := linalg.matrix4_translate_f32(entity.transform.translation) *
                linalg.matrix4_from_quaternion(entity.transform.rotation)
            sdl.PushGPUVertexUniformData(cmd_buff, 1, &model_matrix, size_of(matrix[4,4]f32))
            sdl.DrawGPUPrimitives(render_pass, num_vertices, 1, 0, 0)
        }
    }
    // Skybox
    {
        sdl.BindGPUGraphicsPipeline(render_pass, renderer.skybox_pipeline)
        sdl.BindGPUFragmentSamplers(render_pass, 0, &(sdl.GPUTextureSamplerBinding  {
            texture = renderer.skybox_texture,
            sampler = renderer.default_sampler
        }), 1)
        sdl.DrawGPUPrimitives(render_pass, 3, 1, 0, 0)
    }
    // Bounding Box
    if DEBUG_GPU {
        sdl.BindGPUGraphicsPipeline(render_pass, renderer.bbox_pipeline)
        for &model in models {
            using model
            bindings: [1]sdl.GPUBufferBinding = { sdl.GPUBufferBinding { buffer = bbox_vbo } } 
            sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)
            for entity in entities {
                if entity.model != &model do continue
                model_matrix := linalg.matrix4_translate_f32(entity.transform.translation)
                sdl.PushGPUVertexUniformData(cmd_buff, 1, &model_matrix, size_of(matrix[4,4]f32))
                sdl.DrawGPUPrimitives(render_pass, 24, 1, 0, 0)
            }
        }
    }

}

render_gltf_scene :: proc(renderer: ^Renderer, scene: GLTFScene, frame: ^Frame) {
    defer {
        sdl.EndGPURenderPass(frame.render_pass)
        frame.render_pass = nil
    }
    assert(frame.cmd_buff != nil)
    assert(frame.swapchain != nil)
    assert(frame.render_pass == nil)
    color_target := sdl.GPUColorTargetInfo {
        texture = frame.swapchain,
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

    furstum_planes := create_frustum_planes(frame.ubo_global.vp)
    frame.render_pass = sdl.BeginGPURenderPass(frame.cmd_buff, &color_target, 1, &depth_target_info)
    assert(frame.render_pass != nil)
    sdl.BindGPUGraphicsPipeline(frame.render_pass, renderer.gltf_pipeline)
    sdl.PushGPUVertexUniformData(frame.cmd_buff, 0, &frame.ubo_global, size_of(VertUBO))
    sdl.PushGPUFragmentUniformData(frame.cmd_buff, 0, &renderer.dir_light, size_of(DirLight))
    for node in scene.root_nodes {
        draw_gltf_node(
            renderer^, 
            frame,
            node, 
            linalg.matrix4_translate(node.transform.translation), 
            furstum_planes,
        )
    }

    if !DEBUG_GPU do return
    sdl.BindGPUGraphicsPipeline(frame.render_pass, renderer.bbox_pipeline)
    for node in scene.root_nodes {
        draw_gltf_aabb(
            renderer^, 
            frame^,
            node, 
            linalg.matrix4_translate(node.transform.translation),
        )
    }
}

draw_gltf_aabb :: proc(
    renderer: Renderer, 
    frame: Frame,
    node: GLTFNode,
    parent_matrix: matrix[4,4]f32,
){
    using node, frame
    model_matrix := parent_matrix

    if bbox_vbo != nil {
        bindings: [1]sdl.GPUBufferBinding = { 
            sdl.GPUBufferBinding { buffer = bbox_vbo },
        } 
        sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)
        sdl.PushGPUVertexUniformData(cmd_buff, 1, &model_matrix, size_of(matrix[4,4]f32))
        sdl.DrawGPUPrimitives(render_pass, 24, 1, 0, 0)
    }

    for &child in node.children {
        draw_gltf_aabb(renderer, frame, child, model_matrix)
    }
}
GLTF_FragUBO :: struct {
    base_color_factor:      vec4,
    metallic_factor:        f32,
    roughness_factor:       f32,
    has_base_col_tex:       b32,
    has_metal_rough_tex:    b32,
    has_normal_tex:         b32,
    has_occlusion_tex:      b32,
    _pad:                   [2]uint
}

DirLight :: struct {
    direction: vec3,
    _pad:      f32,
    color:     vec3,
    _pad2:     f32
}
import "core:fmt"
draw_gltf_node :: proc(
    renderer: Renderer, 
    frame: ^Frame,
    node: GLTFNode,
    parent_matrix: matrix[4,4]f32,
    frustum_planes: [6]vec4,
){
    using node

    offset: vec3
    model_matrix := parent_matrix * create_model_matrix(node.transform)

    visible := true
    if node.mesh != nil {
        aabb_transformed := AABB {min = node.aabb.min, max = node.aabb.max}
        visible = aabb_intersects_frustum(frustum_planes, aabb_transformed)
    }
    if mesh != nil && visible {
        bindings: [2]sdl.GPUBufferBinding = { 
            sdl.GPUBufferBinding { buffer = mesh.vbo },
            sdl.GPUBufferBinding { buffer = mesh.ibo }
        } 
        sdl.BindGPUVertexBuffers(frame.render_pass, 0, &bindings[0], 1)
        sdl.BindGPUIndexBuffer(frame.render_pass, bindings[1], ._16BIT)
        sdl.PushGPUVertexUniformData(frame.cmd_buff, 1, &model_matrix, size_of(matrix[4,4]f32))
        using mesh
        for primitive in data.primitives {
            frag_ubo: GLTF_FragUBO
            frag_ubo.base_color_factor = primitive.material.pbr_metallic_roughness.base_color_factor
            frag_ubo.metallic_factor = primitive.material.pbr_metallic_roughness.metallic_factor
            frag_ubo.roughness_factor = primitive.material.pbr_metallic_roughness.roughness_factor

            frag_ubo.has_base_col_tex = primitive.material.pbr_metallic_roughness.base_color_texture != {}
            frag_ubo.has_metal_rough_tex = primitive.material.pbr_metallic_roughness.metallic_roughness_texture != {}
            frag_ubo.has_normal_tex = primitive.material.normal_texture != {}
            frag_ubo.has_occlusion_tex = primitive.material.occlusion_texture != {}

            fallback_binding := sdl.GPUTextureSamplerBinding {
                texture = renderer.fallback_texture,
                sampler = renderer.default_sampler
            }

            tex_bindings: [3]sdl.GPUTextureSamplerBinding

            tex_bindings[0] = frag_ubo.has_base_col_tex? sdl.GPUTextureSamplerBinding {
                texture = primitive.material.pbr_metallic_roughness.base_color_texture.texture,
                sampler = primitive.material.pbr_metallic_roughness.base_color_texture.sampler
                // sampler = renderer.default_sampler
            } : fallback_binding

            tex_bindings[1] = frag_ubo.has_base_col_tex? sdl.GPUTextureSamplerBinding {
                texture = primitive.material.pbr_metallic_roughness.metallic_roughness_texture.texture,
                sampler = primitive.material.pbr_metallic_roughness.metallic_roughness_texture.sampler
                // sampler = renderer.default_sampler
            } : fallback_binding

            tex_bindings[2] = frag_ubo.has_normal_tex? sdl.GPUTextureSamplerBinding {
                texture = primitive.material.normal_texture.texture,
                sampler = primitive.material.normal_texture.sampler
                // sampler = renderer.default_sampler
            } : fallback_binding
            // tex_bindings[3] = frag_ubo.has_occlusion_tex? sdl.GPUTextureSamplerBinding {
            //     texture = primitive.material.occlusion_texture.texture,
            //     sampler = primitive.material.occlusion_texture.sampler
            //     // sampler = renderer.default_sampler
            // } : fallback_binding

            sdl.BindGPUFragmentSamplers(frame.render_pass, 0, raw_data(tex_bindings[:]), len(tex_bindings))
            sdl.PushGPUFragmentUniformData(frame.cmd_buff, 1, &frag_ubo, size_of(GLTF_FragUBO))
            num_indices := u32(primitive.end - primitive.start)
            sdl.DrawGPUIndexedPrimitives(frame.render_pass, num_indices, 1, u32(primitive.start), 0, 0)
        }
    }

    for &child in node.children {
        draw_gltf_node(renderer, frame, child, model_matrix, frustum_planes)
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

    transfer_mem := cast([^]byte) sdl.MapGPUTransferBuffer(gpu, transfer_buffer, true)
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

upload_texture :: proc(
    gpu: ^sdl.GPUDevice,
    copy_pass: ^sdl.GPUCopyPass, 
    pixels: []byte, 
    size: [2]u32
) -> ^sdl.GPUTexture {

    texture := sdl.CreateGPUTexture(gpu, {
        type = .D2,
        format = .R8G8B8A8_UNORM_SRGB,
        usage = {.SAMPLER},
        width = u32(size.x),
        height = u32(size.y),
        layer_count_or_depth = 1,
        num_levels = 1
    })

    tex_transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
        usage = .UPLOAD,
        size = u32(len(pixels)),
    }); assert(tex_transfer_buffer != nil)

    tex_transfer_mem := sdl.MapGPUTransferBuffer(gpu, tex_transfer_buffer, false)
    mem.copy(tex_transfer_mem, raw_data(pixels), len(pixels))
    sdl.UnmapGPUTransferBuffer(gpu, tex_transfer_buffer)
    sdl.UploadToGPUTexture(copy_pass, 
        {transfer_buffer = tex_transfer_buffer},
        {texture = texture, w = u32(size.x), h = u32(size.y), d = 1},
        false
    )

    sdl.ReleaseGPUTransferBuffer(gpu, tex_transfer_buffer)
    return texture
}

upload_cubemap_texture_sides :: proc(
    gpu: ^sdl.GPUDevice,
    copy_pass: ^sdl.GPUCopyPass,
    pixels: [sdl.GPUCubeMapFace][]byte,
    size: u32
) -> ^sdl.GPUTexture {
	texture := sdl.CreateGPUTexture(gpu, {
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

	tex_transfer_buf := sdl.CreateGPUTransferBuffer(gpu, {
		usage = .UPLOAD,
		size = u32(side_byte_size * 6)
	})
	tex_transfer_mem := cast([^]byte)sdl.MapGPUTransferBuffer(gpu, tex_transfer_buf, false)

	offset := 0
	for side_pixels in pixels {
		mem.copy(tex_transfer_mem[offset:], raw_data(side_pixels), side_byte_size)
		offset += side_byte_size
	}

	sdl.UnmapGPUTransferBuffer(gpu, tex_transfer_buf)

	offset = 0
	for side in 0..<len(pixels) {
		sdl.UploadToGPUTexture(copy_pass,
			{transfer_buffer = tex_transfer_buf, offset = u32(offset)},
			{texture = texture, layer = u32(side), w = size, h = size, d = 1},
			false
		)
		offset += side_byte_size
	}

	sdl.ReleaseGPUTransferBuffer(gpu, tex_transfer_buf)
	return texture
}

load_shader :: proc(device: ^sdl.GPUDevice, shaderfile: string) -> ^sdl.GPUShader {
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

create_skybox_pipeline :: proc(renderer: Renderer) -> ^sdl.GPUGraphicsPipeline {
    using renderer
    vert_shader := load_shader(gpu, "skybox.vert"); defer sdl.ReleaseGPUShader(renderer.gpu, vert_shader)
    frag_shader := load_shader(gpu, "skybox.frag"); defer sdl.ReleaseGPUShader(renderer.gpu, frag_shader)
    format := sdl.GetGPUSwapchainTextureFormat(gpu, window)
    pipeline := sdl.CreateGPUGraphicsPipeline(gpu, {
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

create_render_pipeline :: proc(
    renderer: Renderer,
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
    using renderer
    vert_shader := load_shader(gpu, vert_shader); defer sdl.ReleaseGPUShader(gpu, vert_shader)
    frag_shader := load_shader(gpu, frag_shader); defer sdl.ReleaseGPUShader(gpu, frag_shader)

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
        swapchain_format = sdl.GetGPUSwapchainTextureFormat(gpu, window)
    }
    pipeline := sdl.CreateGPUGraphicsPipeline(gpu, {
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