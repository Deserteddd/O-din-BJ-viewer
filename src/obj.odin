package obj_viewer

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:log"
import stbi "vendor:stb/image"

OBJFile :: struct {
    name: string,
    vertices: []Vertex3,
    indices: []u32,
    face_data: []u32,
    materials: []Material,
}

Material :: struct  {
    Ka, Kd, Ks, Ke: vec3,
    Ns, Ni, d: f32,
    illum: uint
}

mat_matrix :: proc(mat: Material) -> matrix[4,4]f32 {
    m: matrix[4,4]f32
    m[0] = {mat.Ka.x, mat.Ka.y, mat.Ka.z, 0}
    m[1] = {mat.Kd.x, mat.Kd.y, mat.Kd.z, 0}
    m[2] = {mat.Ks.x, mat.Ks.y, mat.Ks.z, 0}
    m[3] = {mat.Ke.x, mat.Ke.y, mat.Ke.z, 1}
    return m
}
// Material :: struct{
//     Ka: vec3,  pad1: f32,
//     Kd: vec3,  pad2: f32,
//     Ks: vec3,  pad3: f32,
//     Ke: vec3,  pad4: f32,
//     Ns, Ni, d: f32,
//     illum: uint,
// }

destroy_obj :: proc(data: OBJFile) {
    delete(data.name)
    delete(data.vertices)
    delete(data.indices)
    // delete(data.materials)
}

// print_obj :: proc(data: OBJFile) {
//     fmt.println("Object:", data.name)
//     fmt.println("Vertex count:", len(data.vertices))
//     fmt.println("Index count:", len(data.indices))
//     for _, data in data.materials {
//         if data != {} {
//             fmt.println("Ns:", data.Ns)
//             fmt.println("Ka:", data.Ka)
//             fmt.println("Kd:", data.Kd)
//             fmt.println("Ks:", data.Ks)
//             fmt.println("Ke:", data.Ke)
//             fmt.println("Ni:", data.Ni)
//             fmt.println("d:", data.d)
//             fmt.println("illum:", data.illum)
//         }
//         fmt.println()
//     }
// }

@(private = "file")
load_mtl :: proc(mtl_path: string) -> ([]Material, []string) {
    materials: [dynamic]Material
    material_names: [dynamic]string
    assert(materials == nil)
    file, err := os.read_entire_file_or_err(mtl_path); //defer delete(file)
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
                append(&materials, mat)
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
    append(&materials, mat)
    append(&material_names, mat_name)
    return materials[:], material_names[:]
}

ObjLoader :: struct {
    o: string,
    g: string
}

load_obj :: proc(obj_path: string) -> OBJFile {
    fmt.println("Loading:", obj_path)
    file, err := os.read_entire_file_or_err(obj_path); assert(err == nil); defer delete(file)
    mtl_path := strings.concatenate({obj_path[:len(obj_path)-3], "mtl"});  defer delete(mtl_path)
    materials, material_names := load_mtl(mtl_path); defer delete(material_names)
    file_data := string(file)
    positions: [dynamic]vec3;    defer delete(positions)
    uvs: [dynamic]vec2;          defer delete(uvs)
    normals: [dynamic]vec3;      defer delete(normals)
    raw_face_data: [dynamic][10]u32;  defer delete(raw_face_data)
    name: string
    i, n := 0, 0
    current_material: u32 = 0
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
                r := parse_face_data(line)
                augmented := [10]u32 {r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], current_material}
                append(&raw_face_data, augmented)
            case "us":
                for name, i in material_names {
                    if name == line[7:] {
                        current_material = u32(i)
                    }
                }
        }
    }
    vertices := make([]Vertex3, len(positions));
    indices := make([]u32, len(raw_face_data) * 3);
    face_data := make([]u32, len(raw_face_data));
    for face, i in raw_face_data {
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
        
        face_data[i/3] = face[9]
    }

    data := OBJFile { 
        vertices = vertices[:], 
        indices = indices[:],
        face_data = face_data[:],
        materials = materials[:],
    }
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