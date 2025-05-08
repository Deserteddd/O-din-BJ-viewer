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

StructuredBuffer<Material> materials : register(t0, space2);

float4 main(Input input) : SV_Target0 {
    float4 base_color = materials[0].base_color;
    return base_color;
}