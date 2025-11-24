package obj_viewer
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:log"
import "base:runtime"

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

Globals :: struct {
    mode:       Mode,
    gpu:        ^sdl.GPUDevice,
    window:     ^sdl.Window,
    last_ticks: u64,
    frame:      u64,
    fov:        f32,
    fullscreen,
    lmb_down,
    rmb_down,
    debug_draw: bool,
}

Pipeline :: enum {
    NONE,
    OBJ,
    AABB,
    SKYBOX,
    HEIGHTMAP,
    QUAD,
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

HeightMap :: struct {
    scale:          vec3,
    num_indices:    u32,
    vbo:            ^sdl.GPUBuffer,
    ibo:            ^sdl.GPUBuffer,
}

HeightMapVertex :: struct {
    position, color: vec3,
}

bind_pipeline :: proc(renderer: ^Renderer, frame: Frame, pipeline: Pipeline, loc := #caller_location) {
    assert(frame.render_pass != nil)
    if pipeline == renderer.bound_pipeline {
        log.warnf("%v: attempted to bind already bound pipeline: %v", loc, pipeline)
        return
    }
    to_be_bound: ^sdl.GPUGraphicsPipeline
    switch pipeline {
        case .NONE: {
            log.errorf("%v: attempted to bind NONE pipeline", loc)
            runtime.trap()
        }
        case .OBJ:          to_be_bound = renderer.r3.obj_pipeline
        case .AABB:         to_be_bound = renderer.r3.aabb_pipeline
        case .SKYBOX:       to_be_bound = renderer.r3.skybox_pipeline
        case .HEIGHTMAP:    to_be_bound = renderer.r3.heightmap_pipeline
        case .QUAD:         to_be_bound = renderer.r2.quad_pipeline
        case .SPRITESHEET:  to_be_bound = renderer.r2.sprite_sheet_pipeline
    }
    sdl.BindGPUGraphicsPipeline(frame.render_pass, to_be_bound)
    renderer.bound_pipeline = pipeline
}

to_vec4 :: proc(v: vec3, f: f32) -> vec4 { return vec4{v.x, v.y, v.z, f} }

norm :: proc(v: vec3) -> f32 { return math.sqrt_f32(v.x*v.x + v.y*v.y + v.z*v.z) }

random_range :: proc(min: f32, max: f32) -> f32 {
    return rand.float32() * (max - min) + min
}