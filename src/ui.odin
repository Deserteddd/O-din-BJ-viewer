package obj_viewer

import sdl "vendor:sdl3"
import "core:fmt"

GUI :: struct {
    pipeline: ^sdl.GPUGraphicsPipeline,
    quad: Quad,
    sampler: ^sdl.GPUSampler
}

Vertex2 :: struct {
    position: vec2,
    uv: vec2
}

Quad :: struct {
    position: vec2,
    vbo: ^sdl.GPUBuffer,
    ibo: ^sdl.GPUBuffer,
    num_indices: u32
}

GUI_Init :: proc(gpu: ^sdl.GPUDevice, window: ^sdl.Window) -> GUI {
    pipeline := build_2D_pipeline(gpu, window)
    quad     := create_quad(gpu)
    sampler  := sdl.CreateGPUSampler(gpu, {}); assert(sampler != nil)
    return GUI {
        pipeline,
        quad,
        sampler
    }
}

create_quad :: proc(gpu: ^sdl.GPUDevice) -> Quad {
    vertices: [4]Vertex2 = {
        Vertex2{position = vec2{-1,  1}, uv = vec2{0, 1}},
        Vertex2{position = vec2{-1, -1}, uv = vec2{0, 0}},
        Vertex2{position = vec2{ 1, -1}, uv = vec2{1, 0}},
        Vertex2{position = vec2{ 1,  1}, uv = vec2{1, 1}}
    }
    indices: [6]u32 = {0, 1, 2, 0, 2, 3}
    len_bytes := max(
        size_of(vertices),
        size_of(indices)
    )
    transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = u32(len_bytes),
    }); assert(transfer_buffer != nil)
    copy_commands := sdl.AcquireGPUCommandBuffer(gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)

    vbo := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.VERTEX}, vertices[:]); assert(vbo != nil)
    ibo := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.INDEX}, indices[:]); assert(ibo != nil)
    sdl.ReleaseGPUTransferBuffer(gpu, transfer_buffer)
    sdl.EndGPUCopyPass(copy_pass)
    ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)
    return Quad {
        position = vec2{-1, 1},
        vbo = vbo,
        ibo = ibo,
        num_indices = 6
    }
}

draw_ui :: proc(renderer: ^Renderer) {
    assert(renderer.depth_texture != nil)
    color_target := sdl.GPUColorTargetInfo {
        texture = renderer.swapchain_texture,
        load_op = .LOAD,
        store_op = .STORE,
        clear_color = {0, 0, 0, 1},
    }
    render_pass := sdl.BeginGPURenderPass(renderer.cmd_buff, &color_target, 1, nil); assert(render_pass != nil)

    using renderer.gui
    sdl.BindGPUGraphicsPipeline(render_pass, pipeline)
    sdl.BindGPUFragmentSamplers(render_pass, 0, 
        &(sdl.GPUTextureSamplerBinding{texture = renderer.depth_texture, sampler = sampler}), 1
    )
    sdl.BindGPUIndexBuffer(render_pass, { buffer = quad.ibo }, ._32BIT)
    bindings: [1]sdl.GPUBufferBinding = sdl.GPUBufferBinding { buffer = quad.vbo }
    sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)
    sdl.DrawGPUIndexedPrimitives(render_pass, quad.num_indices, 1, 0, 0, 0)
    sdl.EndGPURenderPass(render_pass)
}

@(private = "file")
build_2D_pipeline :: proc(gpu: ^sdl.GPUDevice, window: ^sdl.Window) -> ^sdl.GPUGraphicsPipeline {
    pipeline: ^sdl.GPUGraphicsPipeline
    sdl.ReleaseGPUGraphicsPipeline(gpu, pipeline)
    vert_shader := load_shader(gpu, vert_code_2D, .VERTEX, 0, 0, 0); defer sdl.ReleaseGPUShader(gpu, vert_shader)
    frag_shader := load_shader(gpu, frag_code_2D, .FRAGMENT, 0, 1, 0); defer sdl.ReleaseGPUShader(gpu, frag_shader)

    vb_descriptions: [1]sdl.GPUVertexBufferDescription
    vb_descriptions[0] = sdl.GPUVertexBufferDescription {
        slot = u32(0),
        pitch = size_of(Vertex2),
        input_rate = .VERTEX,
        instance_step_rate = 0
    }     

    vb_attributes: []sdl.GPUVertexAttribute = {
        sdl.GPUVertexAttribute { // Position
            location = 0,
            buffer_slot = 0,
            format = .FLOAT2,
            offset = 0
        },
        sdl.GPUVertexAttribute { // UV
            location = 1,
            buffer_slot = 0,
            format = .FLOAT2,
            offset = size_of(vec2)
        },
    }

    pipeline = sdl.CreateGPUGraphicsPipeline(gpu, {
        vertex_shader = vert_shader,
        fragment_shader = frag_shader,
        primitive_type = .TRIANGLELIST,
        target_info = {
            num_color_targets = 1,
            color_target_descriptions = &(sdl.GPUColorTargetDescription {
                format = sdl.GetGPUSwapchainTextureFormat(gpu, window)
            }),
        },
        vertex_input_state = {
            vertex_buffer_descriptions = &vb_descriptions[0],
            num_vertex_buffers = 1,
            vertex_attributes = &vb_attributes[0],
            num_vertex_attributes = 2
        },
        rasterizer_state = {
            fill_mode = .FILL,
            cull_mode = .NONE
        },
    })
    return pipeline
}