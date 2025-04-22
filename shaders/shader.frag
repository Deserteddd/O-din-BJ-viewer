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
layout(location = 4) in vec4 v_light_space_position;

layout(location = 0) out vec4 frag_color;

layout(set=2, binding=0) uniform sampler2D shadow_sampler;
layout(set=2, binding=1) uniform sampler2D ts0;
layout(set=2, binding=2) uniform sampler2D ts1;
layout(set=2, binding=3) uniform sampler2D ts2;
layout(set=2, binding=4) uniform sampler2D ts3;

layout(set=2, binding = 5) readonly buffer Materials {
    Material materials[];
};

layout(set=3, binding = 0) uniform UBO {
    PointLight light;
};

layout(set=3, binding = 1) uniform BIAS {
    float bias;
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

float calculateShadow(vec4 light_space_pos) {
    // Perspective divide
    vec3 proj_coords = light_space_pos.xyz / light_space_pos.w;

    // Transform from [-1,1] to [0,1] for sampling
    proj_coords = proj_coords * 0.5 + 0.5;

    // If outside the light's view, skip shadowing
    if (proj_coords.z > 1.0 || proj_coords.x < 0.0 || proj_coords.x > 1.0 || proj_coords.y < 0.0 || proj_coords.y > 1.0)
        return 1.0;
    vec2 flipped_uv = vec2(proj_coords.x, 1.0 - proj_coords.y);
    float closest_depth = texture(shadow_sampler,  flipped_uv).r;
    float current_depth = proj_coords.z;

    // Add bias to reduce shadow acne
    // float bias = 0.2;
    return current_depth - bias > closest_depth ? 0.0 : 1.0;
}

void main() {
    vec4 color = getColor();
    vec3 to_light = normalize(light.position - v_pos);
    vec3 normal = normalize(v_normal);
    float diffuse = max(0.0, dot(v_normal, to_light));
    float distance = distance(v_pos.xyz, light.position);
    vec3 intensity = light.power * light.color * color.xyz * diffuse * (1/(distance*distance));
    float shadow = calculateShadow(v_light_space_position);
    frag_color = vec4(intensity * max(0.1, shadow), 1.0);
}