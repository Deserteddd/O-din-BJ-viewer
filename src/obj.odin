package obj_viewer

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:log"
import "core:time"
import "core:slice"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"

OBJObjectData :: struct {
    name:           string,
    vertices:       [dynamic]OBJVertex,
    materials:      []Material,
    texture_data:   TextureData
}

Material :: struct {
    Ka, Kd, Ks, Ke: vec3,
    Ns, Ni, d: f32,
    illum: uint,
}

OBJVertex :: struct {
    position: vec3,
    normal: vec3,
    uv: vec2,
    material: u32 // Index: 0 ..< number of materials , in order they appear in .mtl file
}

TextureData :: struct {
    names:     [dynamic]string,
    textures:  [dynamic][]u8,
    sizes:     [dynamic][2]i32
}

OBJModel :: struct {

}

print_obj :: proc(data: OBJObjectData, verbose := false) {
          fmt.println("-------------------- OBJObjectData --------------------")
    defer fmt.println("----------------------------------------------------")

    fmt.printfln("Vertices: {}", len(data.vertices))
    if verbose {
        fmt.printfln("Materials:")
        for mat, i in data.materials {
            fmt.printfln("\tMaterial {}", i)
            M := material_matrix(mat)
            for i in 0..<4 do fmt.printfln("\t\t{}", M[i])
        }
    } else do fmt.println("Material count:", len(data.materials))
    tex := data.texture_data
    if len(tex.sizes) == 0 do return
    fmt.println("Texture data:")
    for i in 0..<len(tex.sizes) {
        fmt.printfln("\tTexture: {}", tex.names[i])
        fmt.printfln("\tPointer: {}", tex.textures[i])
        fmt.printfln("\tSize:    {} x {}", tex.sizes[i].x, tex.sizes[i].y)
        if i != 2 do fmt.println()
    }

}

material_matrix :: proc(m: Material) -> [4]vec4 {
    return {
        to_vec4(m.Ka, m.Ns),
        to_vec4(m.Kd, m.Ni),
        to_vec4(m.Ks, m.d),
        to_vec4(m.Ke, f32(m.illum))
    }
}

delete_obj :: proc(data: OBJObjectData) {
    using data
    using texture_data
    assert(len(names) == len(sizes) && len(sizes) == len(textures))
    delete(vertices)
    delete(materials)
    for i in 0..<len(names) {
        delete(names[i])
    }
    delete(names)
    delete(textures)
    delete(sizes)
}

load_object :: proc(dir_path: string) -> OBJObjectData {
    defer free_all(context.temp_allocator)
    fmt.println("Loading:", dir_path)
    obj: OBJObjectData
    asset_handle, err := os.open(dir_path, 0, 0); assert(err == nil)
    dir_split: []string
    dir_split, err = strings.split(dir_path, "/", context.temp_allocator); assert(err == nil)
    obj.name = strings.clone(dir_split[len(dir_split)-1])
    asset_dir: []os.File_Info
    asset_dir, err = os.read_dir(asset_handle, 0); assert(err == nil)
    vertex_groups: [dynamic]OBJVertex

    materials: []Material
    material_names: []string
    texture_data: TextureData
    for file in asset_dir {
        if file.name[len(file.name)-3:] == "mtl" { // If this crashes, add a check for name length
            materials, material_names, texture_data = load_mtl(file.fullpath)
        }
    }
    obj.materials = materials
    obj.texture_data = texture_data

    for file in asset_dir {
        if line_len := len(file.name); line_len > 3 && file.name[line_len-3:] == "obj" {
            positions: [dynamic]vec3;    defer delete(positions)
            uvs: [dynamic]vec2;          defer delete(uvs)
            normals: [dynamic]vec3;      defer delete(normals)
            path := strings.concatenate({dir_path, "/", file.name[:line_len-4]}, context.temp_allocator)

            // Load materials
            obj_path := strings.concatenate({path, ".obj"}, context.temp_allocator)
            file, err := os.read_entire_file_or_err(obj_path); assert(err == nil); defer delete(file)
            line_arr := strings.split_lines(string(file)); defer delete(line_arr)
            start, i: int
            for line in line_arr {
                if len(line) < 2 do continue
                defer i += 1
                if line[0] == 'o' {
                    if start != 0 {
                        now := time.now()
                        new_obj := load_obj(line_arr[start:i], material_names, &positions, &uvs, &normals)
                        for v in new_obj do append(&obj.vertices, v)
                    }
                    start = i
                }
            }
            new_obj := load_obj(line_arr[start:i], material_names, &positions, &uvs, &normals)
            for v in new_obj do append(&obj.vertices, v)

        }
    }

    // fmt.printfln("Object loading took: {}", load_time)
    return obj
}


