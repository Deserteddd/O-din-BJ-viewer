package obj_viewer

vec2 :: [2]f32
vec3 :: [3]f32
vec4 :: [4]f32

to_vec4 :: #force_inline proc(v: vec3, f: f32) -> vec4 {return vec4{v.x, v.y, v.z, f}}