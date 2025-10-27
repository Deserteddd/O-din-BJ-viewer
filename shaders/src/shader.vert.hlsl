#include "common.hlsl"

struct Input {
    float3 position : TEXCOORD0;
    float3 normal : TEXCOORD1;
    float2 uv : TEXCOORD2;
    uint material : TEXCOORD3;
};

struct Output {
    float4 clipPosition : sv_position;
    float3 position : texcoord0;
    float3 normal : texcoord1;
    float2 uv : texcoord2;
    nointerpolation uint material : texcoord3;
};

cbuffer PROJ : register(b1, space1) {
    float4x4 model;
};

Output main(Input input) {
    float4 worldPosition = mul(model, float4(input.position, 1));

    Output output;
    output.clipPosition = mul(vp, worldPosition);
    output.uv = input.uv;
    output.position = worldPosition.xyz;
    output.normal = normalize(mul(model, float4(input.normal, 0)).xyz);
    output.material = input.material;
    return output;
}