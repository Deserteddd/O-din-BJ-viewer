#version 450 core

layout (location = 0) in vec3 position;

layout(set=1, binding=0) uniform SHADOW_UBO {
    mat4 light_viewproj;
    vec4 position_offset;
};

void main()
{
    vec4 world_pos = vec4(position + position_offset.xyz, 1.0);
    gl_Position = light_viewproj * world_pos;
}