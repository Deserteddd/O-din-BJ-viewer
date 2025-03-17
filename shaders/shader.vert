#version 450

layout (location = 0) in vec3 position;
layout (location = 1) in vec3 normal;
layout (location = 2) in vec2 uv;

layout (location = 0) out vec3 v_position;
layout (location = 1) out vec3 v_normal;
layout (location = 2) out vec2 v_uv;

layout(set=1, binding=0) uniform UBO {
    mat4 view_matrix;
    mat4 projection_matrix;
    mat4 model_matrix;
};

layout(set=1, binding=1) uniform MTL {
    vec3 Ka;
    vec3 Kd;
    vec3 Ks;
    vec3 Ke;
    float Ns;
    float Ni;
    float d;
    uint illum;
};

void main() {
    mat4 modelview = view_matrix*model_matrix;
    gl_Position = projection_matrix * modelview * vec4(position, 1.0);
    v_position = gl_Position.xyz;
    v_normal = normal;
    v_uv = uv;
}