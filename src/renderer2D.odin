package obj_viewer

import "core:log"
import fs "vendor:fontstash"
import sdl "vendor:sdl3"

Vertex2D :: struct {
    position: vec2,
    uv:       vec2,
}

Rect :: sdl.FRect

Renderer2 :: struct {
    quad_pipeline:         ^sdl.GPUGraphicsPipeline,
    sprite_sheet_pipeline: ^sdl.GPUGraphicsPipeline,
    crosshair:              Sprite,
    quad:                   Quad,
}

Sprite :: struct {
    name: string,
    sampler: ^sdl.GPUSampler,
    texture: ^sdl.GPUTexture,
    size:    [2]i32
}

SpriteSheet :: struct {
    texture: ^sdl.GPUTexture,
    rects:   []Rect,
    size:    [2]i32
}

SpriteSheetUBO :: struct {
    dst_rect:    Rect,
    src_rect:    Rect,
    tex_size:    Rect,
    screen_size: vec2,
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

init_r2 :: proc(copy_pass: ^sdl.GPUCopyPass) -> Renderer2 {
    r2: Renderer2
    r2.quad_pipeline = create_render_pipeline(
        "ui.vert",
        "ui.frag",
        Vertex2D,
        {.FLOAT2, .FLOAT2},
        false,
    )
    r2.sprite_sheet_pipeline = create_render_pipeline(
        "spritesheet.vert",
        "spritesheet.frag",
        Vertex2D,
        {.FLOAT2, .FLOAT2},
        false,
    )
    r2.crosshair = load_sprite("assets/crosshair.png", copy_pass)
    r2.quad = init_quad(copy_pass)
    return r2
}

load_font :: proc() {
    fons_context: fs.FontContext
    fs.Init(&fons_context)
}

init_quad :: proc(copy_pass: ^sdl.GPUCopyPass) -> Quad {
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
    assert(r2.quad_pipeline != nil)

    color_target := sdl.GPUColorTargetInfo {
        texture = swapchain,
        load_op = .LOAD,
        store_op = .STORE,
    }
    render_pass = sdl.BeginGPURenderPass(cmd_buff, &color_target, 1, nil); assert(render_pass != nil)
    assert(r2.quad.vbo != nil)
    bindings: [2]sdl.GPUBufferBinding = {
        sdl.GPUBufferBinding {buffer = r2.quad.vbo},
        sdl.GPUBufferBinding {buffer = r2.quad.ibo},
    }
    sdl.BindGPUFragmentSamplers(frame.render_pass, 0, &(sdl.GPUTextureSamplerBinding  {
        texture = renderer.fallback_texture,
        sampler = renderer.default_sampler
    }), 1)
    sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)
    sdl.BindGPUIndexBuffer(render_pass, bindings[1], ._16BIT)
}

draw_crosshair :: proc(renderer: ^Renderer, frame: Frame) {
    bind_pipeline(renderer, frame, .QUAD)
    draw_sprite(renderer.r2.crosshair, frame)
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

draw_sprite_from_sheet :: proc(
    renderer: Renderer,
    sheet: SpriteSheet,
    pos: vec2,
    index: int,
    frame: Frame
) {
    using frame
    if render_pass == nil do panic("Render pass not in progress")
    if index >= len(sheet.rects) {
        log.logf(.Error, "Sprite index %d is out of range", index)
        return
    }

    src_rect := sheet.rects[index]
    ubo_global := SpriteSheetUBO{
        {pos.x, pos.y, src_rect.w, src_rect.h},
        src_rect,
        {
            f32(sheet.size.x), f32(sheet.size.y),
            1/f32(sheet.size.x), 1/f32(sheet.size.y)
        },
        win_size
    }
    sdl.PushGPUVertexUniformData(cmd_buff, 0, &ubo_global, size_of(SpriteSheetUBO))
    sdl.BindGPUFragmentSamplers(render_pass, 0, 
        &(sdl.GPUTextureSamplerBinding {
            texture = sheet.texture,
            sampler = renderer.default_sampler
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

