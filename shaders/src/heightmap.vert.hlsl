#include "common.hlsl"

#define TAU 6.2831853072

struct Input {
    float3 position : TEXCOORD0;
    float3 color    : TEXCOORD1;
};

struct Output {
    float4 clip_position : sv_position;
    float3 world_position : TEXCOORD0;
    float3 normal  : TEXCOORD1;
    float4 p_color : TEXCOORD2;
};

cbuffer Global : register(b1, space1) {
    float time;
}

struct Wave {
    float3 position;
    float3 normal;
};

Wave createWave(Input input, float3 waveDir, float waveLen, float waveHeight, float waveSpeed) {
    float  peakSharpness = 0.4;

    // Speed
    float tauPerLen = TAU/waveLen;
    float gravity = tauPerLen*9.81;
    float gravitySqrt = sqrt(gravity);
    float gravityTime = gravitySqrt * (time * waveSpeed);
    
    // Sharpness
    float sharpHeight = waveHeight * tauPerLen;
    float peakPerHeight = peakSharpness / sharpHeight;
    float peakTimesHeight = peakPerHeight * waveHeight;

    float3 waveDirNormal = normalize(waveDir);
    float3 dirTimesTauPerLen = waveDirNormal * tauPerLen;

    float3 posDot = dot(dirTimesTauPerLen, input.position);
    float3 posDotMinusGravityTime = posDot - gravityTime;

    float3 sinPosDotMinusGravityTime = sin(posDotMinusGravityTime);
    float3 sinPeakTimesHeight = sinPosDotMinusGravityTime * peakTimesHeight;
    sinPeakTimesHeight *= waveDirNormal;

    posDotMinusGravityTime = cos(posDotMinusGravityTime);
    float3 posDotMinusGravityTimeY = posDotMinusGravityTime * float3(0, 1, 0);
    posDotMinusGravityTimeY *= waveHeight;

    float3 peakSubtracted = posDotMinusGravityTimeY - sinPeakTimesHeight;
    float3 wavePosition = peakSubtracted + input.position;

    // Normal
    float3 gtTimesHeight = sinPosDotMinusGravityTime * sharpHeight;
    gtTimesHeight *= waveDirNormal;
    float3 cosSharpHeight = posDotMinusGravityTime * peakTimesHeight;
    cosSharpHeight /= peakPerHeight;
    cosSharpHeight = 1 - cosSharpHeight;

    Wave wave;
    wave.normal = float3(gtTimesHeight.x, cosSharpHeight.y, gtTimesHeight.z);
    wave.position = wavePosition;
    return wave;
}

Output main(Input input) {
    Output output;
    
    Wave w1 = createWave(input, float3(1, 0, 0.2), 4, 0.6, 0.8);
    Wave w2 = createWave(input, float3(0.3, 0, 1), 6, 0.4, 1);
    Wave w3 = createWave(input, float3(0.6, 0, 0.4), 10, 1, 1.2);
    
    float3 wavePos = (w1.position + w2.position + w3.position) / 3;
    float3 waveNormal = (w1.normal + w2.normal + w3.normal) / 3;

    float4 worldPosition = float4(wavePos, 1);
    output.clip_position = mul(vp, worldPosition);
    output.world_position = worldPosition.xyz;
    output.normal = waveNormal;
    output.p_color = float4(input.color, 1);
    return output;
}