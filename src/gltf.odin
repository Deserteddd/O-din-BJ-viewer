package obj_viewer

import gl "vendor:cgltf"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"
import "core:log"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"

GLTFScene  :: struct {
    name:           string,
    root_nodes:     []GLTFNode,
    meshes:         []GLTFMesh,
    materials:      []GLTFMaterial,
    textures:       []GLTFTexture
}

MaterialBinding :: struct {
    gl_material:    ^gl.material,
    material:       ^GLTFMaterial
}

GLTFTexture :: struct {
    texture:        ^sdl.GPUTexture,
    sampler:        ^sdl.GPUSampler,
}

TextureBinding :: struct {
    gl_texture:     ^gl.texture,
    texture:        ^GLTFTexture
}

GLTFMesh :: struct {
    vbo:            ^sdl.GPUBuffer,
    ibo:            ^sdl.GPUBuffer,
    aabb:           AABB,
    data:           MeshData
}

GLTFPrimitive :: struct {
    start:          uint,
    end:            uint,
    material:       ^GLTFMaterial
}

GLTFMaterial :: struct {
    name: string,
	has_pbr_metallic_roughness:  bool,
	pbr_metallic_roughness:      PBRMetallicRoughness,
	normal_texture:              ^GLTFTexture,
	occlusion_texture:           ^GLTFTexture,
}

PBRMetallicRoughness :: struct {
    base_color_factor:          vec4,
    metallic_factor:            f32,
    roughness_factor:           f32,
    base_color_texture:         ^GLTFTexture,
    metallic_roughness_texture: ^GLTFTexture
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
    position:   vec3,
    normal:     vec3,
    uv:         vec2,
    tangent:    vec3
}

GLTFNode :: struct {
    mesh:       ^GLTFMesh,
    children:   []GLTFNode,
    transform:  Transform,
    bbox_vbo:   ^sdl.GPUBuffer,
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



load_gltf_scene :: proc(path: string, gpu: ^sdl.GPUDevice) -> GLTFScene {
    start := time.now()
    path_cstr := strings.clone_to_cstring(path, context.temp_allocator)
    gltf_data := parse_file(path_cstr); defer gl.free(gltf_data)
    assert(len(gltf_data.buffers) == 1)
    name: string
    {
        dir_split, err := strings.split(path, "/", context.temp_allocator); assert(err == nil)
        name = strings.clone(dir_split[len(dir_split)-1])
        if strings.contains(name, ".") {
            dir_split, err = strings.split(name, ".", context.temp_allocator); assert(err == nil)
            name = strings.clone(dir_split[0])
        }
    }

    meshes: [dynamic]GLTFMesh
    fmt.println(path)
    copy_commands := sdl.AcquireGPUCommandBuffer(gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)

    textures := make([]GLTFTexture, len(gltf_data.textures))
    texture_bindings := load_textures(gltf_data.textures, textures, gpu, copy_pass)
    defer delete(texture_bindings)

    materials := make([]GLTFMaterial, len(gltf_data.materials))
    material_bindings := load_materials(gltf_data.materials, materials, texture_bindings, gpu, copy_pass)
    defer delete(material_bindings)
    assert(len(materials) > 0)
    
    nodes := make([]GLTFNode, len(gltf_data.scene.nodes))
    for i in 0..<len(nodes) {
        root: GLTFNode
        build_scene(gltf_data.scene.nodes[i], &root, gpu, copy_pass, &meshes, material_bindings)
        nodes[i] = root
    }

    sdl.EndGPUCopyPass(copy_pass)
    ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)
    fmt.println("gltf loader took", time.since(start))
    return GLTFScene {
        name,
        nodes,
        meshes[:],
        materials,
        textures
    }
}

load_textures :: proc(
    gl_textures: []gl.texture,
    textures:    []GLTFTexture,
    gpu:         ^sdl.GPUDevice,
    copy_pass:   ^sdl.GPUCopyPass
) -> []TextureBinding {
    assert(len(gl_textures) == len(textures))
    bindings := make([]TextureBinding, len(textures))
    for &t, i in gl_textures {
        sdl_texture := load_texture(&t, gpu, copy_pass); assert(sdl_texture != nil)
        sampler := sdl.CreateGPUSampler(gpu, {}); assert(sampler != nil)
        texture := GLTFTexture {
            texture = sdl_texture,
            sampler = sampler
        }
        textures[i] = texture
        bindings[i] = TextureBinding {
            gl_texture = &t,
            texture = &textures[i]
        }
    }
    return bindings
}

