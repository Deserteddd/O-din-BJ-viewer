package obj_viewer

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:log"
import "core:math/linalg"
import stbi "vendor:stb/image"

vec2 :: [2]f32
vec3 :: [3]f32
vec4 :: [4]f32

ObjectData :: struct {
    vertex_groups: [dynamic][]Vertex,
    materials: [][4]vec4,
}
Material :: struct {
    Ka, Kd, Ks, Ke: vec3,
    Ns, Ni, d: f32,
    illum: uint
}

Vertex :: struct {
    position: vec3,
    normal: vec3,
    uv: vec2,
    material: u32 // Index: 0 ..< number of materials , in order they appear in .mtl file
}

to_vec4 :: #force_inline proc(v: vec3, f: f32) -> vec4 {return vec4{v.x, v.y, v.z, f}}

material_matrix :: #force_inline proc(m: Material) -> [4]vec4 {
    mat: [4]vec4 = {
        to_vec4(m.Ka, m.Ns),
        to_vec4(m.Kd, m.Ni),
        to_vec4(m.Ks, m.d),
        to_vec4(m.Ke, f32(m.illum))
    }
    
    return mat
}

load_object :: proc(dir_path: string) -> ObjectData {
    defer free_all(context.temp_allocator)
    fmt.println("Loading:", dir_path)
    obj: ObjectData
    asset_handle, err := os.open(dir_path, 0, 0); assert(err == nil)
    asset_dir: []os.File_Info
    asset_dir, err = os.read_dir(asset_handle, 0, context.temp_allocator); assert(err == nil)
    vertex_groups: [dynamic]Vertex
    for file in asset_dir {
        if len := len(file.name); len > 3 && file.name[len-3:] == "obj"{
            positions: [dynamic]vec3;    defer delete(positions)
            uvs: [dynamic]vec2;          defer delete(uvs)
            normals: [dynamic]vec3;      defer delete(normals)
            path := strings.concatenate({dir_path, "/", file.name[:len-4]}, context.temp_allocator)
            materials, material_names := load_mtl( strings.concatenate({path, ".mtl"}, context.temp_allocator) )
            defer delete(material_names)
            obj.materials = materials
            obj_path := strings.concatenate({path, ".obj"}, context.temp_allocator)
            file, err := os.read_entire_file_or_err(obj_path); assert(err == nil); defer delete(file)
            src := string(file)
            line_arr: [dynamic]string
            for line in strings.split_lines_iterator(&src) do append(&line_arr, line)
            start, i: int
            for line in line_arr {
                defer i += 1
                if line[0] == 'o' {
                    if start != 0 {
                        append(&obj.vertex_groups, 
                            load_obj(line_arr[start:i], material_names, &positions, &uvs, &normals)
                        )
                    }
                    start = i
                }
            }
            append(&obj.vertex_groups, 
                load_obj(line_arr[start:i], material_names, &positions, &uvs, &normals)
            )
        }
    }
    return obj
}

@(private = "file")
load_mtl :: proc(mtl_path: string) -> ([][4]vec4, []string) {
    materials: [dynamic][4]vec4
    material_names: [dynamic]string
    assert(materials == nil)
    file, err := os.read_entire_file_or_err(mtl_path, context.temp_allocator)
    if err != nil {
        log.warnf("COULDN'T FIND MTL FILE {}", mtl_path)
        return nil, nil
    }
    file_data := string(file)
    mat: Material
    mat_name: string
    for line in strings.split_lines_iterator(&file_data) {
        if len(line) == 0 do continue
        if len(line) > 7  && line[:6] == "newmtl"{
            new_name := strings.clone(line[7:])
            if mat_name != "" {
                fmt.printfln("Append '{}': {}", mat_name, material_matrix(mat))
                append(&materials, material_matrix(mat))
                name := strings.clone(mat_name)
                append(&material_names, name)
            }
            mat_name = new_name
            mat = {}
        }
        switch line[0:2] {
            case "Ka":
                mat.Ka = parse_vec3(line, 3)
            case "Kd":
                mat.Kd = parse_vec3(line, 3)
            case "Ks":
                mat.Ks = parse_vec3(line, 3)
            case "Ke":
                mat.Ke = parse_vec3(line, 3)
            case "Ns":
                Ns, ok := strconv.parse_f32(line[3:]); assert(ok)
                mat.Ns = Ns
            case "Ni":
                Ni, ok := strconv.parse_f32(line[3:]); assert(ok)
                mat.Ni = Ni
            case "d ":
                d, ok := strconv.parse_f32(line[2:]); assert(ok)
                mat.d = d
            case "il":
                illum, ok := strconv.parse_uint(line[6:]); assert(ok)
                mat.illum = illum
        }
    }
    append(&materials, material_matrix(mat))
    append(&material_names, mat_name)
    return materials[:], material_names[:]
}

load_obj :: proc(obj_data: []string, mat_names: []string, 
    positions: ^[dynamic]vec3, uvs: ^[dynamic]vec2, normals: ^[dynamic]vec3,
) -> []Vertex {
    data: ObjectData

    vertices: [dynamic]Vertex;
    current_material: u32 = 0
    for line in obj_data {
        if len(line)<2 do panic("short line")
        switch line[0:2] {
            case "v ":
                append(positions, parse_vec3(line, 2))
            case "vt":
                append(uvs, parse_vec2(line))
            case "vn":
                append(normals, parse_vec3(line, 3))
            case "f ":
                face := parse_face_data(line)
                    append(&vertices, Vertex {
                        position = positions[face[0]],
                        uv       = {uvs[face[1]].x, 1-uvs[face[1]].y},
                        normal   = normals[face[2]],
                        material = current_material
                    })
                    append(&vertices, Vertex {
                        position = positions[face[3]],
                        uv       = {uvs[face[4]].x, 1-uvs[face[4]].y},
                        normal   = normals[face[5]],
                        material = current_material
                    })
                    append(&vertices, Vertex {
                        position = positions[face[6]],
                        uv       = {uvs[face[7]].x, 1-uvs[face[7]].y},
                        normal   = normals[face[8]],
                        material = current_material
                    })
            case "us": // Switch material
                for name, i in mat_names {
                    if name == line[7:] {
                        current_material = u32(i)
                    }
                }
        }
    }
    return vertices[:]
}

delete_obj :: proc(data: ObjectData) {
    for mesh in data.vertex_groups {
        delete(mesh)
    }
    delete(data.vertex_groups)
    delete(data.materials)
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
                fmt.println("Failed to parse:", line)
                panic("")
            }
            data[n] = u32(num)-1
            n += 1
            start = i+1
        }
    }
    num, ok := strconv.parse_int(line[start:]); assert(ok)
    data[n] = u32(num)-1
    return data
}