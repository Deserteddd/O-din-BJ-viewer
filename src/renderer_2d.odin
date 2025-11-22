package obj_viewer

import "core:strings"
import sdl "vendor:sdl3"


Vertex2D :: struct {
    position: vec2,
    uv:       vec2,
}


Rect :: sdl.FRect

R2D :: struct {
    ui_pipeline: ^sdl.GPUGraphicsPipeline,
    crosshair:   Sprite,
    quad:        Quad,
    color:       vec4
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
    rect:     Rect,
    win_size: vec2,
    use_tex:  b32,
    _pad:     b32,
    color:    vec4
}

upload_sprite :: proc(path: string, copy_pass: ^sdl.GPUCopyPass) -> Sprite {
    pixels, size := load_pixels_byte(path); assert(pixels != nil)
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
        rect = {x, y, f32(sprite.size.x)*scale, f32(sprite.size.y)*scale},
        win_size = win_size,
        use_tex = true,
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

draw_rect :: proc(rect: Rect, frame: Frame, color: vec4 = 0.2) {
    using frame
    if render_pass == nil do panic("Render pass not in progress")

    ubo := UBO2D {
        rect = rect,
        win_size = win_size,
        use_tex = false,
        color = color
    }
    sdl.PushGPUVertexUniformData(cmd_buff, 0, &ubo, size_of(UBO2D))
    sdl.DrawGPUIndexedPrimitives(render_pass, 6, 1, 0, 0, 0)
}

submit_2d :: proc(frame: ^Frame) {
    sdl.EndGPURenderPass(frame.render_pass)
    frame.render_pass = nil
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

