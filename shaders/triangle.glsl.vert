#version 450

layout (location = 0) in vec3 position;
layout (location = 1) in vec3 normal;

layout (location = 0) out vec3 v_position;
layout (location = 1) out vec3 v_normal;

layout(set=1, binding=0) uniform UBO {
    mat4 perspective;
    mat4 view;
    mat4 matrix;
};

void main() {
    mat4 modelview = view*matrix;
    v_normal = transpose(inverse(mat3(modelview))) * normal;
    gl_Position = perspective * modelview * vec4(position, 1.0);
    v_position = gl_Position.xyz / gl_Position.w;
}

