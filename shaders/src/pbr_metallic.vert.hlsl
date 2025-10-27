#include "common.hlsl"

cbuffer PROJ : register(b1, space1) {
    float4x4 model;
};

struct Input {
    float3 position : POSITION;
    float3 normal   : NORMAL;
    float2 uv       : TEXCOORD0;
    float3 tangent  : TANGENT;
};

struct Output {
    float4 clipPosition : SV_Position;
    float3 position     : TEXCOORD0;
    float3 normal       : TEXCOORD1;
    float2 uv           : TEXCOORD2;
    float3 tangent      : TEXCOORD3;
};

Output main(Input input)
{
    float4 worldPosition = mul(model, float4(input.position, 1));
    Output output;
    output.clipPosition = mul(vp, worldPosition);
    output.uv = input.uv;
    output.position = worldPosition.xyz;
    output.normal = normalize(mul(model, float4(input.normal, 0)).xyz);
    output.tangent = input.tangent;
    return output;
}