#version 450

layout(location = 0) in vec2 v_position;
layout(location = 1) in vec2 v_uv;

layout(location = 0) out vec4 frag_color;

#define RADIUS 100.0

void main() {
    // frag_color = vec4(texture(tex_sampler, v_uv));
    vec2 frag_pos = gl_FragCoord.xy;
    vec2 center = vec2(200, 300);
    
    if (length(frag_pos - center) < RADIUS) {
        frag_color = vec4(1);
    } else {
        discard;
    }
}

