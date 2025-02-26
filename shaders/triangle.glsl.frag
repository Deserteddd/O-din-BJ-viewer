#version 450

layout(location = 0) in vec3 v_position;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec2 v_uv;
layout(location = 3) in vec3 v_cubie_pos;

layout(location = 0) out vec4 frag_color;

layout(set=2, binding=0) uniform sampler2D tex_sampler;

const vec3 specular_color = vec3(1.0, 1.0, 1.0);
const vec3 diffuse_color = vec3(0.8, 0.8, 0.8);
const vec3 u_light = vec3(-1, 0, 0);
void main() {
    float diffuse = max(dot(normalize(v_normal), normalize(u_light)), 0.0);

    vec3 camera_dir = normalize(-v_position);
    vec3 half_direction = normalize(normalize(u_light) + camera_dir);
    float specular = pow(max(dot(half_direction, normalize(v_normal)), 0.0), 16.0);

    vec4 color = vec4((normalize(v_cubie_pos) + 0.5) / 2 + diffuse * diffuse_color + specular * specular_color, 1.0);
    // vec4 color = vec4(normalize(v_cubie_pos)/2 + 0.5, 1.0);
    frag_color = texture(tex_sampler, v_uv) * color;
}

