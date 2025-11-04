package obj_viewer

import "core:time"
import "core:math"
import "core:strings"
import sdl "vendor:sdl3"
import im "shared:imgui"
import im_sdl "shared:imgui/imgui_impl_sdl3"
import im_sdlgpu "shared:imgui/imgui_impl_sdlgpu3"

Vertex2D :: struct {
    position: vec2,
    uv:       vec2,
}

R2D :: struct {
    ui_pipeline: ^sdl.GPUGraphicsPipeline,
    quad: Quad,
}

Sprite :: struct {
    name: string,
    sampler: ^sdl.GPUSampler,
    texture: ^sdl.GPUTexture,
    size: [2]i32
}

Quad :: struct {
    vbo:     ^sdl.GPUBuffer,
    ibo:     ^sdl.GPUBuffer,
}

UBO2D :: struct {
    xywh:     vec4,
    win_size: vec2
}

load_sprite :: proc(path: string, renderer: Renderer) -> Sprite {
    using renderer
    copy_commands := sdl.AcquireGPUCommandBuffer(gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)
    defer {ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)}
    defer sdl.EndGPUCopyPass(copy_pass)
    
    pixels, size := load_pixels(path); assert(pixels != nil)
    size_u32: [2]u32 = {u32(size.x), u32(size.y)}
    texture := upload_texture(gpu, copy_pass, pixels, size_u32)
    assert(texture != nil)
    free_pixels(pixels)

    file_name  := strings.split(path, "/", context.temp_allocator)
    name_split := strings.split(file_name[len(file_name)-1], ".", context.temp_allocator)
    name       := strings.clone(name_split[0])

    sampler := sdl.CreateGPUSampler(gpu, {}); assert(sampler != nil)
    return Sprite {
        name,
        sampler,
        texture,
        size
    }
}

init_r2d :: proc(renderer: Renderer) {
    using renderer

    copy_commands := sdl.AcquireGPUCommandBuffer(gpu); assert(copy_commands != nil)
    defer {ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)}

    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)
    defer sdl.EndGPUCopyPass(copy_pass)

    {
        using renderer.r2d
        ui_pipeline = create_render_pipeline(
                renderer,
                "ui.vert",
                "ui.frag",
                Vertex2D,
                {.FLOAT2, .FLOAT2},
                false,
                num_vertex_buffers = 2,
                alpha_blend = true
        )
        quad = init_quad(gpu, copy_pass)
    }
}

init_quad :: proc(
    gpu:            ^sdl.GPUDevice,
    copy_pass:      ^sdl.GPUCopyPass
) -> Quad {
    verts := [4]Vertex2D {
        Vertex2D{{-1, -1}, {0, 0}}, // Bottom-left
        Vertex2D{{ 1, -1}, {1, 0}}, // Bottom-right
        Vertex2D{{ 1,  1}, {1, 1}}, // Top-right
        Vertex2D{{-1,  1}, {0, 1}}, // Top-left
    }
    indices := [6]u16{
        0, 2, 1, // First triangle
        2, 0, 3, // Second triangle
    }
    len_bytes := u32(len(verts) * size_of(Vertex2D))

    vbo, ibo := upload_polygon(gpu, copy_pass, verts[:], indices[:])
    return Quad {vbo, ibo}
}

begin_2d :: proc(renderer: Renderer, frame: ^Frame) {
    using renderer, frame
    assert(cmd_buff != nil)
    assert(swapchain != nil)
    assert(r2d.ui_pipeline != nil)


    color_target := sdl.GPUColorTargetInfo {
        texture = swapchain,
        load_op = .LOAD,
        store_op = .STORE,
    }
    render_pass = sdl.BeginGPURenderPass(cmd_buff, &color_target, 1, nil); assert(render_pass != nil)
    sdl.BindGPUGraphicsPipeline(render_pass, r2d.ui_pipeline)
    assert(r2d.quad.vbo != nil)
    bindings: [2]sdl.GPUBufferBinding = {
        sdl.GPUBufferBinding {buffer = r2d.quad.vbo},
        sdl.GPUBufferBinding {buffer = r2d.quad.ibo},
    }

    sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)
    sdl.BindGPUIndexBuffer(render_pass, bindings[1], ._16BIT)
}

