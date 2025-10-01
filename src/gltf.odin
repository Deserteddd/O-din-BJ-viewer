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

dbg := false

GLTFObjectData  :: struct {
    root: GLTFNode,
    meshes: []GLTFMesh,
}

GLTFMaterial :: struct {
    name: string,
    texture_count: u32,
    base_color_factor: vec4,
    base_color_texture: GLTFTexture,
    metallic_factor: f32,
    roughness_factor: f32,
    metallic_roughness_texture: GLTFTexture,
    normal_map: GLTFTexture,
}

Transform :: struct {
    translation: vec3,
    rotation: quaternion128,
    scale:      vec3
}

GLTFTexture :: struct {
    texture: ^sdl.GPUTexture,
    sampler: ^sdl.GPUSampler
}

GLTFMesh :: struct {
    vbo: ^sdl.GPUBuffer,
    ibo: ^sdl.GPUBuffer,
    data: MeshData
}

GLTFPrimitive :: struct {
    start: uint,
    end: uint,
    material: GLTFMaterial
}

MeshData :: struct {
    name:       string,
    positions:  []vec3,
    normals:    []vec3,
    uvs:        []vec2,
    tangents:   []vec3,
    indices:    []u16,
    primitives: []GLTFPrimitive,
}

GLTFVertex :: struct {
    position: vec3,
    normal: vec3,
    uv: vec2,
    tangent: vec3
}

GLTFNode :: struct {
    aabb:       AABB,
    mesh:       ^GLTFMesh,
    children:   []GLTFNode,
    transform: Transform,
    bbox_vbo: ^sdl.GPUBuffer,
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
        sdl.GPUVertexAttribute {
            location = 3,
            buffer_slot = 0,
            format = .FLOAT3,
            offset = size_of(vec3) * 2 + size_of(vec2)
        }
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
            num_vertex_attributes = 4
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

print_gltf :: proc(data: GLTFObjectData) {
    line := "---------------------------------------------------------------------------------"
    fmt.println(line); defer fmt.println(line)
    print_node(data.root)
}

print_node :: proc(node: GLTFNode, indent := 0) {
    for i in 0..<indent do fmt.print("\t")
    if node.mesh == nil do fmt.println("Empty node:", node.transform)
    else {
        fmt.println("Mesh node:", node.transform)
        for p in node.mesh.data.primitives {
            for _ in 0..<indent+1 do fmt.print("\t")
            fmt.println("Primitive:", p.start, p.end, p.material.name)
        }
    }
    for c in node.children do print_node(c, indent+1)
}

load_gltf :: proc(path: cstring, gpu: ^sdl.GPUDevice, debug := false) -> GLTFObjectData {
    dbg = debug
    gltf_data := parse_file(path); defer gl.free(gltf_data)
    assert(len(gltf_data.buffers) == 1)
    assert(len(gltf_data.scene.nodes) == 1)
    root: GLTFNode
    meshes: [dynamic]GLTFMesh
    fmt.println(path)
    copy_commands := sdl.AcquireGPUCommandBuffer(gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)

    build_scene(gltf_data.scene.nodes[0], &root, gpu, copy_pass, &meshes)
    sdl.EndGPUCopyPass(copy_pass)
    ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)
    return GLTFObjectData {
        root,
        meshes[:]
    }
}

