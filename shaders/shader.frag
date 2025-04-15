#version 450

struct Material {
    vec4 Ka;
    vec4 Kd;
    vec4 Ks;
    vec4 Ke;
};

struct PointLight {
    vec3 position;
    float power;
    vec3 color;
};

layout(location = 0) in vec3 v_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec2 v_uv;
layout(location = 3) flat in uint material;

layout(location = 0) out vec4 frag_color;

layout(set=2, binding=0) uniform sampler2D ts0;
layout(set=2, binding=1) uniform sampler2D ts1;
layout(set=2, binding=2) uniform sampler2D ts2;
layout(set=2, binding=3) uniform sampler2D ts3;

layout(set=2, binding = 4) readonly buffer Materials {
    Material materials[];
};

layout(set=3, binding = 0) uniform UBO {
    PointLight light;
};

vec4 getColor() {
    float is_texture = materials[material].Kd.x;
    if (is_texture == -1) {
        float texture_index = materials[material].Kd.y;
        if (texture_index == 0) {
            return vec4(texture(ts0, v_uv));
        } else if (texture_index == 1) {
            return vec4(texture(ts1, v_uv));
        } else if (texture_index == 2) {
            return vec4(texture(ts2, v_uv));
        } else if (texture_index == 3) {
            return vec4(texture(ts3, v_uv));
        }
    } 
    else {
        return vec4(materials[material].Kd.xyz, 1);
    }
}

void main() {
    vec4 color = getColor();
    vec3 to_light = normalize(light.position - v_pos);
    vec3 normal = normalize(v_normal);
    float diffuse = max(0.0, dot(v_normal, to_light));
    float distance = distance(v_pos.xyz, light.position);
    vec3 intensity = light.power * light.color * color.xyz * diffuse * (1/(distance*distance));
    frag_color = vec4(color.xyz * intensity, 1);
}





