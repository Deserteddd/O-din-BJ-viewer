package obj_viewer

import "core:time"
import "core:math"
import "core:fmt"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"
import im "shared:imgui"
import im_sdl "shared:imgui/imgui_impl_sdl3"
import im_sdlgpu "shared:imgui/imgui_impl_sdlgpu3"

Vertex2D :: struct {
    position: vec2,
}

Renderer2D :: struct {
    crosshair: Crosshair,
}

Crosshair :: struct {
    vbo: ^sdl.GPUBuffer,
    ibo: ^sdl.GPUBuffer,
    num_vertices: u32,
    num_indices: u32
}

UBO_2D :: struct {
    screensize: [2]u32
}

init_renderer_2d:: proc(renderer: ^Renderer) {
    using renderer
    
    verts, indices := crosshair()

    len_bytes := u32(len(verts) * size_of(Vertex2D))

    transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = len_bytes,
    }); assert(transfer_buffer != nil)

    copy_commands := sdl.AcquireGPUCommandBuffer(gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)
    vbo := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.VERTEX}, verts[:])
    ibo := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.INDEX}, indices[:])

    sdl.ReleaseGPUTransferBuffer(gpu, transfer_buffer)
    sdl.EndGPUCopyPass(copy_pass)
    ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)
    renderer.r2d = {
        crosshair = {vbo, ibo, u32(len(verts)), u32(len(indices))}
    }
}

crosshair :: proc() -> (verts: [16]Vertex2D, indices: [24]u16) {
    verts = {
        // top bar
        Vertex2D{{ -0.0010417,  0.0222222 }},
        Vertex2D{{  0.0010417,  0.0222222 }},
        Vertex2D{{  0.0010417,  0.0074074 }},
        Vertex2D{{ -0.0010417,  0.0074074 }},
        Vertex2D{{ -0.0010417, -0.0074074 }},
        Vertex2D{{  0.0010417, -0.0074074 }},
        Vertex2D{{  0.0010417, -0.0222222 }},
        Vertex2D{{ -0.0010417, -0.0222222 }},
        Vertex2D{{ -0.0125000,  0.0018519 }},
        Vertex2D{{ -0.0041667,  0.0018519 }},
        Vertex2D{{ -0.0041667, -0.0018519 }},
        Vertex2D{{ -0.0125000, -0.0018519 }},
        Vertex2D{{  0.0041667,  0.0018519 }},
        Vertex2D{{  0.0125000,  0.0018519 }},
        Vertex2D{{  0.0125000, -0.0018519 }},
        Vertex2D{{  0.0041667, -0.0018519 }},
    };
    indices = {
        0,1,2, 2,3,0,
        4,5,6, 6,7,4,
        8,9,10, 10,11,8,
        12,13,14, 14,15,12
    };
    return
}

RND_DrawUI :: proc(state: ^AppState) {
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
    draw_2d(&state.renderer)
}

draw_2d :: proc(renderer: ^Renderer) {
    using renderer
    assert(renderer.cmd_buff != nil)
    assert(renderer.swapchain_texture != nil)
    assert(renderer.ui_pipeline != nil)
    // assert(renderer..crosshair.vbo != nil)

    color_target := sdl.GPUColorTargetInfo {
        texture = renderer.swapchain_texture,
        load_op = .LOAD,
        store_op = .STORE,
    }
    render_pass := sdl.BeginGPURenderPass(cmd_buff, &color_target, 1, nil); assert(render_pass != nil)
    
    sdl.BindGPUGraphicsPipeline(render_pass, ui_pipeline)
    bindings: [2]sdl.GPUBufferBinding = {
        sdl.GPUBufferBinding {buffer = r2d.crosshair.vbo},
        sdl.GPUBufferBinding {buffer = r2d.crosshair.ibo},
    }
    sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)
    sdl.BindGPUIndexBuffer(render_pass, bindings[1], ._16BIT)
    { 
        using r2d.crosshair
        sdl.DrawGPUIndexedPrimitives(render_pass, num_indices, 1, 0, 0, 0)
        sdl.EndGPURenderPass(render_pass)
    }
}

build_pipeline_2d :: proc(renderer: ^Renderer) {
    using renderer
    sdl.ReleaseGPUGraphicsPipeline(gpu, ui_pipeline)
    vert_shader := load_shader(renderer.gpu, "ui.vert"); defer sdl.ReleaseGPUShader(renderer.gpu, vert_shader)
    frag_shader := load_shader(renderer.gpu, "ui.frag"); defer sdl.ReleaseGPUShader(renderer.gpu, vert_shader)

    vb_descriptions: [1]sdl.GPUVertexBufferDescription
    vb_descriptions = {
        sdl.GPUVertexBufferDescription {
            slot = u32(0),
            pitch = size_of(vec2),
            input_rate = .VERTEX,
            instance_step_rate = 0
        },
    }  
    vb_attributes: []sdl.GPUVertexAttribute = {
        sdl.GPUVertexAttribute { // Screen size
            location = 0,
            buffer_slot = 0,
            format = .FLOAT2,
            offset = 0
        },
    }
    format := sdl.GetGPUSwapchainTextureFormat(renderer.gpu, renderer.window)
    renderer.ui_pipeline = sdl.CreateGPUGraphicsPipeline(gpu, {
        vertex_shader = vert_shader,
        fragment_shader = frag_shader,
        primitive_type = .TRIANGLELIST,
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
            fill_mode = .FILL,
            cull_mode = .NONE,
        },
    })
}