#version 450

layout(location = 0) in vec3 v_position;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec2 v_uv;
layout(location = 3) in flat float v_cubie;

layout(location = 0) out vec4 frag_color;

layout(set=2, binding=0) uniform sampler2D tex_sampler;


void main() {
    frag_color = vec4(normalize(vec3(v_cubie, 0, 0)), 1);
}

