#version 450

layout (location = 0) in vec3 position;
layout (location = 1) in vec3 normal;
layout (location = 2) in vec2 uv;

layout (location = 0) out vec3 v_position;
layout (location = 1) out vec3 v_normal;
layout (location = 2) out vec2 v_uv;
layout (location = 3) out vec3 v_cubie_pos;

layout(set=1, binding=0) uniform UBO {
    mat4 view_matrix;
    mat4 projection_matrix;
    mat4 model_matrix;
    vec3 cubie_pos;
};

void main() {
    mat4 modelview = view_matrix*model_matrix;
    v_normal = transpose(inverse(mat3(modelview))) * normal;
    gl_Position = projection_matrix * modelview * vec4(position, 1.0);
    v_position = gl_Position.xyz;
    v_uv = uv;
    v_cubie_pos = cubie_pos;
}

