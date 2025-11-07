package obj_viewer

import "core:os"
import "core:strings"
import "core:strconv"
import "core:log"
import "core:fmt"
import sdl "vendor:sdl3"

OBJModel :: struct {
    name:               string,
    vbo:                ^sdl.GPUBuffer,
    material_buffer:    ^sdl.GPUBuffer,
    aabbs:              []AABB,
    aabb_vbos:          []^sdl.GPUBuffer,
    textures:           []Texture,
    primitives:         []OBJPrimitive,
    materials:          []OBJMaterial
}

OBJMaterial :: struct {
    name:               string,
    diffuse_color:      vec3,
    has_diff_map:       b32,
    specular_color:     vec3,
    has_spec_map:       b32,
    specular_factor:    f32,
    diffuse_map:        ^Texture,
    specular_map:       ^Texture

}

MaterialUBO :: struct {
    diffuse_color:      vec3,
    has_diff_map:       b32,
    specular_color:     vec3,
    has_specular_map:   b32,
    specular_factor:    f32,
}

OBJVertex :: struct {
    position: vec3,
    normal: vec3,
    uv: vec2,
}

Texture :: struct {
    path:    string,
    texture: ^sdl.GPUTexture,
    sampler: ^sdl.GPUSampler
}

OBJPrimitive :: struct {
    start, end, material: u32,
}

delete_obj :: proc(model: OBJModel) {
    panic("Not implemented")
}

load_obj_model :: proc(dir_path: string, gpu: ^sdl.GPUDevice) -> OBJModel {
    fmt.println("Loading:", dir_path)
    defer free_all(context.temp_allocator)
    asset_handle, err := os.open(dir_path, 0, 0); assert(err == nil)
    dir_split: []string
    dir_split, err = strings.split(dir_path, "/", context.temp_allocator); assert(err == nil)
    asset_dir: []os.File_Info
    asset_dir, err = os.read_dir(asset_handle, 0, context.temp_allocator); assert(err == nil)

    materials: []OBJMaterial
    textures:  []Texture
    cmd_buf   := sdl.AcquireGPUCommandBuffer(gpu); assert(cmd_buf != nil)
    defer {ok := sdl.SubmitGPUCommandBuffer(cmd_buf); assert(ok)}
    copy_pass := sdl.BeginGPUCopyPass(cmd_buf); assert(copy_pass != nil)
    defer sdl.EndGPUCopyPass(copy_pass)
    for file in asset_dir {
        if len(file.name) < 5 do continue
        if file.name[len(file.name)-3:] == "mtl" { // If this crashes, add a check for name length
            materials, textures = load_mtl(file.fullpath, gpu, copy_pass)
            break
        }
    }

    vertices:   []OBJVertex; defer delete(vertices)
    primitives: []OBJPrimitive
    for file in asset_dir {
        if line_len := len(file.name); line_len > 3 && file.name[line_len-3:] == "obj" {
            vertices, primitives = load_obj(file.fullpath, materials)
        }
    }

    material_ubos := make([]MaterialUBO, len(materials))
    defer delete(material_ubos)
    for material, i in materials {
        material_ubos[i] = MaterialUBO {
            diffuse_color = material.diffuse_color,
            has_diff_map = material.has_diff_map,
            specular_color = material.specular_color,
            has_specular_map = material.has_spec_map,
            specular_factor = material.specular_factor
        }
    }


    len_bytes := u32(len(vertices) * size_of(OBJVertex) + len(materials) * size_of(MaterialUBO))
    transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
        usage = .UPLOAD,
        size  = len_bytes
    }); assert(transfer_buffer != nil)
    defer sdl.ReleaseGPUTransferBuffer(gpu, transfer_buffer)
    vbo              := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.VERTEX}, vertices)
    material_buffer  := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.GRAPHICS_STORAGE_READ}, material_ubos)
    assert(vbo != nil); assert(material_buffer != nil)


    model: OBJModel
    model.name              = strings.clone(dir_split[len(dir_split)-1])
    model.materials         = materials
    model.primitives        = primitives
    model.textures          = textures
    model.vbo               = vbo
    model.material_buffer   = material_buffer
    return model
}



@(private = "file")
load_obj :: proc(obj_path: string, materials: []OBJMaterial) -> ([]OBJVertex, []OBJPrimitive) {
    file_data_1 := read_file_to_string(obj_path)
    vertices:   [dynamic]OBJVertex
    primitives: [dynamic]OBJPrimitive

    positions: [dynamic]vec3; defer delete(positions)
    uvs:       [dynamic]vec2; defer delete(uvs)
    normals:   [dynamic]vec3; defer delete(normals)
    vertex_index: u32
    start, end: u32
    primitive: OBJPrimitive
    first_primitive := true
    aabb: AABB
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
                defer vertex_index += 3
                face := parse_face_data(line)
                append(&vertices, OBJVertex {
                    position = positions[face[0]],
                    uv       = {uvs[face[1]].x, 1-uvs[face[1]].y},
                    normal   = normals[face[2]],
                })
                append(&vertices, OBJVertex {
                    position = positions[face[3]],
                    uv       = {uvs[face[4]].x, 1-uvs[face[4]].y},
                    normal   = normals[face[5]],
                })
                append(&vertices, OBJVertex {
                    position = positions[face[6]],
                    uv       = {uvs[face[7]].x, 1-uvs[face[7]].y},
                    normal   = normals[face[8]],
                })
            case "us":
                if first_primitive {
                    for &mat, i in materials {
                        if mat.name == line[7:] do primitive.material = u32(i)
                        break
                    }
                    first_primitive = false
                } else {
                    for &mat, i in materials {
                        if mat.name == line[7:] {
                            primitive.end = vertex_index
                            append(&primitives, primitive)
                            primitive.material = u32(i)
                            primitive.start = vertex_index
                            break
                        }
                    }

                }
        }
    }
    primitive.end = vertex_index
    append(&primitives, primitive)

    return vertices[:], primitives[:]
}

@(private = "file")
load_mtl :: proc(
    mtl_path: string, 
    gpu: ^sdl.GPUDevice, 
    copy_pass: ^sdl.GPUCopyPass
) -> ([]OBJMaterial, []Texture) {
    materials: [dynamic]OBJMaterial
    textures:  [dynamic]Texture
    file_data := read_file_to_string(mtl_path)
    material: OBJMaterial
    started: bool
    for line in strings.split_lines_iterator(&file_data) {
        if line == "" {
            if !started do continue
            append(&materials, material)
            material = {}
            continue
        }
        switch line[0:2] {
            case "Kd":
                material.diffuse_color = parse_vec3(line, 3)
            case "Ks":
                material.specular_color = parse_vec3(line, 3)
            case "ma":
                tex_path := line[7:]
                texture: ^Texture
                found: bool
                for &tex in textures {
                    if tex.path == tex_path {
                        texture = &tex
                        found = true
                    }
                }
                if !found {
                    pixels, size := load_pixels(tex_path)
                    tex := upload_texture(gpu, copy_pass, pixels, {u32(size.x), u32(size.y)})
                    free_pixels(pixels)
                    sampler := sdl.CreateGPUSampler(gpu, {}); assert(sampler != nil)
                    append(&textures,  Texture {
                        path = strings.clone(tex_path),
                        texture = tex,
                        sampler = sampler
                    })
                    texture = &textures[len(textures)-1]
                }
                switch line[4:6] {
                    case "Kd":
                        material.has_diff_map = true
                        material.diffuse_map = texture
                    case "Ks":
                        material.has_spec_map = true
                        material.specular_map = texture
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