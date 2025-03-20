package obj_viewer

import sdl "vendor:sdl3"

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

draw_ui :: proc(renderer: ^Renderer, ui_elements: []Quad) {
    color_target := sdl.GPUColorTargetInfo {
        texture = renderer.swapchain_texture,
        load_op = .LOAD,
        store_op = .STORE,
        clear_color = {0, 0, 0, 1},
    }
    render_pass := sdl.BeginGPURenderPass(renderer.cmd_buff, &color_target, 1, nil); assert(render_pass != nil)
    sdl.BindGPUGraphicsPipeline(render_pass, renderer.pipeline2D)
    for &element in ui_elements {
        sdl.BindGPUIndexBuffer(render_pass, { buffer = element.ibo }, ._32BIT)
        bindings: [1]sdl.GPUBufferBinding = sdl.GPUBufferBinding { buffer = element.vbo }
        sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)

        sdl.DrawGPUIndexedPrimitives(render_pass, element.num_indices, 1, 0, 0, 0)
    }

    sdl.EndGPURenderPass(render_pass)
}

quad_pipeline :: proc(renderer: ^Renderer) {
    sdl.ReleaseGPUGraphicsPipeline(renderer.gpu, renderer.pipeline2D)
    vert_shader := load_shader(renderer.gpu, vert_code_2D, .VERTEX, 0, 0, 0); defer sdl.ReleaseGPUShader(renderer.gpu, vert_shader)
    frag_shader := load_shader(renderer.gpu, frag_code_2D, .FRAGMENT, 0, 0, 0); defer sdl.ReleaseGPUShader(renderer.gpu, frag_shader)

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

    renderer.pipeline2D = sdl.CreateGPUGraphicsPipeline(renderer.gpu, {
        vertex_shader = vert_shader,
        fragment_shader = frag_shader,
        primitive_type = .TRIANGLELIST,
        target_info = {
            num_color_targets = 1,
            color_target_descriptions = &(sdl.GPUColorTargetDescription {
                format = sdl.GetGPUSwapchainTextureFormat(renderer.gpu, renderer.window)
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
            cull_mode = .BACK
        },
    })
}