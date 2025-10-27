
cbuffer MaterialCB : register(b1, space3)
{
    float4 base_color_factor;
    float metallic_factor;
    float roughness_factor;
    bool has_base_col_tex;
    bool has_metal_rough_tex;
    bool has_normal_tex;
    bool has_occlusion_tex;
};

Texture2D<float4> base_color_texture         : register(t0, space2);
Texture2D<float4> metallic_roughness_texture : register(t1, space2);
Texture2D<float4> normal_texture             : register(t2, space2);
Texture2D<float4> occlusion_texture          : register(t3, space2);
SamplerState smp0          : register(s0, space2);
SamplerState smp1          : register(s1, space2);
SamplerState smp2          : register(s2, space2);
SamplerState smp3          : register(s3, space2);

struct Input {
    float4 position : SV_Position;
    float3 worldPos : TEXCOORD0;
    float3 normal   : TEXCOORD1;
    float2 uv       : TEXCOORD2;
    float3 tangent  : TEXCOORD3;
};

// Simple directional light
cbuffer LightCB : register(b0, space3)
{
    float3 lightDirection;
    float3 lightColor;
};

float4 main(Input input) : SV_Target {
    float3 albedo = base_color_factor.rgb;
    if (has_base_col_tex) {
        albedo = base_color_texture.Sample(smp0, input.uv).rgb;
    }
    float3 normal = input.normal;
    if (has_normal_tex) {
        normal = normal_texture.Sample(smp2, input.uv).rgb;
    }
    float metallic = metallic_factor;
    float roughness = roughness_factor;
    if (has_metal_rough_tex) {
        float2 metal_rough = metallic_roughness_texture.Sample(smp1, input.uv).bg;
        metallic = metal_rough.r;
        roughness = metal_rough.g;
    }
    // This is here to avoid unused variable removal
    float _ = (albedo.r + normal.r + metallic + roughness + lightDirection.r)*0.0000001;

    return float4(albedo, 1+_);
}