package obj_viewer

import gl "vendor:cgltf"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"
import "core:log"
import "core:fmt"
import "core:mem"
import "core:c"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:math/linalg"
import "core:time"

GLTFMaterial :: struct {
    name: string,
    base_color_factor: vec4,
    base_color_texture: GLTFTexture,
    metallic_factor: f32,
    roughness_factor: f32,
    metallic_roughness_texture: GLTFTexture,
}

GLTFTexture :: struct {
    texture: ^sdl.GPUTexture,
    sampler: ^sdl.GPUSampler
}

GLTFPrimitive :: struct {
    start: uint,
    end: uint,
    material: GLTFMaterial
}

GLTFMesh :: struct {
    name: string,
    primitives: []GLTFPrimitive,
    vbo: ^sdl.GPUBuffer,
    ibo: ^sdl.GPUBuffer,
}

GLTFVertex :: struct {
    position: vec3,
    normal: vec3,
    uv: vec2
}

GLTFNode :: struct {
    mesh:        ^GLTFMesh,
    mat:         matrix[4,4]f32,
    children:    []GLTFNode,
}


build_gltf_pipeline :: proc(renderer: ^Renderer) {
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
    gltf_pipeline = pipeline
}

load_gltf :: proc(path: cstring, gpu: ^sdl.GPUDevice) -> ([]GLTFMesh, GLTFNode) {
    gltf_data := parse_file(path); defer gl.free(gltf_data)
    assert(len(gltf_data.buffers) == 1)
    assert(len(gltf_data.scene.nodes) == 1)
    meshes := load_meshes(gltf_data, gpu)
    root: GLTFNode
    build_scene(gltf_data.scene.nodes[0], meshes, &root)
    return meshes, root
}

print_node_tree :: proc(root: GLTFNode, level := 0) {
    fmt.println("LEVEL", level)
    if root.mesh != nil do for m in root.mesh.primitives do fmt.println(m.material.name)
    for node in root.children {
        for i in 0..<level do fmt.print("\t")
        print_node_tree(node, level = level + 1)
    }
}

build_scene :: proc(gl_node: ^gl.node, meshes: []GLTFMesh, node: ^GLTFNode) {
    // Mesh
    if gl_node.mesh != nil {
        m_name := strings.clone_from_cstring(gl_node.mesh.name, context.temp_allocator)
        for &m in meshes {
            if m.name == m_name {
                node.mesh = &m
                break
            }
        }
    }
    // Model matrix
    if gl_node.has_matrix {
        fmt.println("If the scene is fucked up, the matrix transmutation likely didn't work")
        m := gl_node.matrix_
        node.mat = transmute(matrix[4,4]f32)m
        fmt.println(node.mat)
    } else {
        t_mat: matrix[4,4]f32
        if gl_node.has_translation do t_mat = linalg.matrix4_translate(gl_node.translation)
        else do t_mat = linalg.MATRIX4F32_IDENTITY

        rotation: quaternion128
        if gl_node.has_rotation {
            r := gl_node.rotation
            rotation = quaternion(real = r.w, imag = r.x, jmag = r.y, kmag = r.z)
        } else do rotation = quaternion(real = 1, imag = 0, jmag = 0, kmag = 0)
        r_mat := linalg.matrix4_from_quaternion(rotation)


        s_mat: matrix[4,4]f32
        if gl_node.has_scale do s_mat = linalg.matrix4_scale(gl_node.scale)
        else do s_mat = linalg.MATRIX4F32_IDENTITY
        node.mat = t_mat * r_mat * s_mat
    }
    if len(gl_node.children) == 0 do return
    children := make([]GLTFNode, len(gl_node.children))
    node.children = children
    for child, i in gl_node.children {
        build_scene(child, meshes, &node.children[i])
    }
}

load_meshes :: proc(data: ^gl.data, gpu: ^sdl.GPUDevice) -> []GLTFMesh {
    meshes: [dynamic]GLTFMesh
    copy_commands := sdl.AcquireGPUCommandBuffer(gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)
    for m in data.meshes {
        vertices, indices, primitives := load_mesh(m, gpu, copy_pass)
        name := strings.clone_from_cstring(m.name)
        defer {
            delete(vertices)
            delete(indices)
        }
        mesh: GLTFMesh
        mesh.name = name
        mesh.primitives = primitives
        vert_count: uint = len(vertices)
        index_count: uint = len(indices)
        len_bytes := vert_count*size_of(GLTFVertex) + index_count*size_of(u16)
        transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
            usage = sdl.GPUTransferBufferUsage.UPLOAD,
            size = u32(len_bytes),
        }); assert(transfer_buffer != nil)
        vbo := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.VERTEX}, vertices)
        assert(vbo != nil)
        mesh.vbo = vbo
        ibo := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.INDEX}, indices)
        assert(ibo != nil)
        mesh.ibo = ibo
        sdl.ReleaseGPUTransferBuffer(gpu, transfer_buffer)
        append(&meshes, mesh)
    }

    sdl.EndGPUCopyPass(copy_pass)
    ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)
    return meshes[:]
}

