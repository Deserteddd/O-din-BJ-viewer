package obj_viewer

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:log"
import "core:slice"
import stbi "vendor:stb/image"

OBJObjectData :: struct {
    name:           string,
    vertex_groups:  [dynamic][]OBJVertex,
    materials:      []OBJMaterial,
    textures:       []Texture
}

OBJMaterial :: struct {
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

Texture:: struct {
    name:      string,
    image:     []u8,
    size:      [2]i32
}

material_matrix :: proc(m: OBJMaterial) -> [4]vec4 {
    return {
        to_vec4(m.Ka, m.Ns),
        to_vec4(m.Kd, m.Ni),
        to_vec4(m.Ks, m.d),
        to_vec4(m.Ke, f32(m.illum))
    }
}

delete_obj :: proc(data: OBJObjectData) {
    using data
    for group in vertex_groups {
        delete(group)
    }
    delete(vertex_groups)
    delete(materials)
    for texture in textures {
        free_pixels(texture.image)
        delete(texture.name)
    }
}

load_obj_object :: proc(dir_path: string) -> OBJObjectData {
    fmt.println("Loading:", dir_path)
    obj: OBJObjectData
    asset_handle, err := os.open(dir_path, 0, 0); assert(err == nil)
    dir_split: []string
    dir_split, err = strings.split(dir_path, "/", context.temp_allocator); assert(err == nil)
    obj.name = strings.clone(dir_split[len(dir_split)-1])
    asset_dir: []os.File_Info
    asset_dir, err = os.read_dir(asset_handle, 0, context.temp_allocator); assert(err == nil)
    vertex_groups: [dynamic]OBJVertex

    materials: []OBJMaterial
    material_names: []string
    textures: []Texture
    for file in asset_dir {
        if file.name[len(file.name)-3:] == "mtl" { // If this crashes, add a check for name length
            materials, material_names, textures = load_mtl(file.fullpath)
            break
        }
    }
    obj.materials = materials
    obj.textures = textures

    for file in asset_dir {
        if line_len := len(file.name); line_len > 3 && file.name[line_len-3:] == "obj" {
            positions: [dynamic]vec3;    defer delete(positions)
            uvs: [dynamic]vec2;          defer delete(uvs)
            normals: [dynamic]vec3;      defer delete(normals)
            path := strings.concatenate({dir_path, "/", file.name[:line_len-4]}, context.temp_allocator)

            // Load materials
            obj_path := strings.concatenate({path, ".obj"}, context.temp_allocator)
            file_content, read_err := os.read_entire_file_or_err(obj_path, context.temp_allocator)
            assert(read_err == nil)
            line_arr := strings.split_lines(string(file_content), context.temp_allocator)
            start, i: int
            for line in line_arr {
                if len(line) < 2 do continue
                defer i += 1
                if line[0] == 'o' {
                    if start != 0 {
                        new_obj := load_obj(line_arr[start:i], material_names, &positions, &uvs, &normals)
                        append(&obj.vertex_groups, new_obj)
                    }
                    start = i
                }
            }
            new_obj := load_obj(line_arr[start:i], material_names, &positions, &uvs, &normals)
            append(&obj.vertex_groups, new_obj)
            break
        }
    }
    free_all(context.temp_allocator)
    return obj
}


/* Loads materials from specified path along with their names.
    returns: 
        1. List of materials in the order they appear in file
        2. List of material names as they appear in the file
*/
@(private = "file")
load_mtl :: proc(mtl_path: string) -> ([]OBJMaterial, []string, []Texture) {
    materials:      [dynamic]OBJMaterial
    material_names: [dynamic]string;  defer assert(len(materials) == len(material_names))
    textures:       [dynamic]Texture

    defer { for tex, i in textures {
        if tex.name != ""  do assert(textures[i].image != nil)
        else        do assert(textures[i].image == nil)
    }}

    file, err := os.read_entire_file_or_err(mtl_path)
    if err != nil { log.warnf("COULDN'T FIND MTL FILE {}", mtl_path); return nil, nil, {} }
    file_data := string(file)
    mat: OBJMaterial
    mat_name: string
    for line in strings.split_lines_iterator(&file_data) {
        if len(line) == 0 do continue
        if len(line) > 7  && line[:6] == "newmtl"{
            new_name := strings.clone(line[7:])
            if mat_name != "" {
                append(&materials, mat)
                name := mat_name
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
                tex_index := new_texture(tex_path, &textures)
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
    return materials[:], material_names[:], textures[:]
}

// returns: index to texture/sampler that should be bound to the material field. -1 if the there is no space for a new textures
@(private="file")
new_texture :: proc(tex_path: string, textures: ^[dynamic]Texture) -> f32 {
    tex_path_cstring := strings.clone_to_cstring(tex_path, context.temp_allocator); 
    path_split       := strings.split(tex_path, "/");
    tex_name         := strings.clone(path_split[len(path_split)-1])
    i: int

    // If texture is loaded, we return the index of it
    for texture, j in textures {
        if texture.name == tex_name {
            delete(tex_name)
            return f32(j)
        }
    }

    // At this point we know there is no space for new textures, and it doesn't exist in our texture collection
    if i == 4 do return -1

    pixels, size := load_pixels(tex_path)
    if pixels == nil {
        pixels, size = load_pixels("assets/err_tex.jpg")
    }
    texture: Texture = {
        name = tex_name,
        image = pixels,
        size = size
    }
    append(textures, texture)

    return f32(i)
}


@(private = "file")
load_obj :: proc(obj_data: []string, mat_names: []string, 
    positions: ^[dynamic]vec3, uvs: ^[dynamic]vec2, normals: ^[dynamic]vec3,
) -> []OBJVertex {
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