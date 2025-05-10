struct Input {
    float4 clipPosition : SV_Position;
    float3 position : TEXCOORD0;
    float3 normal : TEXCOORD1;
    float2 uv : TEXCOORD2;
};

struct Material {
    float4 base_color;
    float metallic;
    float roughness;
};

Texture2D<float4> ts0 : register(t0, space2);
SamplerState smp0 : register(s0, space2);

cbuffer MATERIAL : register(b0, space3) {
    float4 base_color;
    float metallic_factor;
    float roughness_factor;
};


float4 main(Input input) : SV_Target0 {
    return ts0.Sample(smp0, input.uv) * base_color;
}