package obj_viewer

import gl "vendor:cgltf"
import sdl "vendor:sdl3"
import "core:log"
import "core:fmt"
import "core:mem"
import "core:c"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:math/linalg"

GLTFScene :: struct {
    meshes: []GLTFMesh,
    materials: []GLTFMaterial,
    pipeline: ^sdl.GPUGraphicsPipeline,
    material_buffer: ^sdl.GPUBuffer
}

GLTFMaterial :: struct {
    name: string,
    base_color: vec4,
    metallic_factor: f32,
    roughness_factor: f32,
}

GLTFMaterialParams :: struct {
    base_color: vec4,
    metallic_factor: f32,
    roughness_factor: f32,
    _pad: vec2
}

GLTFMesh :: struct {
    vertices: []GLTFVertex,
    indices: []u16,
    material_name: string,
    vbo: ^sdl.GPUBuffer,
    num_vertices: uint,
    ibo: ^sdl.GPUBuffer,
    num_indices: uint
}

GLTFVertex :: struct {
    position: vec3,
    normal: vec3,
    uv: vec2
}

build_gltf_pipeline :: proc(renderer: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
    using renderer
    vert_shader := load_shader(gpu, "pbr_metallic.vert"); defer sdl.ReleaseGPUShader(gpu, vert_shader)
    frag_shader := load_shader(gpu, "pbr_metallic.frag"); defer sdl.ReleaseGPUShader(gpu, vert_shader)
    vb_descriptions: [1]sdl.GPUVertexBufferDescription
    vb_descriptions = {
        sdl.GPUVertexBufferDescription {
            slot = u32(0),
            pitch = size_of(GLTFVertex),
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
    }
    fill_mode: sdl.GPUFillMode;
    cull_mode: sdl.GPUCullMode; 
    if .WIREFRAME in props {fill_mode = .LINE; cull_mode = .NONE} else {fill_mode = .FILL; cull_mode = .BACK}
    format := sdl.GetGPUSwapchainTextureFormat(gpu, window)
    pipeline := sdl.CreateGPUGraphicsPipeline(gpu, {
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
            num_vertex_attributes = 3
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
    }); assert(pipeline != nil)
    return pipeline
}

prepare_gltf_scene :: proc(scene: ^GLTFScene, renderer: ^Renderer) {
    using renderer
    scene.pipeline = build_gltf_pipeline(renderer)
    copy_commands := sdl.AcquireGPUCommandBuffer(gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)
    for &mesh in scene.meshes {
        vert_count: uint = len(mesh.vertices)
        index_count: uint = len(mesh.indices)
        len_bytes := vert_count*size_of(GLTFVertex) + index_count*size_of(u16)
        transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
            usage = sdl.GPUTransferBufferUsage.UPLOAD,
            size = u32(len_bytes),
        }); assert(transfer_buffer != nil)
        mesh.vbo = create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.VERTEX}, mesh.vertices)
        mesh.ibo = create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.INDEX}, mesh.indices)
        mesh.num_vertices = vert_count
        mesh.num_indices = index_count
        sdl.ReleaseGPUTransferBuffer(gpu, transfer_buffer)
    }
    materials: [dynamic]GLTFMaterialParams; defer delete(materials)
    for material in scene.materials {
        append(&materials, GLTFMaterialParams{
            base_color = material.base_color,
            metallic_factor = material.metallic_factor,
            roughness_factor = material.roughness_factor,
        })
    }
    transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = u32(len(materials) * size_of(GLTFMaterialParams)),
    }); assert(transfer_buffer != nil)
    scene.material_buffer = create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.GRAPHICS_STORAGE_READ}, materials[:])
    sdl.EndGPUCopyPass(copy_pass)
    ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)
}

