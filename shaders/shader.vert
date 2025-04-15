#version 450

layout (location = 0) in vec3 position;
layout (location = 1) in vec3 normal;
layout (location = 2) in vec2 uv;
layout (location = 3) in uint material;

layout (location = 0) out vec3 v_position;
layout (location = 1) out vec3 v_normal;
layout (location = 2) out vec2 v_uv;
layout (location = 3) flat out uint v_material;


layout(set=1, binding=0) uniform PROJ {
    mat4 projection_matrix;
};

layout(set=1, binding=1) uniform UBO {
    mat4 modelview;
    vec4 position_offset;
};


void main() {
    gl_Position = projection_matrix * modelview * vec4(position, 1.0);
    v_position = position+position_offset.xyz;
    v_normal = normal;
    v_uv = uv;
    v_material = material;
}