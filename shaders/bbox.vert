#version 450

layout (location = 0) in vec3 position;
layout (location = 0) out vec4 p_color; 

layout(set=1, binding=0) uniform UBO {
    mat4 modelview;
    mat4 projection_matrix;
};

void main() {
    gl_Position = projection_matrix * modelview * vec4(position, 1.0);
    p_color = vec4(1, 0, 1, 1);

}