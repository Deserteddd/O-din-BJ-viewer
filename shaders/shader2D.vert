#version 450

layout (location = 0) in vec2 position;
layout (location = 1) in vec2 uv;

layout (location = 0) out vec2 v_position;
layout (location = 1) out vec2 v_uv;

// layout(set=1, binding=0) uniform UBO {
//     mat4 view_matrix;
//     mat4 projection_matrix;
//     mat4 model_matrix;
// };

void main() {
    gl_Position = vec4(position, 1.0, 1.0);
    v_uv = uv;
}

