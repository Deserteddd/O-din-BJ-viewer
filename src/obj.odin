package obj_viewer

import "core:os"
import "core:strings"
import "core:slice"
import "core:strconv"
import "core:log"
import "core:fmt"
import sdl "vendor:sdl3"

OBJModel :: struct {
    name:               string,
    vbo:                ^sdl.GPUBuffer,
    material_buffer:    ^sdl.GPUBuffer,
    aabb_vbo:           ^sdl.GPUBuffer,
    aabbs:              []AABB,
    textures:           []Texture,
    materials:          []OBJMaterial,
    num_vertices:       u32
}

OBJMaterial :: struct {
    name:               string,
    diffuse_color:      vec3,
    diffuse_map:        i32,
    specular_color:     vec3,
    specular_map:       i32,
    specular_factor:    f32,
}

GPUMaterial :: struct {
    diffuse_color:      vec3,
    diffuse_map:        i32,
    specular_color:     vec3,
    specular_map:       i32,
    specular_factor:    f32,
    pad:                vec3,
}

OBJVertex :: struct {
    position: vec3,
    normal: vec3,
    uv: vec2,
    material: u32,
}

Texture :: struct {
    path:    string,
    texture: ^sdl.GPUTexture,
}

delete_obj :: proc(model: OBJModel) {
    panic("Not implemented")
}

load_obj_model :: proc(dir_path: string) -> OBJModel {
    fmt.println("Loading:", dir_path)
    defer free_all(context.temp_allocator)
    asset_handle, err := os.open(dir_path, 0, 0); assert(err == nil)
    dir_split: []string
    dir_split, err = strings.split(dir_path, "/", context.temp_allocator); assert(err == nil)
    asset_dir: []os.File_Info
    asset_dir, err = os.read_dir(asset_handle, 0, context.temp_allocator); assert(err == nil)

    materials: []OBJMaterial
    textures:  []Texture
    cmd_buf   := sdl.AcquireGPUCommandBuffer(g.gpu); assert(cmd_buf != nil)
    defer {ok := sdl.SubmitGPUCommandBuffer(cmd_buf); assert(ok)}
    copy_pass := sdl.BeginGPUCopyPass(cmd_buf); assert(copy_pass != nil)
    defer sdl.EndGPUCopyPass(copy_pass)
    for file in asset_dir {
        if len(file.name) < 5 do continue
        if file.name[len(file.name)-3:] == "mtl" { // If this crashes, add a check for name length
            materials, textures = load_mtl(file.fullpath, copy_pass)
            break
        }
    }
    vertices:   []OBJVertex; defer delete(vertices)
    aabbs:      []AABB
    for file in asset_dir {
        if line_len := len(file.name); line_len > 3 && file.name[line_len-3:] == "obj" {
            vertices, aabbs = load_obj(file.fullpath, materials)
        }
    }

    material_buffer_gpu := make([]GPUMaterial, len(materials))
    defer delete(material_buffer_gpu)
    for material, i in materials {
        material_buffer_gpu[i] = GPUMaterial {
            diffuse_color   = material.diffuse_color,
            diffuse_map     = material.diffuse_map,
            specular_color  = material.specular_color,
            specular_map    = material.specular_map,
            specular_factor = material.specular_factor
        }
    }

    aabb_verts: [dynamic]vec3; defer delete(aabb_verts)
    for aabb in aabbs {
        verts := get_bbox_vertices(aabb)
        for v in verts do append(&aabb_verts, v)
    }

    len_bytes := u32(
        len(vertices) * size_of(OBJVertex) + 
        len(materials) * size_of(GPUMaterial) +
        len(aabbs) * 24 * size_of(vec3)
    )
    transfer_buffer := sdl.CreateGPUTransferBuffer(g.gpu, {
        usage = .UPLOAD,
        size  = len_bytes
    }); assert(transfer_buffer != nil)
    defer sdl.ReleaseGPUTransferBuffer(g.gpu, transfer_buffer)
    vbo              := create_buffer_with_data(transfer_buffer, copy_pass, {.VERTEX}, vertices)
    material_buffer  := create_buffer_with_data(transfer_buffer, copy_pass, {.GRAPHICS_STORAGE_READ}, material_buffer_gpu)
    aabb_vbo         := create_buffer_with_data(transfer_buffer, copy_pass, {.VERTEX}, aabb_verts[:])
    assert(vbo != nil); assert(material_buffer != nil); assert(aabb_vbo != nil)


    model: OBJModel
    model.name              = strings.clone(dir_split[len(dir_split)-1])
    model.vbo               = vbo
    model.material_buffer   = material_buffer
    model.aabb_vbo          = aabb_vbo
    model.aabbs             = aabbs
    model.textures          = textures
    model.materials         = materials
    model.num_vertices      = u32(len(vertices))
    return model
}



