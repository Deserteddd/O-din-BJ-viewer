package obj_viewer

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"

load_obj :: proc(path: string) -> (ObjectData, bool) {
    path_split := strings.split(path, "."); defer delete(path_split)
    extension := path_split[len(path_split)-1] 
    if extension != "obj" {
        fmt.printfln("Invalid file extension: {}", extension)
        return ({}), false
    }
    fmt.printfln("LOADING OBJ: {}", path)
    file, err := os.read_entire_file_or_err(path); assert(err == nil); defer delete(file)
    data := string(file);

    positions: [dynamic]vec3; defer delete(positions)
    normals: [dynamic]vec3; defer delete(normals)
    face_data: [dynamic][9]u32; defer delete(face_data)


    for line in strings.split_lines_iterator(&data) {
        if len(line) < 2 do continue
        switch line[0:2] {
            case "v ":
                append(&positions, parse_vec3(line, 2))
            case "f ":
                data, ok := parse_face_data(line)
                if !ok do return {}, false
                append(&face_data, data)
            case "vn":
                append(&normals, parse_vec3(line, 3))
        }
    }
    vertices := make([]Vertex, len(positions));
    indices := make([]u32, len(face_data) * 3);

    for face, i in face_data {
        i := i*3
        vertices[face[0]].position = positions[face[0]]
        vertices[face[0]].normal = normals[face[2]]
        indices[i] = face[0]

        vertices[face[3]].position = positions[face[3]]
        vertices[face[3]].normal = normals[face[5]]
        indices[i+1] = face[3]

        vertices[face[6]].position = positions[face[6]]
        vertices[face[6]].normal = normals[face[8]]
        indices[i+2] = face[6]
    }
    return (ObjectData {
        vertices = vertices,
        indices = indices,
    }), true
}

parse_vec3 :: proc(line: string, start: int) -> vec3 {
    data: vec3
    start := start
    n := 0
    for i in start..<len(line) {
        if line[i] == 32 {
            data[n] = strconv.parse_f32(line[start:i]) or_else panic("parse_vec3 error")
            n += 1
            start = i+1
        }
    }
    data[n] = strconv.parse_f32(line[start:]) or_else panic("parse_vec3 error")
    
    return data
}

parse_face_data :: proc(line: string) -> ([9]u32, bool) {
    data: [9]u32;
    start := 2
    n := 0
    for i in 2..<len(line) {
        if !(rune(line[i]) >= '0' && rune(line[i]) <= '9')  {
            num, ok := strconv.parse_int(line[start:i])
            if !ok || n > 8 do return data, false
            data[n] = u32(num)-1
            n += 1
            start = i+1
        }
    }
    num, ok := strconv.parse_int(line[start:])
    if !ok do return data, false
    data[n] = u32(num)-1

    return data, ok
}