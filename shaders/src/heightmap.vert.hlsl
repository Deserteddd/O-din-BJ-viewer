#include "common.hlsl"

struct Input {
    float3 position : TEXCOORD0;
    float3 color    : TEXCOORD1;
};

struct Output {
    float4 clip_position : sv_position;
    float4 p_color : TEXCOORD0;
};

cbuffer Global : register(b1, space1) {
    float3 scale;
}

Output main(Input input) {
    Output output;
    input.position *= scale;
    input.position.y -= scale.y*5000;
    float4 worldPosition = float4(input.position, 1);
    output.clip_position = mul(vp, worldPosition);
    output.p_color = float4(input.color, 1);
    return output;
}