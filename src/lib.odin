package obj_viewer
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:strings"
import sdl "vendor:sdl3"

vec2 :: [2]f32
vec3 :: [3]f32
vec4 :: [4]f32
mat4 :: matrix[4,4]f32

TRANSFORM_IDENTITY :: Transform {
    translation = 0,
    scale = 1,
    rotation = linalg.QUATERNIONF32_IDENTITY
}

HeightMap :: struct {
    size:           [2]i32,
    vbo:            ^sdl.GPUBuffer,
    ibo:            ^sdl.GPUBuffer,
    num_indices:    u32
}

HeightMapVertex :: struct {
    position, color: vec3,
}

to_vec4 :: proc(v: vec3, f: f32) -> vec4 { return vec4{v.x, v.y, v.z, f} }

norm :: proc(v: vec3) -> f32 { return math.sqrt_f32(v.x*v.x + v.y*v.y + v.z*v.z) }

random_range :: proc(min: f32, max: f32) -> f32 {
    return rand.float32() * (max - min) + min
}
import "core:fmt"
import "core:time"
load_height_map :: proc(path: string, gpu: ^sdl.GPUDevice, scale: f32) -> HeightMap {
    now := time.now()
    height_path  := strings.concatenate({path, "/height_map.png"}, context.temp_allocator)
    diffuse_path := strings.concatenate({path, "/diffuse.png"}, context.temp_allocator)
    pixels, size := load_height_map_pixels(height_path); defer free_pixels(pixels)
    colors, dsize := load_pixels(diffuse_path); defer free_pixels(colors)
    fmt.println("Pixel loading took", time.since(now))
    start_time := now
    now = time.now()
    assert(size == dsize)
    min: u16 = 1 << 15;
    for pixel in pixels {
        if pixel < min do min = pixel
    }

    vertices: [dynamic]HeightMapVertex; defer delete(vertices)
    indices:  [dynamic]u32;             defer delete(indices)
    index: u32
    for pixel, i in pixels {
        i := i32(i)
        row := i / size.x
        col := i % size.x
        x := f32(row-size.x/2) * scale
        y := f32(col-size.y/2) * scale
        if col == size.x-1 do continue
        if row == size.y-1 do break
        vert := HeightMapVertex {
            position = {x, f32(pixel-min)/10*scale, y},
            color = get_pixel_color(colors, row, col, size.x)
        }
        r_pixel := pixels[i+1]
        r_vert  := HeightMapVertex {
            position = {x, f32(r_pixel-min)/10*scale, y+scale},
            color = get_pixel_color(colors, row, col+1, size.x)
        }
        d_pixel := pixels[i+size.x]
        d_vert  := HeightMapVertex {
            position = {x+scale, f32(d_pixel-min)/10*scale, y},
            color = get_pixel_color(colors, row+1, col, size.x)
        }
        dr_pixel := pixels[i+size.x+1]
        dr_vert  := HeightMapVertex {
            position = {x+scale, f32(dr_pixel-min)/10*scale, y+scale},
            color = get_pixel_color(colors, row+1, col+1, size.x)
        }
        quad_verts: [4]HeightMapVertex = {vert, d_vert, r_vert, dr_vert}
        quad_indices: [6]u32 = {
            index, index + 1, index + 2,
            index + 1, index + 2, index + 3 
        }
        index += 4
        for v in quad_verts do append(&vertices, v)
        for idx in quad_indices do append(&indices, idx)
    }
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

    height_map: HeightMap
    height_map.size = size
    height_map.num_indices  = u32(len(indices))
    height_map.vbo = vbo
    height_map.ibo = ibo
    fmt.println("Processing took:", time.since(now))
    fmt.println("Total:", time.since(start_time))
    return height_map
}

get_pixel_color :: proc(pixels: []byte, row, col: i32, width: i32) -> vec3 {
    bytes_per_pixel: i32 = 4
    index := (row * width + col) * bytes_per_pixel

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


decompose_trs :: proc(matrix_data: [16]f32) -> (translation: vec3, scale: vec3, rotation: quaternion128) {
    // Convert [16]f32 column-major to math.Mat4
    mat := matrix[4,4]f32{
        matrix_data[0],  matrix_data[1],  matrix_data[2],  matrix_data[3],
        matrix_data[4],  matrix_data[5],  matrix_data[6],  matrix_data[7],
        matrix_data[8],  matrix_data[9],  matrix_data[10], matrix_data[11],
        matrix_data[12], matrix_data[13], matrix_data[14], matrix_data[15],
    }

    // Extract translation from last column
    translation = vec3{mat[3].x, mat[3].y, mat[3].z}

    // Extract columns of upper-left 3x3 matrix (rotation * scale)
    col0 := vec3{mat[0].x, mat[0].y, mat[0].z}
    col1 := vec3{mat[1].x, mat[1].y, mat[1].z}
    col2 := vec3{mat[2].x, mat[2].y, mat[2].z}

    // Compute scale
    scale.x = linalg.length(col0)
    scale.y = linalg.length(col1)
    scale.z = linalg.length(col2)

    // Normalize columns to extract rotation matrix
    norm_col0 := col0 / scale.x
    norm_col1 := col1 / scale.y
    norm_col2 := col2 / scale.z

    // Construct rotation matrix
    rot_mat := matrix[3,3]f32{
        norm_col0.x, norm_col0.y, norm_col0.z,
        norm_col1.x, norm_col1.y, norm_col1.z,
        norm_col2.x, norm_col2.y, norm_col2.z,
    }

    // Convert to quaternion
    rotation = linalg.quaternion_from_matrix3(rot_mat)

    return
}
