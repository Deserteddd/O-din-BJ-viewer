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

Globals :: struct {
    mode:       Mode,
    gpu:        ^sdl.GPUDevice,
    window:     ^sdl.Window,
    player:      Player,
    editor:      Editor,
    debug_info:  DebugInfo,
    renderer:    Renderer,
    ui_context: ^im.Context,
    heightmap:   HeightMap,
    last_ticks:  u64,
    total_time:  f64,
    fov:         f32,
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


KeyEvent :: struct {
    key: sdl.Scancode,
    mod: sdl.Keymod
}

KeyboardEvents :: sa.Small_Array(64, KeyEvent)

DebugInfo :: struct {
    frame_time:         time.Duration,
    draw_call_count:    u32,
    player_speed:       f32,
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

g: Globals = {
    fov = 90
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

to_vec4 :: proc(v: vec3, f: f32) -> vec4 { return vec4{v.x, v.y, v.z, f} }

norm :: proc(v: vec3) -> f32 { return math.sqrt_f32(v.x*v.x + v.y*v.y + v.z*v.z) }

random_range :: proc(min: f32, max: f32) -> f32 {
    return rand.float32() * (max - min) + min
}