struct Material {
    float4 Ka;
    float4 Kd;
    float4 Ks;
    float4 Ke;
};

struct PointLight {
    float3 position;
    float power;
    float3 color;
};

struct Input {
    float3 position : TEXCOORD0;
    float3 normal : TEXCOORD1;
    float2 uv : TEXCOORD2;
    nointerpolation uint material : TEXCOORD3;
};

Texture2D<float4> ts0 : register(t0, space2);
Texture2D<float4> ts1 : register(t1, space2);
Texture2D<float4> ts2 : register(t2, space2);
Texture2D<float4> ts3 : register(t3, space2);

SamplerState smp0 : register(s0, space2);
SamplerState smp1 : register(s1, space2);
SamplerState smp2 : register(s2, space2);
SamplerState smp3 : register(s3, space2);

StructuredBuffer<Material> materials : register(t4, space2);

cbuffer UBO : register(b0, space3) {
    PointLight light;
};

float4 getColor(Input input) {
    float is_texture = materials[input.material].Kd.x;
    if (is_texture == -1) {
        float texture_index = materials[input.material].Kd.y;
        if (texture_index == 0) {
            return ts0.Sample(smp0, input.uv);
        } else if (texture_index == 1) {
            return ts1.Sample(smp1, input.uv);
        } else if (texture_index == 2) {
            return ts2.Sample(smp2, input.uv);
        } else if (texture_index == 3) {
            return ts3.Sample(smp3, input.uv);
        }
    } 
    return float4(materials[input.material].Kd.xyz, 1);
}

float4 main(Input input) : SV_Target0 {
    float4 color = getColor(input);
    float3 to_light = normalize(light.position - input.position);
    float3 normal = normalize(input.normal);
    float diffuse = max(0.0, dot(input.normal, to_light));
    float dist = distance(input.position.xyz, light.position);
    float3 intensity = light.power * light.color * color.xyz * diffuse * (1/(dist*dist));
    return float4(intensity, 1);
}