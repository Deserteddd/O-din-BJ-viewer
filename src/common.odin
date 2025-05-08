package obj_viewer
import "core:math"
import "core:math/rand"

vec2 :: [2]f32
vec3 :: [3]f32
vec4 :: [4]f32

WORLD_SIZE: vec3 = {50, 20, 50}
SLAB_COUNT: u32 = 2500

to_vec4 :: proc(v: vec3, f: f32) -> vec4 { return vec4{v.x, v.y, v.z, f} }

norm :: proc(v: vec3) -> f32 { return math.sqrt_f32(v.x*v.x + v.y*v.y + v.z*v.z) }

random_range :: proc(min: f32, max: f32) -> f32 {
    return rand.float32() * (max - min) + min
}