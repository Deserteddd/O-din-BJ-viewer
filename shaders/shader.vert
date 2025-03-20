#version 450

layout (location = 0) in vec3 position;
layout (location = 1) in vec3 normal;
layout (location = 2) in vec2 uv;
layout (location = 3) in uint material;

layout (location = 0) out vec3 v_color;
layout (location = 1) out vec2 v_uv;

struct Material {
    vec4 Ka;
    vec4 Kd;
    vec4 Ks;
    vec4 Ke;
};

layout(set=1, binding=0) uniform UBO {
    mat4 modelview;
    mat4 projection_matrix;
};

layout(set=0, binding = 0) readonly buffer Materials {
    Material materials[];
};



void main() {
    gl_Position = projection_matrix * modelview * vec4(position, 1.0);
    v_color = materials[material].Kd.xyz;
    v_uv = uv;
}