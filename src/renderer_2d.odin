package obj_viewer

import "core:time"
import "core:math/linalg"
import "core:strings"
import sdl "vendor:sdl3"
import im "shared:imgui"
import im_sdl "shared:imgui/imgui_impl_sdl3"
import im_sdlgpu "shared:imgui/imgui_impl_sdlgpu3"

Vertex2D :: struct {
    position: vec2,
    uv:       vec2,
}


Rect :: struct {
    x, y,
    width,
    height: f32
}

R2D :: struct {
    ui_pipeline: ^sdl.GPUGraphicsPipeline,
    crosshair:   Sprite,
    quad:        Quad,
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
    win_size: vec2,
    use_tex:  b32,
    _pad:     b32
}

upload_sprite :: proc(path: string, copy_pass: ^sdl.GPUCopyPass) -> Sprite {
    pixels, size := load_pixels(path); assert(pixels != nil)
    size_u32: [2]u32 = {u32(size.x), u32(size.y)}
    texture := upload_texture(copy_pass, pixels, size_u32)
    assert(texture != nil)
    free_pixels(pixels)

    file_name  := strings.split(path, "/", context.temp_allocator)
    name_split := strings.split(file_name[len(file_name)-1], ".", context.temp_allocator)
    name       := strings.clone(name_split[0])

    sampler := sdl.CreateGPUSampler(g.gpu, {}); assert(sampler != nil)
    return Sprite {
        name,
        sampler,
        texture,
        size
    }
}

init_r2d :: proc(renderer: Renderer) {

    copy_commands := sdl.AcquireGPUCommandBuffer(g.gpu); assert(copy_commands != nil)
    defer {ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)}

    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)
    defer sdl.EndGPUCopyPass(copy_pass)

    {
        using renderer.r2d
        ui_pipeline = create_render_pipeline(
                "ui.vert",
                "ui.frag",
                Vertex2D,
                {.FLOAT2, .FLOAT2},
                false,
                num_vertex_buffers = 2,
                alpha_blend = true
        )
        crosshair = upload_sprite("assets/crosshair.png", copy_pass)
        quad = init_quad(copy_pass)
    }
}

init_quad :: proc(
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

    vbo, ibo := upload_polygon(copy_pass, verts[:], indices[:])
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
    sdl.BindGPUFragmentSamplers(frame.render_pass, 0, &(sdl.GPUTextureSamplerBinding  {
        texture = renderer.fallback_texture,
        sampler = renderer.default_sampler
    }), 1)
    sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)
    sdl.BindGPUIndexBuffer(render_pass, bindings[1], ._16BIT)
}

draw_crosshair :: proc(renderer: Renderer, frame: Frame) {
    draw_sprite(renderer.r2d.crosshair, frame)
}

