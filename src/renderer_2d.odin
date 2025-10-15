package obj_viewer

import "core:time"
import "core:math"
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
    sprites: [dynamic]Sprite,
}

Sprite :: struct {
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

load_sprite :: proc(path: string, renderer: ^Renderer) -> Sprite {
    using renderer
    copy_commands := sdl.AcquireGPUCommandBuffer(gpu); assert(copy_commands != nil)
    defer {ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)}
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)
    defer sdl.EndGPUCopyPass(copy_pass)
    
    pixels, size := load_pixels(path)
    texture := upload_texture(gpu, copy_pass, pixels, transmute([2]u32)size)

    sampler := sdl.CreateGPUSampler(gpu, {}); assert(sampler != nil)
    return Sprite {
        sampler,
        texture,
        size
    }
}

init_r2d :: proc(renderer: ^Renderer) {
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
        0, 1, 2, // First triangle
        2, 3, 0, // Second triangle
    }
    len_bytes := u32(len(verts) * size_of(Vertex2D))

    vbo, ibo := upload_polygon(gpu, copy_pass, verts[:], indices[:])
    return Quad {vbo, ibo}
}

draw_2d :: proc(state: ^AppState) {
    using state.renderer
    assert(cmd_buff != nil)
    assert(swapchain_texture != nil)
    assert(r2d.ui_pipeline != nil)

    win_size := get_window_size(state.renderer)


    color_target := sdl.GPUColorTargetInfo {
        texture = swapchain_texture,
        load_op = .LOAD,
        store_op = .STORE,
    }
    render_pass := sdl.BeginGPURenderPass(cmd_buff, &color_target, 1, nil); assert(render_pass != nil)
    
    sdl.BindGPUGraphicsPipeline(render_pass, r2d.ui_pipeline)
    assert(r2d.quad.vbo != nil)
    bindings: [2]sdl.GPUBufferBinding = {
        sdl.GPUBufferBinding {buffer = r2d.quad.vbo},
        sdl.GPUBufferBinding {buffer = r2d.quad.ibo},
    }

    // Draw sprites
    for sprite in r2d.sprites {
        im_w := f32(sprite.size.x); im_h := f32(sprite.size.y)
        ubo := UBO2D {
            {win_size.x/2-im_w/2, win_size.y/2-im_h/2, f32(sprite.size.x), f32(sprite.size.y)},
            win_size
        }
        sdl.PushGPUVertexUniformData(cmd_buff, 0, &ubo, size_of(UBO2D))
        sdl.BindGPUFragmentSamplers(render_pass, 0, 
            &(sdl.GPUTextureSamplerBinding {
                texture = sprite.texture,
                sampler = sprite.sampler
            }), 1
        )
        { 
            sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)
            sdl.BindGPUIndexBuffer(render_pass, bindings[1], ._16BIT)
            using r2d.quad
            sdl.DrawGPUIndexedPrimitives(render_pass, 6, 1, 0, 0, 0)
        }
    }
    sdl.EndGPURenderPass(render_pass)

    draw_imgui(state)
}

@(private="file")
draw_imgui :: proc(state: ^AppState) {
    using state
    im_sdlgpu.NewFrame()
    im_sdl.NewFrame()
    im.NewFrame()
    if props.ui_visible {
        if im.Begin("Properties") {
            im.LabelText("", "Light")
            if !props.attatch_light_to_player {
                im.DragFloat3("position", &renderer.light.position, 0.5, -200, 200)
            }
            im.Checkbox("Snap to player", &props.attatch_light_to_player)
            im.DragFloat("intensity", &renderer.light.power, 10, 0, 10000)
            im.ColorPicker3("color", transmute(^vec3)&renderer.light.color, {.InputRGB})
            im.LabelText("", "General")
            im.DragFloat3("Player position", &player.position, 0.25, 0, 60)
            im.DragFloat("Draw distance", &renderer.draw_distance, 0.5, 10, 250)
            if im.Button("Random tiles") do randomize_tile_positions(state)
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
        rendered := i32(debug_info.objects_rendered)
        im.SetNextItemWidth(50)
        im.DragInt("Drawn", &rendered)
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
    im_render_pass := sdl.BeginGPURenderPass(renderer.cmd_buff, &im_color_target, 1, nil); assert(im_render_pass != nil)
    im_sdlgpu.RenderDrawData(im_draw_data, renderer.cmd_buff, im_render_pass)
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