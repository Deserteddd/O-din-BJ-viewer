package obj_viewer
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:strings"
import "core:os"
import "core:encoding/json"


import sdl "vendor:sdl3"

vec2 :: [2]f32
vec3 :: [3]f32
vec4 :: [4]f32
mat4 :: matrix[4,4]f32

TRANSFORM_IDENTITY :: Transform {
    translation = 0,
    scale = 1,
    rotation = 0
}

HeightMap :: struct {
    scale:          vec3,
    num_indices:    u32,
    vbo:            ^sdl.GPUBuffer,
    ibo:            ^sdl.GPUBuffer,
}

HeightMapVertex :: struct {
    position, color: vec3,
}

ModelFormat :: enum {
    OBJ,
    GLTF
}

AssetInstance :: struct {
    asset:    string,
    position: [3]f32, // x, y, z
}

SaveFile :: struct {
    assets:    map[string]string,
    instances: []AssetInstance
}

load_save_file :: proc(path: string) -> SaveFile {
    json_filename := strings.concatenate({path, ".json"}, context.temp_allocator)
    json_data, ok := os.read_entire_file_from_filename(json_filename, context.temp_allocator)
    assert(ok)

    result: SaveFile
    err := json.unmarshal(json_data, &result)
    assert(err == nil)

    return result
}

free_save_file :: proc(savefile: SaveFile) {
    delete(savefile.assets)
    delete(savefile.instances)
}

load_height_map :: proc(path: string, renderer: Renderer) -> ^HeightMap {
    height_path  := strings.concatenate({path, "/height_map.png"})
    diffuse_path := strings.concatenate({path, "/diffuse.png"})
    pixels, size := load_height_map_pixels(height_path); defer free_pixels(pixels)
    colors, dsize := load_pixels(diffuse_path);          defer free_pixels(colors)
    assert(size == dsize)

    min: u16 = 1 << 15;
    for pixel in pixels {
        if pixel < min do min = pixel
    }

    vertices := make([]HeightMapVertex, size.x*size.y)
    defer delete(vertices)
    indices:  [dynamic]u32
    defer delete(indices)
    // First pass to add a vertex for every pixel
    for pixel, i in pixels {
        row := i32(i) / size.x
        col := i32(i) % size.x
        x := f32(row-size.x/2)
        y := f32(col-size.y/2)
        height := f32(pixel-min)
        vert := HeightMapVertex {
            position = {x, height, y},
            color = get_pixel_color(colors, row, col, size.x)
        }
        vertices[i] = vert
    }
    assert(i32(len(vertices)) == size.x * size.y)

    // Second pass to create indices for a triangulated mesh
    for i in 0..<len(pixels) {
        if i32(i) % size.x == size.x - 1 do continue // Second to last column
        if i32(i) / size.x == size.y - 1 do break    // Second to last line
        this_idx := u32(i)
        r_idx    := u32(i+1)
        d_idx    := u32(i32(i)+size.x)
        rd_idx   := u32(i32(i)+size.x+1)
        append_elems(&indices, this_idx, r_idx, d_idx, d_idx, r_idx, rd_idx)
    }
    using renderer
    copy_commands := sdl.AcquireGPUCommandBuffer(gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)
    len_bytes := u32(len(vertices) * size_of(HeightMapVertex))
    transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = len_bytes,
    }); assert(transfer_buffer != nil)
    vbo := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.VERTEX}, vertices[:])
    ibo := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.INDEX}, indices[:])

    sdl.ReleaseGPUTransferBuffer(gpu, transfer_buffer)
    sdl.EndGPUCopyPass(copy_pass)
    ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)
    pipeline := create_render_pipeline(
        renderer,
        "heightmap.vert",
        "heightmap.frag",
        HeightMapVertex,
        {.FLOAT3, .FLOAT3},
        true,
    )
    height_map := new(HeightMap)
    height_map.num_indices  = u32(len(indices))
    height_map.vbo = vbo
    height_map.ibo = ibo
    return height_map
}

get_pixel_color :: proc(pixels: []byte, row, col: i32, width: i32) -> vec3 {
    index := (row * width + col) * 4

    r := f32(pixels[index + 0]) / 255.0
    g := f32(pixels[index + 1]) / 255.0
    b := f32(pixels[index + 2]) / 255.0

    return vec3{r, g, b}
}

get_bbox_vertices :: proc(bbox: AABB) -> [24]vec3 {
    using bbox
    return {
        vec3{min.x, min.y, min.z},
        vec3{max.x, min.y, min.z},

        vec3{max.x, max.y, min.z},
        vec3{min.x, max.y, min.z},

        vec3{min.x, min.y, min.z},
        vec3{min.x, min.y, max.z},

        vec3{max.x, min.y, max.z},
        vec3{min.x, min.y, max.z},

        vec3{max.x, max.y, max.z},
        vec3{min.x, max.y, max.z},

        vec3{max.x, min.y, max.z},
        vec3{max.x, min.y, min.z},

        vec3{max.x, max.y, min.z},
        vec3{max.x, max.y, max.z},

        vec3{min.x, max.y, min.z},
        vec3{min.x, max.y, max.z},
        
        // Vertical bars
        vec3{min.x, min.y, min.z},
        vec3{min.x, max.y, min.z},

        vec3{max.x, min.y, min.z},
        vec3{max.x, max.y, min.z},

        vec3{min.x, min.y, max.z},
        vec3{min.x, max.y, max.z},

        vec3{max.x, min.y, max.z},
        vec3{max.x, max.y, max.z},
    }
}

to_vec4 :: proc(v: vec3, f: f32) -> vec4 { return vec4{v.x, v.y, v.z, f} }

norm :: proc(v: vec3) -> f32 { return math.sqrt_f32(v.x*v.x + v.y*v.y + v.z*v.z) }

random_range :: proc(min: f32, max: f32) -> f32 {
    return rand.float32() * (max - min) + min
}


