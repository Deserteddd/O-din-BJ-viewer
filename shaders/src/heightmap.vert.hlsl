#include "common.hlsl"

#define TAU 6.2831853072

struct Input {
    float3 position : TEXCOORD0;
    float3 color    : TEXCOORD1;
};

struct Output {
    float4 clip_position : sv_position;
    float3 world_position : TEXCOORD0;
    float4 p_color : TEXCOORD1;
};

cbuffer Global : register(b1, space1) {
    float time;
}

Output main(Input input) {
    Output output;
    float3 waveDir = float3(1, 0, 0);
    float  waveLen = 8;
    float  waveHeight = 0.4;

    float tauPerLen = TAU/waveLen;
    float gravity = tauPerLen*9.81;
    float gravitySqrt = sqrt(gravity);
    float gravityTime = gravitySqrt * time;

    float3 waveDirNormal = normalize(waveDir);
    float3 dirTimesTauPerLen = waveDirNormal * tauPerLen;

    float3 posDot = dot(dirTimesTauPerLen, input.position);
    float3 posDotMinusGravityTime = posDot - gravityTime;

    posDotMinusGravityTime = cos(posDotMinusGravityTime);
    posDotMinusGravityTime *= float3(0, 1, 0);
    posDotMinusGravityTime *= waveHeight;

    float3 wavePosition = posDotMinusGravityTime + input.position;


    float4 worldPosition = float4(wavePosition, 1);
    output.clip_position = mul(vp, worldPosition);
    output.world_position = worldPosition.xyz;
    output.p_color = float4(input.color, 1);
    return output;
}