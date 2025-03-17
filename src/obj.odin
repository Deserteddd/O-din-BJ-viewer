package obj_viewer

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:log"
import stbi "vendor:stb/image"

ObjectData :: struct {
    name: string,
    vertices: []Vertex3,
    indices: []u32,
    material: Material
}

Material :: struct {
    Ka, Kd, Ks, Ke: vec3,
    Ns, Ni, d: f32,
    illum: uint
}

destroy_obj :: proc(data: ObjectData) {
    delete(data.name)
    delete(data.vertices)
    delete(data.indices)
}

print_obj :: proc(data: ObjectData) {
    fmt.println("Object:", data.name)
    fmt.println("Vertex count:", len(data.vertices))
    fmt.println("Index count:", len(data.indices))
    if data.material != {} {
        fmt.println("Ns:", data.material.Ns)
        fmt.println("Ka:", data.material.Ka)
        fmt.println("Kd:", data.material.Kd)
        fmt.println("Ks:", data.material.Ks)
        fmt.println("Ke:", data.material.Ke)
        fmt.println("Ni:", data.material.Ni)
        fmt.println("d:", data.material.d)
        fmt.println("illum:", data.material.illum)
    }
    fmt.println()
}

@(private = "file")
load_mtl :: proc(mtl_path: string) -> Material {
    mat: Material
    file, err := os.read_entire_file_or_err(mtl_path); //defer delete(file)
    if err != nil {
        log.warnf("COULDN'T FIND MTL FILE {}", mtl_path)
        return mat
    }
    file_data := string(file)
    for line in strings.split_lines_iterator(&file_data) {
        if len(line) == 0 do continue
        switch line[0:2] {
            case "Ns":
                Ns, ok := strconv.parse_f32(line[3:]); assert(ok)
                mat.Ns = Ns
            case "Ka":
                mat.Ka = parse_vec3(line, 3)
            case "Kd":
                mat.Kd = parse_vec3(line, 3)
            case "Ks":
                mat.Ks = parse_vec3(line, 3)
            case "Ke":
                mat.Ke = parse_vec3(line, 3)
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

    return mat
}

load_obj :: proc(obj_path: string) -> ObjectData {
    fmt.println("Loading:", obj_path)
    file, err := os.read_entire_file_or_err(obj_path); assert(err == nil); defer delete(file)
    mtl_path := strings.concatenate({obj_path[:len(obj_path)-3], "mtl"});  defer delete(mtl_path)
    material: Material
    material = load_mtl(mtl_path)
    file_data := string(file)
    positions: [dynamic]vec3;    defer delete(positions)
    uvs: [dynamic]vec2;          defer delete(uvs)
    normals: [dynamic]vec3;      defer delete(normals)
    face_data: [dynamic][9]u32;  defer delete(face_data)
    name: string
    i, n := 0, 0
    for line in strings.split_lines_iterator(&file_data) {
        switch line[0:2] {
            case "o ":
                name = strings.clone(line[2:])
            case "v ":
                append(&positions, parse_vec3(line, 2))
            case "vt":
                append(&uvs, parse_vec2(line))
            case "vn":
                append(&normals, parse_vec3(line, 3))
            case "f ":
                append(&face_data, parse_face_data(line))
        }
    }
    vertices := make([]Vertex3, len(positions));
    indices := make([]u32, len(face_data) * 3);
    for face, i in face_data {
        i := i*3
        vertices[face[0]].position = positions[face[0]]
        vertices[face[0]].uv.x = uvs[face[1]].x
        vertices[face[0]].uv.y = 1-uvs[face[1]].y
        vertices[face[0]].normal = normals[face[2]]
        indices[i] = face[0]

        vertices[face[3]].position = positions[face[3]]
        vertices[face[3]].uv.x = uvs[face[4]].x
        vertices[face[3]].uv.y = 1-uvs[face[4]].y
        vertices[face[3]].normal = normals[face[5]]
        indices[i+1] = face[3]

        vertices[face[6]].position = positions[face[6]]
        vertices[face[6]].uv.x = uvs[face[7]].x
        vertices[face[6]].uv.y = 1-uvs[face[7]].y
        vertices[face[6]].normal = normals[face[8]]
        indices[i+2] = face[6]
    }
    data := ObjectData { 
        name = name,
        vertices = vertices[:], 
        indices = indices[:],
        material = material
    }
    print_obj(data)
    return data
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