package obj_viewer

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"

load_obj :: proc(path: string) -> Object {
    fmt.printfln("LOADING OBJ: {}", path)
    file, err := os.read_entire_file_or_err(path); assert(err == nil)
    defer delete(file)
    data := string(file)
    verticies: [dynamic]Vertex
    indices: [dynamic]u16
    loop: for line in strings.split_lines_iterator(&data) {
        switch line[0:2] {
            case "v ":
                append(&verticies, parse_v_pos(line))
            case "f ":
                parse_indices(line, &indices)
                // break loop
        }
    }
    return Object {
        mesh = {
            verts = verticies,
            indices = indices
        },
        position = {0, 0, -2},
    }
}

parse_v_pos :: proc(line: string) -> Vertex {
    coords: [3]f32
    start := 2
    num := 0
    for i in 2..<len(line) {
        if line[i] == 32 {
            pos, ok := strconv.parse_f32(line[start:i]); assert(ok)
            coords[num] = pos
            num += 1
            start = i+1
        }
    }
    coords[num] = strconv.parse_f32(line[start:]) or_else panic("parse_v_pos: Parse Error")
    
    return Vertex {
        x = coords[0],
        y = coords[1],
        z = coords[2],
    }
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