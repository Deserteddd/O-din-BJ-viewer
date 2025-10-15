#include "common.hlsl"

struct Material {
    float4 Ka;
    float4 Kd;
    float4 Ks;
    float4 Ke;
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

float4 diffuseColor(Input input) {
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

float3 blinnPhongBRDF(float3 dirToLight, float3 dirToView, float3 surfaceNormal, Input input) {
    float3 materialDiffuseReflection = diffuseColor(input).rgb;
    float shininess = materials[input.material].Ka.a;

    float3 halfWayDir = normalize(dirToLight + dirToView);
    float specularDot = max(0, dot(halfWayDir, surfaceNormal));
    float specularFactor = pow(specularDot, shininess);

    float3 specularReflection = materials[input.material].Ks.rgb * specularFactor;
    return materialDiffuseReflection + specularReflection;
}

float4 main(Input input) : SV_Target0 {
    float3 vecToLight = lightPosition - input.position;
    float distToLight = length(vecToLight);
    float3 dirToLight = vecToLight / distToLight;
    float3 dirToView = normalize(viewPosition - input.position);
    float3 surfaceNormal = normalize(input.normal);

    float incidenceAngleFactor = dot(dirToLight, surfaceNormal);
    float3 reflectedRadiance;
    if (incidenceAngleFactor > 0) {
        float attenuationFactor = 1 / (distToLight * distToLight);
        float3 incomingRadiance = lightColor * lightIntensity;
        float3 irradiance = incomingRadiance * incidenceAngleFactor * attenuationFactor;
        float3 brdf = blinnPhongBRDF(dirToLight, dirToView, surfaceNormal, input);
        reflectedRadiance = irradiance * brdf;
    } else {
        reflectedRadiance = float3(0, 0, 0);
    }

    float3 emittedRadiance = float3(0, 0, 0);
    float3 outRadiance = emittedRadiance + reflectedRadiance;
    return float4(outRadiance, 1);
}