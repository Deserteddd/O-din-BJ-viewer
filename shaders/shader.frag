#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 1) flat in uint material;

layout(location = 0) out vec4 frag_color;

// layout(set=2, binding=0) uniform sampler2D tex_sampler;
// layout(set=2, binding=1) uniform sampler2D tex_sampler2;

layout(set=2, binding=0) uniform sampler2D ts1;
layout(set=2, binding=1) uniform sampler2D ts2;
layout(set=2, binding=2) uniform sampler2D ts3;
layout(set=2, binding=3) uniform sampler2D ts4;

struct Material {
    vec4 Ka;
    vec4 Kd;
    vec4 Ks;
    vec4 Ke;
};

layout(set=2, binding = 4) readonly buffer Materials {
    Material materials[];
};

void main() {
    vec4 diffuse;
    float Kd_texture = materials[material].Kd.x;
    if (Kd_texture == -1) {
        float texture_index = materials[material].Kd.y;
        if (texture_index == 0)
            diffuse = vec4(texture(ts1, v_uv));
        else
            diffuse = vec4(texture(ts2, v_uv));
    } else {
        diffuse = vec4(materials[material].Kd.xyz, 1);
    }
    frag_color = diffuse;
}