build_scene :: proc(
    gl_node: ^gl.node,
    node: ^GLTFNode, 
    gpu: ^sdl.GPUDevice, 
    copy_pass: ^sdl.GPUCopyPass,
    meshes: ^[dynamic]GLTFMesh,
    parent_transform := TRANSFORM_IDENTITY,
) {
    transform := TRANSFORM_IDENTITY
    if gl_node.has_matrix {
        t, s, r := decompose_trs(gl_node.matrix_)
        transform.translation = t
        transform.scale = s
        transform.rotation = r
    } else {
        if gl_node.has_translation do transform.translation = gl_node.translation
        if gl_node.has_rotation {
            r := gl_node.rotation
            transform.rotation = quaternion(real = r.w, imag = r.x, jmag = r.y, kmag = r.z)
        }

        if gl_node.has_scale do transform.scale = gl_node.scale
        node.transform = transform
    }

    parent_transform := Transform {
        translation = parent_transform.translation + transform.translation,
        scale = parent_transform.scale * transform.scale,
        rotation = parent_transform.rotation * transform.rotation
    }
    fmt.println(parent_transform)
    // Mesh
    mesh_data := load_mesh_data(gl_node.mesh, gpu, copy_pass)
    if len(mesh_data.primitives) != 0 {
        mesh := load_mesh(mesh_data, gpu, copy_pass)
        append(meshes, mesh)
        node.mesh = &meshes[len(meshes)-1]
        bbox: AABB = {min = max(f32), max = min(f32)}
        for &v in mesh_data.positions {
            v += parent_transform.translation
            q := parent_transform.rotation
            p := quaternion(w = 0, x = v.x, y = v.y, z = v.z)
            q_ := conj(q)
            p_ := q*p*q_
            v = {p_.x, p_.y, p_.z}
            if (v.x < bbox.min.x) do bbox.min.x = v.x;
            if (v.y < bbox.min.y) do bbox.min.y = v.y;
            if (v.z < bbox.min.z) do bbox.min.z = v.z;
            if (v.x > bbox.max.x) do bbox.max.x = v.x;
            if (v.y > bbox.max.y) do bbox.max.y = v.y;
            if (v.z > bbox.max.z) do bbox.max.z = v.z;
        }


        bbox_vertices := get_bbox_vertices(bbox)
        transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
            usage = sdl.GPUTransferBufferUsage.UPLOAD,
            size = u32(24*size_of(vec3)),
        }); assert(transfer_buffer != nil)
        node.bbox_vbo = create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.VERTEX}, bbox_vertices[:])
        sdl.ReleaseGPUTransferBuffer(gpu, transfer_buffer)
        node.aabb = bbox
    }

    if len(gl_node.children) == 0 do return
    children := make([]GLTFNode, len(gl_node.children))
    node.children = children
    for gl_child, i in gl_node.children {
        build_scene(gl_child, &node.children[i], gpu, copy_pass, meshes, transform)
    }
}

load_mesh :: proc(data: MeshData, gpu: ^sdl.GPUDevice, copy_pass: ^sdl.GPUCopyPass) -> GLTFMesh {
    mesh: GLTFMesh
    vert_count: uint = len(data.positions)
    index_count: uint = len(data.indices)
    len_bytes := vert_count*size_of(GLTFVertex) + index_count*size_of(u16)
    transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = u32(len_bytes),
    }); assert(transfer_buffer != nil)

    vertices := make([]GLTFVertex, len(data.positions))
    for i in 0..<len(data.positions) {
        vertices[i] = GLTFVertex {
            data.positions[i],
            data.normals[i],
            data.uvs[i],
            data.tangents[i]
        }
    }
    vbo := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.VERTEX}, vertices)
    assert(vbo != nil)
    ibo := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.INDEX}, data.indices)
    assert(ibo != nil)
    sdl.ReleaseGPUTransferBuffer(gpu, transfer_buffer)

    mesh.vbo = vbo
    mesh.ibo = ibo
    mesh.data = data
    return mesh
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
    if base_color_texture != {} do texture_count += 1
    metallic_roughness_tex := m.pbr_metallic_roughness.metallic_roughness_texture.texture
    metallic_roughness_texture = load_texture(metallic_roughness_tex, gpu, copy_pass)
    if metallic_roughness_texture != {} do texture_count += 1
    normal_map = load_texture(m.normal_texture.texture, gpu, copy_pass)
    if normal_map != {} do texture_count += 1

    return material
}

load_texture :: proc(t: ^gl.texture, gpu: ^sdl.GPUDevice, copy_pass: ^sdl.GPUCopyPass) -> GLTFTexture {
    if t == nil do return {}
    view := t.image_.buffer_view
    data_multiptr := cast([^]byte)view.buffer.data
    ptr := mem.ptr_offset(data_multiptr, view.offset)
    data: [^]byte = cast([^]byte)ptr
    size := i32(view.size)
    width, height: i32
    pixels := stbi.load_from_memory(data, size, &width, &height, nil, 4)
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
load_mesh_data :: proc(mesh: ^gl.mesh, gpu: ^sdl.GPUDevice, copy_pass: ^sdl.GPUCopyPass) -> MeshData {
    if mesh == nil do return {}
    positions:  [dynamic]vec3
    normals:    [dynamic]vec3
    tangents:   [dynamic]vec3
    uvs:        [dynamic]vec2
    indices:    [dynamic]u16
    primitives: [dynamic]GLTFPrimitive
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
                case .tangent:  load_buffer_from_accessor(accessor, &tangents)
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
    if tangents == nil do tangents = make([dynamic]vec3, len(positions))

    {
        positions := len(positions)
        assert(positions == len(normals))
        assert(positions == len(uvs))
        assert(positions == len(tangents))
    }
    data: MeshData
    data.positions = positions[:]
    data.normals = normals[:]
    data.uvs = uvs[:]
    data.tangents = tangents[:]
    data.indices = indices[:]
    data.primitives = primitives[:]
    return data
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