draw_sprite :: proc(sprite: Sprite, frame: Frame, pos: vec2 = 0, scale: f32 = 1) {
    using frame
    if render_pass == nil do panic("Render pass not in progress")

    x := pos == 0 ? win_size.x/2 - f32(sprite.size.x)/2 : pos.x
    y := pos == 0 ? win_size.y/2 - f32(sprite.size.y)/2 : pos.y

    ubo := UBO2D {
        {x, y, f32(sprite.size.x)*scale, f32(sprite.size.y)*scale},
        win_size,
        true,
        false
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

draw_rect :: proc(rect: Rect, frame: Frame) {
    using frame
    if render_pass == nil do panic("Render pass not in progress")

    ubo := UBO2D {
        {rect.x, rect.y, rect.width, rect.height},
        win_size,
        false,
        false
    }
    sdl.PushGPUVertexUniformData(cmd_buff, 0, &ubo, size_of(UBO2D))
    sdl.DrawGPUIndexedPrimitives(render_pass, 6, 1, 0, 0, 0)
}

submit_2d :: proc(frame: ^Frame) {
    sdl.EndGPURenderPass(frame.render_pass)
    frame.render_pass = nil
}
import "core:fmt"
draw_imgui :: proc(state: ^AppState, frame: Frame) {
    using state, frame
    im_sdlgpu.NewFrame()
    im_sdl.NewFrame()
    im.NewFrame()
    if g.mode == .EDIT {
        if im.Begin("Properties", nil, {.NoTitleBar, .NoResize, .NoMove}) {
            im.SetWindowPos(0)
            im.SetWindowSize({editor.sidebar.width, editor.sidebar.height})
            if im.BeginTabBar("PropertiesTabs") {
                if im.BeginTabItem("Entity") {
                    defer im.EndTabItem()
                    for &e in entities {
                        if e.id == editor.selected_entity {
                            if im.DragFloat3("Position", &e.transform.translation, 0.01) do editor.dragging = true
                            if im.DragFloat3("Scale",    &e.transform.scale, 0.01) do editor.dragging = true
                            break
                        }
                    }
                }

                // --- General Tab ---
                if im.BeginTabItem("General") {
                    defer im.EndTabItem()
                    im.LabelText("", "General")
                    if height_map != nil do im.DragFloat3("Heightmap scale", &height_map.scale, 0.001, 0, 2)
                    im.DragFloat("FOV", &g.fov, 1, 50, 140)
                }

                // --- Point Light Tab ---
                if im.BeginTabItem("Point Light") {
                    defer im.EndTabItem()
                    im.LabelText("", "Point Light")
                    im.DragFloat("intensity", &renderer.light.power, 10, 0, 10000)
                    im.ColorPicker3("color", &renderer.light.color, {.InputRGB})
                }

                im.EndTabBar()
            }
            im.End()
        }
    }
    if im.Begin("info", nil, {.NoTitleBar, .NoMouseInputs}) {
        w, h: i32
        sdl.GetWindowSize(g.window, &w, &h)
        im.SetWindowPos(vec2{f32(w-140), 0})
        im.SetWindowSize(vec2{140, 0})
        frame_time_float := i32(linalg.round(1/f32(time.duration_seconds(debug_info.frame_time))))
        im.SetNextItemWidth(50)
        im.DragInt("FPS", &frame_time_float)
        rendered := i32(debug_info.draw_call_count)
        im.SetNextItemWidth(50)
        im.DragInt("Draw calls", &rendered)
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
    copy_pass:   ^sdl.GPUCopyPass,
    verts:      []Vertex2D,
    indices:    []u16
) -> (vbo, ibo: ^sdl.GPUBuffer){
    len_bytes := u32(len(verts) * size_of(Vertex2D))

    transfer_buffer := sdl.CreateGPUTransferBuffer(g.gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = len_bytes,
    }); assert(transfer_buffer != nil)


    vbo = create_buffer_with_data(transfer_buffer, copy_pass, {.VERTEX}, verts[:]); assert(vbo != nil)
    ibo = create_buffer_with_data(transfer_buffer, copy_pass, {.INDEX}, indices[:]); assert(ibo != nil)

    sdl.ReleaseGPUTransferBuffer(g.gpu, transfer_buffer)
    return
}

init_imgui :: proc(state: ^AppState) {
    assert(g.window != nil)
    if state.ui_context != nil {
        im_sdlgpu.Shutdown()
        im_sdl.Shutdown()
        im.Shutdown()
        im.DestroyContext(state.ui_context)
    }
    im.CHECKVERSION()
    state.ui_context = im.CreateContext()
    using state.renderer
    im_sdl.InitForSDLGPU(g.window)
    im_sdlgpu.Init(&{
        Device = g.gpu,
        ColorTargetFormat = sdl.GetGPUSwapchainTextureFormat(g.gpu, g.window)
    })
    style := im.GetStyle()
    for &color in style.Colors {
        color.rgb = linalg.pow(color.rgb, 2.2)
    }
}