draw_gltf_scene :: proc(state: ^AppState) {
    using state
    assert(renderer.cmd_buff != nil)
    assert(renderer.swapchain_texture != nil)
    proj_matrix := create_proj_matrix(renderer)
    view_matrix := create_view_matrix(player.position, player.rotation)
    vp := proj_matrix * view_matrix;
    color_target := sdl.GPUColorTargetInfo {
        texture = renderer.swapchain_texture,
        load_op = .LOAD,
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
    scene := &gltf_scene
    render_pass := sdl.BeginGPURenderPass(renderer.cmd_buff, &color_target, 1, &depth_target_info); assert(render_pass != nil)
    sdl.BindGPUGraphicsPipeline(render_pass, scene.pipeline)
    sdl.BindGPUFragmentStorageBuffers(render_pass, 0, &scene.material_buffer, 1)
    for mesh in scene.meshes {
        bindings: [2]sdl.GPUBufferBinding = { 
            sdl.GPUBufferBinding { buffer = mesh.vbo },
            sdl.GPUBufferBinding { buffer = mesh.ibo }
        } 
        sdl.BindGPUVertexBuffers(render_pass, 0, &bindings[0], 1)
        sdl.BindGPUIndexBuffer(render_pass, bindings[1], ._16BIT)
        sdl.PushGPUVertexUniformData(renderer.cmd_buff, 0, &vp, size_of(matrix[4,4]f32))

        model_matrix := linalg.matrix4_scale_f32({5, 5, 5})
        sdl.PushGPUVertexUniformData(renderer.cmd_buff, 1, &model_matrix, size_of(matrix[4,4]f32))
        sdl.DrawGPUIndexedPrimitives(render_pass, u32(mesh.num_indices), 1, 0, 0, 0)
    }
    sdl.EndGPURenderPass(render_pass)
}

load_gltf :: proc(path: cstring, gpu: ^sdl.GPUDevice) -> GLTFScene {
    gltf_data := parse_file(path); defer gl.free(gltf_data)
    assert(len(gltf_data.buffers) == 1)
    scene: GLTFScene
    meshes: [dynamic]GLTFMesh
    for mesh, i in gltf_data.meshes {
        new_meshes := load_meshes(mesh)
        for m in new_meshes do append(&meshes, m)
    }
    scene.meshes = meshes[:]

    materials: [dynamic]GLTFMaterial
    load_materials(gltf_data.materials, &materials)
    scene.materials = materials[:]
    return scene
}

load_materials :: proc(materials: []gl.material, buffer: ^[dynamic]GLTFMaterial) {
    for m in materials {
        assert(bool(m.has_pbr_metallic_roughness))
        material: GLTFMaterial;
        using material
        name = strings.clone_from_cstring(m.name)
        base_color = m.pbr_metallic_roughness.base_color_factor
        metallic_factor = m.pbr_metallic_roughness.metallic_factor
        roughness_factor = m.pbr_metallic_roughness.roughness_factor
        append(buffer, material)
    }
}

print_gltf_description :: proc(scene: GLTFScene) {
    fmt.println("Meshes:")
    for m in scene.meshes {
        fmt.println("\tMesh with material:", m.material_name)
        fmt.printfln("\t\t{} indices",len(m.indices))
        fmt.println("\t\tVertex count:", len(m.vertices))
    }
    fmt.println("Materials:")
    for m in scene.materials {
        fmt.printfln("\t{}", m.name)
        fmt.println("\t\tBase color:", m.base_color)
        fmt.println("\t\tMetallic:  ", m.metallic_factor)
        fmt.println("\t\tRoughness: ", m.roughness_factor)
    }
}


@(private = "file")
load_meshes :: proc(mesh: gl.mesh) -> []GLTFMesh {
    meshes: [dynamic]GLTFMesh

    for primitive, i in mesh.primitives {
        positions: [dynamic]vec3; defer delete(positions)
        normals:   [dynamic]vec3; defer delete(normals)
        uvs:       [dynamic]vec2; defer delete(uvs)
        indices:   [dynamic]u16
        load_buffer_from_accessor(primitive.indices, &indices)

        for attribute in primitive.attributes {
            accessor := attribute.data
            #partial switch attribute.type {
                case .normal:   load_buffer_from_accessor(accessor, &normals)
                case .position: load_buffer_from_accessor(accessor, &positions)
                case .texcoord: load_buffer_from_accessor(accessor, &uvs)
            }
        }

        if uvs == nil do uvs = make([dynamic]vec2, len(positions))
        vertices := make([]GLTFVertex, len(positions))

        for i in 0..<len(positions) {
            vertices[i] = GLTFVertex {
                position = positions[i],
                normal = normals[i],
                uv = uvs[i]
            }
        }

        append(&meshes, GLTFMesh {
            vertices = vertices, 
            indices = indices[:],
            material_name = strings.clone_from_cstring(primitive.material.name)
        })
    }

    return meshes[:]
}

@(private = "file")
load_buffer_from_accessor :: proc(accessor: ^gl.accessor, buffer: ^[dynamic]$T) {
    buffer_data := gl.buffer_view_data(accessor.buffer_view)
    data := cast([^]T)buffer_data
    for i in 0..<accessor.count do append(buffer, data[i])
}

@(private = "file")
parse_file :: proc(path: cstring) -> ^gl.data {
    data, err := gl.parse_file({}, path)
    if err != nil do log.errorf("error parsing file: {}", err)
    result := gl.load_buffers({}, data, path); assert(result == .success)
    result =  gl.validate(data); assert(result == .success)
    return data
}