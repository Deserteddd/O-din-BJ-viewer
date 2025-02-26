package obj_viewer

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"

load_cube :: proc(model: ^Model) {
    file, err := os.read_entire_file_or_err("assets/cube.obj"); assert(err == nil); defer delete(file)
    vertices, indices := load_cubie(file)
    model.mesh.vertices = vertices[:]
    model.indices = indices[:]
}

load_cubie :: proc(file: []u8) -> ([]Vertex, []u32) {
    data := string(file);
    positions: [dynamic]vec3;    defer delete(positions)
    uvs: [dynamic]vec2;          defer delete(uvs)
    normals: [dynamic]vec3;      defer delete(normals)
    face_data: [dynamic][9]u32;  defer delete(face_data)
    i, n := 0, 0
    for line in strings.split_lines_iterator(&data) {
        switch line[0:2] {
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
    vertices := make([]Vertex, len(positions));
    indices := make([]u32, len(face_data) * 3);
    for face, i in face_data {
        i := i*3
        vertices[face[0]].position = positions[face[0]]
        vertices[face[0]].uv = uvs[face[1]]
        vertices[face[0]].normal = normals[face[2]]
        indices[i] = face[0]

        vertices[face[3]].position = positions[face[3]]
        vertices[face[3]].uv = uvs[face[4]]
        vertices[face[3]].normal = normals[face[5]]
        indices[i+1] = face[3]

        vertices[face[6]].position = positions[face[6]]
        vertices[face[6]].uv = uvs[face[7]]
        vertices[face[6]].normal = normals[face[8]]
        indices[i+2] = face[6]
    }

    return vertices, indices
}

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

parse_vec3 :: proc(line: string, start: int) -> vec3 {
    data: vec3
    start := start
    n := 0
    ok := true
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

parse_face_data :: proc(line: string) -> [9]u32 {
    data: [9]u32;
    start := 2
    n := 0
    for i in 2..<len(line) {
        if !(rune(line[i]) >= '0' && rune(line[i]) <= '9')  {
            num, ok := strconv.parse_int(line[start:i]); assert(ok)
            data[n] = u32(num)-1
            n += 1
            start = i+1
        }
    }
    num, ok := strconv.parse_int(line[start:]); assert(ok)
    data[n] = u32(num)-1
    return data
}