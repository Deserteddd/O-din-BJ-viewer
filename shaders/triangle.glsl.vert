#version 450

layout (location = 0) in vec3 pos;
layout (location = 1) in vec3 normal;

layout (location = 0) out vec4 v_color;

layout(set=1, binding=0) uniform UBO {
    mat4 mvp;
};

void main() {
    v_color = vec4(normalize(normal) + 0.5, 1.0);
    // v_color = vec4(1, 0, 0, 1.0);
    // gl_Position = mvp * position;
    gl_Position = mvp * vec4(pos, 1.0);
}