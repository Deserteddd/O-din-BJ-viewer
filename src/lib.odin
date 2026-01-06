package obj_viewer
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:log"
import "base:runtime"
import "core:time"

import sa "core:container/small_array"
import im "shared:imgui"
import sdl "vendor:sdl3"

vec2 :: [2]f32
vec3 :: [3]f32
vec4 :: [4]f32
mat4 :: matrix[4,4]f32

to_radians :: math.to_radians_f32
round      :: math.round_f32
pow        :: linalg.pow
max        :: math.max
min        :: math.min

MouseButton :: enum {
    NONE,
    LEFT,
    RIGHT,
}

Globals :: struct {
    mode:       Mode,
    gpu:        ^sdl.GPUDevice,
    window:     ^sdl.Window,
    ui_context: ^im.Context,
    player:      Player,
    editor:      Editor,
    debug_info:  DebugInfo,
    renderer:    Renderer,
    ocean:       Plane,
    mb_click:    MouseButton,
    last_ticks:  u64,
    total_time:  f64,
    fov:         f32,
    fullscreen,
    debug_draw: bool,

}


g: Globals = {
    fov = 90
}

Pipeline :: enum {
    NONE,
    OBJ,
    AABB,
    SKYBOX,
    QUAD,
    PLANE,
    SPRITESHEET,
}

Mode :: enum {
    PLAY,
    EDIT
}

TRANSFORM_IDENTITY :: Transform {
    translation = 0,
    scale = 1,
    rotation = 0
}

Plane :: struct {
    scale:          vec3,
    num_indices:    u32,
    vbo:            ^sdl.GPUBuffer,
    ibo:            ^sdl.GPUBuffer,
}

KeyEvent :: struct {
    key: sdl.Scancode,
    mod: sdl.Keymod,
    repeat: bool,
}

KeyboardEvents :: sa.Small_Array(64, KeyEvent)

DebugInfo :: struct {
    frame_time:         time.Duration,
    draw_call_count:    u32,
    player_speed:       f32,
    fps:                u32,
}

Renderer :: struct {
    pipelines:         [Pipeline]^sdl.GPUGraphicsPipeline,
    bound_pipeline:    Pipeline,
    fallback_texture: ^sdl.GPUTexture,
    default_sampler:  ^sdl.GPUSampler,
    depth_texture:    ^sdl.GPUTexture,
    skybox_texture:   ^sdl.GPUTexture,
    light:             PointLight,
    crosshair:         Sprite,
    quad:              Quad,
}

Scene :: struct {
    models:       [dynamic]OBJModel,
    entities: #soa[dynamic]Entity,
}

new_plane :: proc(n: u16) -> Plane {
    side := n+1
    vertices := make([]OBJVertex, side*side, context.temp_allocator)
    for x in 0..<side {
        for y in 0..<side {
            index := side*x + y
            vertices[index] = OBJVertex {
                position = {f32(x), 0, f32(y)}
            }
        }
    }
    indices := make([]u16, n*n*6, context.temp_allocator)
    idx := 0

    for x in 0..<n {
        for y in 0..<n {
            v0 := u16(side*x     + y)
            v1 := u16(side*(x+1) + y)
            v2 := u16(side*(x+1) + (y+1))
            v3 := u16(side*x     + (y+1))

            // Triangle 1
            indices[idx] = v0; idx += 1
            indices[idx] = v1; idx += 1
            indices[idx] = v2; idx += 1

            // Triangle 2
            indices[idx] = v0; idx += 1
            indices[idx] = v2; idx += 1
            indices[idx] = v3; idx += 1
        }
    }
    cmd_buf   := sdl.AcquireGPUCommandBuffer(g.gpu); assert(cmd_buf != nil)
    defer {ok := sdl.SubmitGPUCommandBuffer(cmd_buf); assert(ok)}
    copy_pass := sdl.BeginGPUCopyPass(cmd_buf); assert(copy_pass != nil)
    defer sdl.EndGPUCopyPass(copy_pass)

    len_bytes := u32(len(vertices) * size_of(OBJVertex))
    transfer_buffer := sdl.CreateGPUTransferBuffer(g.gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = len_bytes,
    }); assert(transfer_buffer != nil)


    vbo := create_buffer_with_data(transfer_buffer, copy_pass, {.VERTEX}, vertices); assert(vbo != nil)
    ibo := create_buffer_with_data(transfer_buffer, copy_pass, {.INDEX}, indices); assert(vbo != nil)
    log.debug(indices)
    return {
        scale = 10,
        num_indices = u32(len(indices))/2,
        vbo = vbo,
        ibo = ibo
    }
}

