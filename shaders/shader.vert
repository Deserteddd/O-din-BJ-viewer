#version 450

layout (location = 0) in vec3 position;
layout (location = 1) in vec3 normal;
layout (location = 2) in vec2 uv;

layout (location = 0) flat out vec3 v_color;
layout (location = 1) out vec2 v_uv;

layout(set=0, binding=0) readonly buffer MaterialIndices {
    uint indices[];
};

layout(set=1, binding=0) uniform UBO {
    mat4 modelview;
    mat4 projection_matrix;
    mat4 mtl;
};

void main() {
    gl_Position = projection_matrix * modelview * vec4(position, 1.0);
    // gl_Position = vec4(normalize(position), 1);
    // v_color = vec3(ks.x, 0, 0);
    // v_color = vec3(1);
    // v_color = mtl[1].xyz;
    uint id = indices[gl_VertexIndex];
    if (id == 0) {
        v_color = vec3(1, 0, 0);
    } else {
        v_color = vec3(0, 0, 0);
    }
    v_uv = uv;
}