@(private = "file")
load_obj :: proc(
    obj_path: string, 
    materials: []OBJMaterial
) -> ([]OBJVertex, []AABB) {
    file_data_1 := read_file_to_string(obj_path)
    vertices:   [dynamic]OBJVertex
    aabbs:      [dynamic]AABB

    positions: [dynamic]vec3; defer delete(positions)
    uvs:       [dynamic]vec2; defer delete(uvs)
    normals:   [dynamic]vec3; defer delete(normals)
    current_material: u32
    aabb := AABB {min = max(f32), max = min(f32)}
    first_aabb := true
    for line in strings.split_lines_iterator(&file_data_1) {
        if len(line) < 2 do continue
        switch line[0:2] {
            case "v ":
                append(&positions, parse_vec3(line, 2))
            case "vt":
                append(&uvs, parse_vec2(line))
            case "vn":
                append(&normals, parse_vec3(line, 3))
            case "f ":
                face := parse_face_data(line)
                new_verts := [3]OBJVertex {
                    OBJVertex {
                        position = positions[face[0]],
                        uv       = {uvs[face[1]].x, 1-uvs[face[1]].y},
                        normal   = normals[face[2]],
                        material = current_material
                    },
                    OBJVertex {
                        position = positions[face[3]],
                        uv       = {uvs[face[4]].x, 1-uvs[face[4]].y},
                        normal   = normals[face[5]],
                        material = current_material
                    },
                    OBJVertex {
                        position = positions[face[6]],
                        uv       = {uvs[face[7]].x, 1-uvs[face[7]].y},
                        normal   = normals[face[8]],
                        material = current_material
                    }
                }
                for vert in new_verts {
                    using vert
                    if (position.x < aabb.min.x) do aabb.min.x = position.x;
                    if (position.y < aabb.min.y) do aabb.min.y = position.y;
                    if (position.z < aabb.min.z) do aabb.min.z = position.z;
                    if (position.x > aabb.max.x) do aabb.max.x = position.x;
                    if (position.y > aabb.max.y) do aabb.max.y = position.y;
                    if (position.z > aabb.max.z) do aabb.max.z = position.z;
                    append(&vertices, vert)
                }
            case "us":
                for mat, i in materials {
                    if mat.name == line[7:] do current_material = u32(i)
                }
            case "o ":
                if !first_aabb {
                    append(&aabbs, aabb)
                    aabb = AABB {min = max(f32), max = min(f32)}
                } else do first_aabb = false

        }
    }

    append(&aabbs, aabb)

    return vertices[:], aabbs[:]
}

@(private = "file")
load_mtl :: proc(
    mtl_path: string, 
    copy_pass: ^sdl.GPUCopyPass
) -> ([]OBJMaterial, []Texture) {
    materials: [dynamic]OBJMaterial
    textures:  [dynamic]Texture
    file_data := read_file_to_string(mtl_path)
    material: OBJMaterial = {specular_map = -1, diffuse_map = -1}
    started: bool
    for line in strings.split_lines_iterator(&file_data) {
        if line == "" {
            if !started do continue
            append(&materials, material)
            material = {specular_map = -1, diffuse_map = -1}
            continue
        }
        switch line[0:2] {
            case "Kd":
                material.diffuse_color = parse_vec3(line, 3)
            case "Ks":
                material.specular_color = parse_vec3(line, 3)
            case "Ns":
                Ns, ok := strconv.parse_f32(line[3:]); assert(ok)
                material.specular_factor = Ns
            case "ma":
                tex_path := line[7:]
                tex_index: i32
                found: bool
                for &tex, i in textures {
                    if tex.path == tex_path {
                        tex_index = i32(i)
                        found = true
                        break
                    }
                }
                if !found {
                    if !strings.contains(tex_path, "\\") {
                        path_builder: strings.Builder
                        strings.builder_init(&path_builder, context.temp_allocator)
                        path_iter := mtl_path
                        i: int
                        for str in strings.split_iterator(&path_iter, "\\") {
                            if strings.contains(str, ".") do break
                            strings.write_string(&path_builder, str)
                            strings.write_rune(&path_builder, '\\')
                        }
                        strings.write_string(&path_builder, tex_path)
                        tex_path = strings.to_string(path_builder)
                    }
                    pixels, size := load_pixels(tex_path)
                    tex := upload_texture(copy_pass, pixels, {u32(size.x), u32(size.y)})
                    free_pixels(pixels)
                    append(&textures,  Texture {
                        path = strings.clone(tex_path),
                        texture = tex,
                    })
                    tex_index = i32(len(textures)-1)
                }
                switch line[4:6] {
                    case "Kd":
                        material.diffuse_map = tex_index
                    case "Ks":
                        material.specular_map = tex_index
                    case:
                        panic("Invalid texture binding")
                }
            case "ne":
                started = true
                material.name = line[7:]
        }
    }
    append(&materials, material)
    return materials[:], textures[:]
}

@(private = "file")
parse_vec2 :: proc(line: string) -> vec2 {
    data: vec2
    start: int
    ok := true
    for i in 3..<len(line) {
        if line[i] == 32 {
            data[0], ok = strconv.parse_f32(line[3:i]); assert(ok)
            start = i+1
            break
        }
    }
    data[1], ok = strconv.parse_f32(line[start:]); assert(ok)
    return data
}

@(private = "file")
parse_vec3 :: proc(line: string, start: int) -> vec3 {
    data: vec3
    start := start
    n := 0
    ok: bool 
    for i in start..<len(line) {
        if line[i] == 32 {
            data[n], ok = strconv.parse_f32(line[start:i]); assert(ok)
            n += 1
            start = i+1
        }
    }
    data[n], ok = strconv.parse_f32(line[start:]); assert(ok)
    return data
}

@(private = "file")
parse_face_data :: proc(line: string) -> [9]u32 {
    data: [9]u32;
    start := 2
    n := 0
    for i in 2..<len(line) {
        if !(rune(line[i]) >= '0' && rune(line[i]) <= '9')  {
            num, ok := strconv.parse_int(line[start:i])
            if !ok {
                data[n] = 0
            } else {
                if n >= len(line) do panic("Mesh must be triangulated")
                data[n] = u32(num)-1
            }
            n += 1
            start = i+1
        }
    }
    num, ok := strconv.parse_int(line[start:]); assert(ok)
    data[n] = u32(num)-1
    return data
}

@(private = "file")
read_file_to_string :: proc(path: string) -> string {
    file, err := os.read_entire_file_or_err(path, context.temp_allocator)
    if err != nil { log.warnf("COULDN'T FIND FILE {}", path); panic("") }
    file_data := string(file)
    return file_data
}