load_height_map :: proc(path: string) -> Plane {
    // height_path   := strings.concatenate({path, "/height_map.png"})
    // diffuse_path  := strings.concatenate({path, "/diffuse.png"})
    // pixels, size  := load_pixels_u16(height_path);   defer free_pixels(pixels)
    // colors, dsize := load_pixels_byte(diffuse_path); defer free_pixels(colors)
    // assert(size == dsize)
    // fmt.println(len(pixels), size)
    size: [2]int = 2048
    // min: u16 = 1 << 15;
    // for pixel in pixels {
        // if pixel < min do min = pixel
    // }

    vertices := make([]OBJVertex, size.x*size.y)
    defer delete(vertices)
    indices:  [dynamic]u32
    defer delete(indices)
    // First pass to add a vertex for every pixel
    for &vert, i in vertices {
        row := i / size.x
        col := i % size.x
        x := f32(row-size.x/2)
        y := f32(col-size.y/2)
        // height := f32(pixel-min)
        vert = OBJVertex {
            position = {x, 0, y},
            // color = get_pixel_color(colors, row, col, size.x)
        }
        // vertices[i] = vert
    }
    // assert(i32(len(vertices)) == size.x * size.y)

    // Second pass to create indices for a triangulated mesh
    for i in 0..<len(vertices) {
        if i % size.x == size.x - 1 do continue // Second to last column
        if i / size.x == size.y - 1 do break    // Second to last line
        this_idx := u32(i)
        r_idx    := u32(i+1)
        d_idx    := u32(i+size.x)
        rd_idx   := u32(i+size.x+1)
        append_elems(&indices, this_idx, r_idx, d_idx, d_idx, r_idx, rd_idx)
    }
    copy_commands := sdl.AcquireGPUCommandBuffer(g.gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)
    len_bytes := u32(len(vertices) * size_of(OBJVertex))
    transfer_buffer := sdl.CreateGPUTransferBuffer(g.gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = len_bytes,
    }); assert(transfer_buffer != nil)
    vbo := create_buffer_with_data(transfer_buffer, copy_pass, {.VERTEX}, vertices[:])
    ibo := create_buffer_with_data(transfer_buffer, copy_pass, {.INDEX}, indices[:])

    sdl.ReleaseGPUTransferBuffer(g.gpu, transfer_buffer)
    sdl.EndGPUCopyPass(copy_pass)
    ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)
    height_map: Plane
    height_map.num_indices  = u32(len(indices))
    height_map.vbo = vbo
    height_map.ibo = ibo
    height_map.scale = 1
    return height_map
}

bind_pipeline :: proc(frame: Frame, pipeline: Pipeline, loc := #caller_location) {
    assert(frame.render_pass != nil)
    if pipeline == g.renderer.bound_pipeline {
        log.warnf("%v: attempted to bind already bound pipeline: %v", loc, pipeline)
        return
    }
    if pipeline == .NONE {
        log.errorf("Bound none pipeline %v", loc)
        return
    }
    sdl.BindGPUGraphicsPipeline(frame.render_pass, g.renderer.pipelines[pipeline])
    g.renderer.bound_pipeline = pipeline
}

in_bounds :: proc(p: vec2, rect: Rect) -> bool {
    return p.x >= rect.x && p.x < rect.x + rect.w && p.y >= rect.y && p.y < rect.y + rect.h
}

to_vec4 :: proc(v: vec3, f: f32) -> vec4 { return vec4{v.x, v.y, v.z, f} }

norm :: proc(v: vec3) -> f32 { return math.sqrt_f32(v.x*v.x + v.y*v.y + v.z*v.z) }

random_range :: proc(min: f32, max: f32) -> f32 {
    return rand.float32() * (max - min) + min
}