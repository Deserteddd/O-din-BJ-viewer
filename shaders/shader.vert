#version 450

layout (location = 0) in vec3 position;
layout (location = 1) in vec3 normal;
layout (location = 2) in vec2 uv;
layout (location = 3) in uint material;

layout (location = 0) out vec3 v_position;
layout (location = 1) out vec3 v_normal;
layout (location = 2) out vec2 v_uv;
layout (location = 3) flat out uint v_material;
layout (location = 4) out vec4 v_light_space_position;



layout(set=1, binding=0) uniform UBO {
    mat4 modelview;
    mat4 model;
    vec4 position_offset;
};

layout(set = 1, binding = 1) uniform LIGHT_MATRIX {
    mat4 light_viewproj;
};

layout(set=1, binding=2) uniform PROJ {
    mat4 projection_matrix;
};

void main() {
    vec4 world_pos = vec4(position + position_offset.xyz, 1.0);
    gl_Position = projection_matrix * modelview * vec4(position, 1.0);
    v_position = world_pos.xyz;
    v_normal = normal;
    v_uv = uv;
    v_material = material;
    v_light_space_position = model * light_viewproj * world_pos;
}