draw_sprite :: proc(sprite: Sprite, frame: Frame, pos: vec2 = 0, scale: f32 = 1) {
    using frame
    if render_pass == nil do panic("Render pass not in progress")
    // Sprite will be centered if no position is provided
    x := pos == 0 ? win_size.x/2 - f32(sprite.size.x)/2 : pos.x
    y := pos == 0 ? win_size.y/2 - f32(sprite.size.y)/2 : pos.y

    ubo := UBO2D {
        {x, y, f32(sprite.size.x)*scale, f32(sprite.size.y)*scale},
        win_size
    }
    sdl.PushGPUVertexUniformData(cmd_buff, 0, &ubo, size_of(UBO2D))
    sdl.BindGPUFragmentSamplers(render_pass, 0, 
        &(sdl.GPUTextureSamplerBinding {
            texture = sprite.texture,
            sampler = sprite.sampler
        }), 1
    )
    sdl.DrawGPUIndexedPrimitives(render_pass, 6, 1, 0, 0, 0)
}

submit_2d :: proc(frame: ^Frame) {
    sdl.EndGPURenderPass(frame.render_pass)
    frame.render_pass = nil
}

draw_imgui :: proc(state: ^AppState, frame: Frame) {
    using state, frame
    im_sdlgpu.NewFrame()
    im_sdl.NewFrame()
    im.NewFrame()
    if props.ui_visible {
        if im.Begin("Properties") {
            if im.BeginTabBar("PropertiesTabs") {
                // --- General Tab ---
                if im.BeginTabItem("General") {
                    im.LabelText("", "General")
                    im.DragFloat3("Player position", &player.position, 0.25, 0, 60)
                    im.DragFloat("Draw distance", &renderer.draw_distance, 1, 10, 2000)
                    if height_map != nil do im.DragFloat3("Heightmap scale", &height_map.scale, 0.001, 0, 2)
                    im.EndTabItem()
                }

                // --- Point Light Tab ---
                if im.BeginTabItem("Point Light") {
                    im.LabelText("", "Point Light")
                    if !props.attatch_light_to_player {
                        im.DragFloat3("position", &renderer.light.position, 0.5, -200, 200)
                    }
                    im.Checkbox("Snap to player", &props.attatch_light_to_player)
                    im.DragFloat("intensity", &renderer.light.power, 10, 0, 10000)
                    im.ColorPicker3("color", &renderer.light.color, {.InputRGB})
                    im.EndTabItem()
                }

                // --- Directional Light Tab ---
                if im.BeginTabItem("Directional Light") {
                    im.LabelText("", "Directional Light")
                    im.DragFloat3("Direction", &renderer.dir_light.direction, 0.01, 0, 1)
                    im.ColorPicker3("color", &renderer.dir_light.color, {.InputRGB})
                    im.EndTabItem()
                }

                im.EndTabBar()
            }
            im.End()
        }
    }
    if im.Begin("info", nil, {.NoTitleBar, .NoMouseInputs}) {
        w, h: i32
        sdl.GetWindowSize(state.renderer.window, &w, &h)
        im.SetWindowPos(vec2{f32(w-120), 0})
        im.SetWindowSize(vec2{120, 0})
        frame_time_float := i32(math.round(1/f32(time.duration_seconds(debug_info.frame_time))))
        im.SetNextItemWidth(50)
        im.DragInt("FPS", &frame_time_float)
        rendered := i32(debug_info.objects_rendered)
        im.SetNextItemWidth(50)
        im.DragInt("Drawn", &rendered)
        im.SetNextItemWidth(50)
        im.LabelText("", "Player")
        im.DragFloat("Vel", &debug_info.player_speed)
        im.DragFloat("X", &player.position.x)
        im.DragFloat("Y", &player.position.y)
        im.DragFloat("Z", &player.position.z)
    }
    im.End()
    im.Render()
    im_draw_data := im.GetDrawData()
    im_sdlgpu.PrepareDrawData(im_draw_data, cmd_buff)
    im_color_target := sdl.GPUColorTargetInfo {
        texture = swapchain,
        load_op = .LOAD,
        store_op = .STORE
    }
    im_render_pass := sdl.BeginGPURenderPass(cmd_buff, &im_color_target, 1, nil); assert(im_render_pass != nil)
    im_sdlgpu.RenderDrawData(im_draw_data, cmd_buff, im_render_pass)
    sdl.EndGPURenderPass(im_render_pass)
}

upload_polygon :: proc(
    gpu:            ^sdl.GPUDevice,
    copy_pass:      ^sdl.GPUCopyPass,
    verts: []Vertex2D,
    indices: []u16
) -> (vbo, ibo: ^sdl.GPUBuffer){
    len_bytes := u32(len(verts) * size_of(Vertex2D))

    transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = len_bytes,
    }); assert(transfer_buffer != nil)


    vbo = create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.VERTEX}, verts[:]); assert(vbo != nil)
    ibo = create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.INDEX}, indices[:]); assert(ibo != nil)

    sdl.ReleaseGPUTransferBuffer(gpu, transfer_buffer)
    return
}