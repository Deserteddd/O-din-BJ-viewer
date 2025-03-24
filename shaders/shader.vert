#version 450

layout (location = 0) in vec3 position;
layout (location = 1) in vec3 normal;
layout (location = 2) in vec2 uv;
layout (location = 3) in uint material;

layout (location = 0) out vec2 v_uv;
layout (location = 1) flat out uint v_material;



layout(set=1, binding=0) uniform UBO {
    mat4 modelview;
    mat4 projection_matrix;
};


void main() {
    gl_Position = projection_matrix * modelview * vec4(position, 1.0);
    v_material = material;
    v_uv = uv;
}