/* Loads materials from specified path along with their names.
    returns: 
        1. List of materials in the order they appear in file
        2. List of material names as they appear in the file
*/
@(private = "file")
load_mtl :: proc(mtl_path: string) -> ([]Material, []string, TextureData) {
    materials:      [dynamic]Material
    material_names: [dynamic]string;  defer assert(len(materials) == len(material_names))
    tex_data: TextureData

    defer { for s, i in tex_data.names {
        if s != ""  do assert(tex_data.textures[i] != nil)
        else        do assert(tex_data.textures[i] == nil)
    }}

    file, err := os.read_entire_file_or_err(mtl_path)
    if err != nil { log.warnf("COULDN'T FIND MTL FILE {}", mtl_path); return nil, nil, {} }
    file_data := string(file)
    mat: Material
    mat_name: string
    for line in strings.split_lines_iterator(&file_data) {
        // fmt.println(line)
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
            case "ma":
                path_split := strings.split_after(mtl_path, "\\");
                extension_split := strings.split(line[7:], "\\")
                tex_path_base := strings.concatenate(path_split[:len(path_split)-1])
                tex_path_extension: string
                for s in extension_split {
                    if s != "" do tex_path_extension = strings.concatenate({tex_path_extension, "\\", s})
                }
                tex_path := strings.concatenate({tex_path_base, tex_path_extension[1:]})
                tex_index := new_texture(tex_path, &tex_data)
                switch line[4:6] {
                    case "Ka":
                        if tex_index >= 0 do mat.Ka.xy = {-1, tex_index}
                    case "Kd":
                        if tex_index >= 0 do mat.Kd.xy = {-1, tex_index}
                    case "Ks":
                        if tex_index >= 0 do mat.Ks.xy = {-1, tex_index}
                    case "Ke":
                        if tex_index >= 0 do mat.Ke.xy = {-1, tex_index}
                }
        }
    }
    append(&materials, mat)
    append(&material_names, mat_name)
    return materials[:], material_names[:], tex_data
}

// returns: index to texture/sampler that should be bound to the material field. -1 if the there is no space for a new textures
@(private="file")
new_texture :: proc(tex_path: string, data: ^TextureData) -> f32 {
    tex_path_cstring := strings.clone_to_cstring(tex_path, context.temp_allocator); 
    path_split       := strings.split(tex_path, "/");
    tex_name         := strings.clone(path_split[len(path_split)-1])
    i: int
    for i = 0; i<len(data.textures); i += 1 {
        if data.textures[i] == nil do break
        assert(data.sizes[i] != {}); assert(data.names[i] != "")
    }

    // If texture is loaded, we return the index of it
    for name, j in data.names {
        if name == tex_name {
            delete(tex_name)
            return f32(j)
        }
    }

    // At this point we know there is no space for new textures, and it doesn't exist in our texture collection
    if i == 4 do return -1

    size: [2]i32
    pixel_data := stbi.load(tex_path_cstring, &size.x, &size.y, nil, 4)
    if pixel_data == nil do pixel_data = stbi.load("assets/err_tex.jpg", &size.x, &size.y, nil, 4)
    append(&data.textures, slice.bytes_from_ptr(pixel_data, int(size.x * size.y * 4)))
    append(&data.names   , tex_name)
    append(&data.sizes   , size)
    return f32(i)
}


@(private = "file")
load_obj :: proc(obj_data: []string, mat_names: []string, 
    positions: ^[dynamic]vec3, uvs: ^[dynamic]vec2, normals: ^[dynamic]vec3,
) -> []OBJVertex {
    data: OBJObjectData
    vertex_count: u32
    for line in obj_data {
        assert(len(line)>=2)
        if line[0] == 'f' do vertex_count += 3
    }
    vertices := make([]OBJVertex, vertex_count);
    current_material: u32 = 0
    vertex_index: uint
    for line in obj_data {
        switch line[0:2] {
            case "v ":
                append(positions, parse_vec3(line, 2))
            case "vt":
                append(uvs, parse_vec2(line))
            case "vn":
                append(normals, parse_vec3(line, 3))
            case "f ":
                defer vertex_index += 3
                face := parse_face_data(line)
                vertices[vertex_index] = OBJVertex {
                    position = positions[face[0]],
                    uv       = {uvs[face[1]].x, 1-uvs[face[1]].y},
                    normal   = normals[face[2]],
                    material = current_material
                }
                vertices[vertex_index+1] = OBJVertex {
                    position = positions[face[3]],
                    uv       = {uvs[face[4]].x, 1-uvs[face[4]].y},
                    normal   = normals[face[5]],
                    material = current_material
                }
                vertices[vertex_index+2] = OBJVertex {
                    position = positions[face[6]],
                    uv       = {uvs[face[7]].x, 1-uvs[face[7]].y},
                    normal   = normals[face[8]],
                    material = current_material
                }
            case "us": // Switch material
                for name, i in mat_names {
                    if name == line[7:] {
                        current_material = u32(i)
                        break
                    }
                }
        }
    }
    return vertices
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
    errors: bool
    for i in 2..<len(line) {
        if !(rune(line[i]) >= '0' && rune(line[i]) <= '9')  {
            num, ok := strconv.parse_int(line[start:i])
            if !ok {
                errors = true
                data[n] = 0
            } else {
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