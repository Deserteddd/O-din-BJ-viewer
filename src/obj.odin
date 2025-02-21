package obj_viewer

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"

load_obj :: proc(path: string) -> Object {
    fmt.printfln("LOADING OBJ: {}", path)
    file, err := os.read_entire_file_or_err(path); assert(err == nil); defer delete(file)
    data := string(file)
    verticies: [dynamic]vec3
    indices: [dynamic]u16
    normals: [dynamic]vec3
    i := 0;
    for line in strings.split_lines_iterator(&data) {
        if len(line) < 2 do continue
        switch line[0:2] {
            case "v ":
                append(&verticies, parse_vec3(line, 2))
            case "f ":
                parse_indices(line, &indices)
            case "vn":
                append(&normals, parse_vec3(line, 3))
        }
    }
    return Object {
        data = {
            verts = verticies,
            indices = indices,
            normals = normals
        },
        position = {0, 0, -3},
    }
}

parse_vec3 :: proc(line: string, start: int) -> vec3 {
    vec: vec3
    start := start
    num := 0
    for i in start..<len(line) {
        if line[i] == 32 {
            pos, ok := strconv.parse_f32(line[start:i]); assert(ok)
            vec[num] = pos
            num += 1
            start = i+1
        }
    }
    vec[num] = strconv.parse_f32(line[start:]) or_else panic("parse_v_pos: Parse Error")
    
    return vec
}

parse_indices :: proc(line: string, indices: ^[dynamic]u16) {
    previous_was_space := true
    start := 2
    for i in 2..<len(line) {
        if line[i] == '/' && previous_was_space {
            index, ok := strconv.parse_uint(line[start:i])
            if !ok do fmt.printfln("failed to parse: '{}'", line[start:i])
            append(indices, u16(index-1))
            previous_was_space = false
        }
        if line[i] == ' ' {
            previous_was_space = true
            start = i+1
        } 
    }
}