load_material :: proc(m: ^gl.material, gpu: ^sdl.GPUDevice, copy_pass: ^sdl.GPUCopyPass) -> GLTFMaterial {
    assert(bool(m.has_pbr_metallic_roughness))
    material: GLTFMaterial;
    using material
    name = strings.clone_from_cstring(m.name)
    base_color_factor = m.pbr_metallic_roughness.base_color_factor
    metallic_factor = m.pbr_metallic_roughness.metallic_factor
    roughness_factor = m.pbr_metallic_roughness.roughness_factor
    base_color_tex := m.pbr_metallic_roughness.base_color_texture.texture
    base_color_texture = load_texture(base_color_tex, gpu, copy_pass)
    metallic_roughness_tex := m.pbr_metallic_roughness.metallic_roughness_texture.texture
    metallic_roughness_texture = load_texture(metallic_roughness_tex, gpu, copy_pass)

    return material
}

load_texture :: proc(t: ^gl.texture, gpu: ^sdl.GPUDevice, copy_pass: ^sdl.GPUCopyPass) -> GLTFTexture {
    if t == nil do return {}
    view := t.image_.buffer_view
    fmt.println("loading image:", t.image_.name)
    data_multiptr := cast([^]byte)view.buffer.data
    ptr := mem.ptr_offset(data_multiptr, view.offset)
    data: [^]byte = cast([^]byte)ptr
    size := i32(view.size)
    width, height: i32
    start := time.now()
    pixels := stbi.load_from_memory(data, size, &width, &height, nil, 4)
    fmt.println(time.since(start))
    defer stbi.image_free(pixels)

    pixels_byte_size := u32(width * height * 4)
    tex_transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = pixels_byte_size,
    }); assert(tex_transfer_buffer != nil)

    texture := sdl.CreateGPUTexture(gpu, {
        type = .D2,
        format = .R8G8B8A8_UNORM_SRGB,
        usage = {.SAMPLER},
        width = u32(width),
        height = u32(height),
        layer_count_or_depth = 1,
        num_levels = 1
    }); assert(texture != nil)
    tex_transfer_mem := sdl.MapGPUTransferBuffer(gpu, tex_transfer_buffer, false)
    assert(tex_transfer_mem != nil)
    mem.copy(tex_transfer_mem, pixels, int(pixels_byte_size))
    sdl.UnmapGPUTransferBuffer(gpu, tex_transfer_buffer)
    sdl.UploadToGPUTexture(copy_pass, 
        {transfer_buffer = tex_transfer_buffer},
        {texture = texture, w = u32(width), h = u32(height), d = 1},
        false
    )
    sampler: ^sdl.GPUSampler
    if t.sampler != nil do sampler = sdl.CreateGPUSampler(gpu, {
        min_filter = sdl.GPUFilter(t.sampler.min_filter),
        mag_filter = sdl.GPUFilter(t.sampler.mag_filter)
    }); else do sampler = sdl.CreateGPUSampler(gpu, {})
    assert(sampler != nil)
    return GLTFTexture {
        texture = texture,
        sampler = sampler
    }
}

@(private = "file")
load_mesh :: proc(mesh: gl.mesh, gpu: ^sdl.GPUDevice, copy_pass: ^sdl.GPUCopyPass) -> ([]GLTFVertex, []u16, []GLTFPrimitive) {
    primitives: [dynamic]GLTFPrimitive
    indices: [dynamic]u16
    positions: [dynamic]vec3; defer delete(positions)
    normals:   [dynamic]vec3; defer delete(normals)
    uvs:       [dynamic]vec2; defer delete(uvs)
    num_indices: uint
    for primitive, i in mesh.primitives {
        position_count := len(positions)
        material := load_material(primitive.material, gpu, copy_pass)
        for attribute in primitive.attributes {
            accessor := attribute.data
            #partial switch attribute.type {
                case .normal:   load_buffer_from_accessor(accessor, &normals)
                case .position: load_buffer_from_accessor(accessor, &positions)
                case .texcoord: load_buffer_from_accessor(accessor, &uvs)
            }
        }
        primitive_indices: [dynamic]u16; defer delete(primitive_indices)
        start := len(indices)
        load_buffer_from_accessor(primitive.indices, &primitive_indices)
        for i in primitive_indices do append(&indices, i + u16(position_count))
        end := len(indices)
        gltf_primitive := GLTFPrimitive {
            start = uint(start),
            end = uint(end),
            material = material
        }
        append(&primitives, gltf_primitive)
    }
    if uvs == nil do uvs = make([dynamic]vec2, len(positions))
    vertices: [dynamic]GLTFVertex
    for i in 0..<len(positions) {
        append(&vertices, GLTFVertex {
            position = positions[i],
            normal = normals[i],
            uv = uvs[i]
        })
    }
    return vertices[:], indices[:], primitives[:]
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