load_materials :: proc(
    gl_materials: []gl.material, 
    materials:    []GLTFMaterial,
    tex_bindings: []TextureBinding,
    gpu:          ^sdl.GPUDevice,
    copy_pass:    ^sdl.GPUCopyPass
) -> []MaterialBinding {
    assert(len(gl_materials) == len(materials))
    bindings := make([]MaterialBinding, len(materials))
    for &m, i in gl_materials {
        assert(bool(m.has_pbr_metallic_roughness))
        material: GLTFMaterial;
        material.name = strings.clone_from_cstring(m.name)
        material.has_pbr_metallic_roughness = bool(m.has_pbr_metallic_roughness)
        material.pbr_metallic_roughness = PBRMetallicRoughness {
            base_color_factor = m.pbr_metallic_roughness.base_color_factor,
            metallic_factor = m.pbr_metallic_roughness.metallic_factor,
            roughness_factor = m.pbr_metallic_roughness.roughness_factor,
        }
        for t in tex_bindings {
            if t.gl_texture == m.pbr_metallic_roughness.base_color_texture.texture {
                material.pbr_metallic_roughness.base_color_texture = t.texture
            }
            if t.gl_texture == m.pbr_metallic_roughness.metallic_roughness_texture.texture {
                material.pbr_metallic_roughness.metallic_roughness_texture = t.texture
            }
            if t.gl_texture == m.normal_texture.texture {
                material.normal_texture = t.texture
            }
            if t.gl_texture == m.occlusion_texture.texture {
                material.occlusion_texture = t.texture
            }
        }
        materials[i] = material
        bindings[i] = MaterialBinding {
            &m,
            &materials[i]
        }
    }
    return bindings
}

build_scene :: proc(
    gl_node: ^gl.node,
    node: ^GLTFNode, 
    gpu: ^sdl.GPUDevice, 
    copy_pass: ^sdl.GPUCopyPass,
    meshes: ^[dynamic]GLTFMesh,
    material_bindings: []MaterialBinding,
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

    mesh_data := load_mesh_data(gl_node.mesh, gpu, copy_pass, material_bindings)
    if len(mesh_data.primitives) != 0 {
        mesh := load_mesh(mesh_data, gpu, copy_pass)
        aabbs := load_aabbs(mesh_data.indices)
        append(meshes, mesh)
        node.mesh = &meshes[len(meshes)-1]
        bbox: AABB = {min = max(f32), max = min(f32)}
        for &v in mesh_data.positions {
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
        node.mesh.aabb = bbox
    }

    if len(gl_node.children) == 0 do return
    children := make([]GLTFNode, len(gl_node.children))
    node.children = children
    for gl_child, i in gl_node.children {
        build_scene(gl_child, &node.children[i], gpu, copy_pass, meshes, material_bindings, transform)
    }
}

load_aabbs :: proc(indices: []u16) -> []AABB {
    assert(len(indices)%3 == 0)
    aabb_count: int; defer fmt.println(aabb_count)
    tested_indices := make([]u16, len(indices))
    for i := 0; i < len(indices); i += 3 {
        new: bool
        for tested in tested_indices[0:i] {
            if tested != indices[i] && tested != indices[i+1] && tested != indices[i+2] {
                new = true
            }
        }
        if new do aabb_count += 1
        tested_indices[i] = indices[i]
        tested_indices[i+1] = indices[i+1]
        tested_indices[i+2] = indices[i+2]
    }
    return nil
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

load_texture :: proc(t: ^gl.texture, gpu: ^sdl.GPUDevice, copy_pass: ^sdl.GPUCopyPass) -> ^sdl.GPUTexture {
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
    sdl.ReleaseGPUTransferBuffer(gpu, tex_transfer_buffer)
    return texture
}

@(private = "file")
load_mesh_data :: proc(
    mesh: ^gl.mesh, 
    gpu: ^sdl.GPUDevice, 
    copy_pass: ^sdl.GPUCopyPass,
    material_bindings: []MaterialBinding
) -> MeshData {
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
        material: ^GLTFMaterial
        for mb in material_bindings {
            if mb.gl_material == primitive.material do material = mb.material
        }
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
        assert(positions % 3 == 0)
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