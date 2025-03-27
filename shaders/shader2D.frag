#version 450

layout(location = 0) in vec2 v_position;
layout(location = 1) in vec2 v_uv;

layout(location = 0) out vec4 frag_color;

layout(set=2, binding=0) uniform sampler2D tex_sampler;
#define RADIUS 100.0

void main() {
    vec4 color = vec4(texture(tex_sampler, v_uv));
    vec2 frag_pos = gl_FragCoord.xy;
    vec2 center = vec2(200, 300);
    
    if (length(frag_pos - center) < RADIUS) {
        // frag_color = color;
        float depth = texture(tex_sampler, v_uv).r;
        frag_color = vec4(vec3(depth), 1.0);
    } else {
        discard;
    }
}

