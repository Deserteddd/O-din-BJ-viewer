#include "common.hlsl"

struct Input {
    float3 position : TEXCOORD0;
    float3 normal   : TEXCOORD1;
    float2 uv       : TEXCOORD2;
    nointerpolation uint material : TEXCOORD3;
};

struct Material {
    float3 diffuseColor;
    int    diffuseMap;
    float3 specularColor;
    int    specularMap;
    float  specularFactor;
};

Texture2D<float4> tex0  : register(t0, space2);
Texture2D<float4> tex1  : register(t1, space2);
Texture2D<float4> tex2  : register(t2, space2);
Texture2D<float4> tex3  : register(t3, space2);
Texture2D<float4> tex4  : register(t4, space2);
Texture2D<float4> tex5  : register(t5, space2);
Texture2D<float4> tex6  : register(t6, space2);
Texture2D<float4> tex7  : register(t7, space2);

SamplerState smp0 : register(s0, space2);
SamplerState smp1 : register(s1, space2);
SamplerState smp2 : register(s2, space2);
SamplerState smp3 : register(s3, space2);
SamplerState smp4 : register(s4, space2);
SamplerState smp5 : register(s5, space2);
SamplerState smp6 : register(s6, space2);
SamplerState smp7 : register(s7, space2);

TextureCube<float4> cubeMap : register(t8, space2);
SamplerState cubeSmp : register(s8, space2);


StructuredBuffer<Material> materials : register(t9, space2);

float3 get_color_value(Input input, int map) {
    switch (map) {
        case 0:
            return tex0.Sample(smp0, input.uv).rgb;
        case 1:
            return tex1.Sample(smp1, input.uv).rgb;
        case 2:
            return tex2.Sample(smp2, input.uv).rgb;
        case 3:
            return tex3.Sample(smp3, input.uv).rgb;
        case 4:
            return tex4.Sample(smp4, input.uv).rgb;
        case 5:
            return tex5.Sample(smp5, input.uv).rgb;
        case 6:
            return tex6.Sample(smp6, input.uv).rgb;
        case 7:
            return tex7.Sample(smp7, input.uv).rgb;
        default:
            return -1;
        
    }
}

float3 get_specular_color(Input input) {
    Material material = materials[input.material];
    float3 specular = get_color_value(input, material.specularMap);
    if (specular.x == -1) {
        return material.specularColor;
    } else {
        return specular;
    }
}

float3 get_diffuse_color(Input input) {
    Material material = materials[input.material];
    float3 diffuse = get_color_value(input, material.diffuseMap);
    if (diffuse.x == -1) {
        return material.diffuseColor;
    } else {
        return diffuse;
    }
}

float3 blinnPhongBRDF(float3 dirToLight, float3 dirToView, float3 surfaceNormal, Input input) {
    float shininess = materials[input.material].specularFactor;
    float3 halfWayDir = normalize(dirToLight + dirToView);
    float specularDot = max(0, dot(halfWayDir, surfaceNormal));
    float3 specularColor = get_specular_color(input);
    float specularFactor = pow(specularDot, shininess);
    float3 specularReflection = specularColor * specularFactor;
    float3 diffuseReflection = get_diffuse_color(input);

    return specularReflection + diffuseReflection;
}

float4 main(Input input) : SV_Target0 {
    float3 surfaceNormal = normalize(input.normal);
    float3 ambientLight = cubeMap.Sample(cubeSmp, surfaceNormal).rgb;
    float3 diff_color = get_diffuse_color(input);
    float3 reflectedRadiance = ambientLight * diff_color;

    if (lightIntensity < 0.1) {
        return float4(reflectedRadiance, 1);
    }

    float3 vecToLight = lightPosition - input.position;
    float distToLight = length(vecToLight);
    float3 dirToLight = vecToLight / distToLight;
    float3 dirToView = normalize(viewPosition - input.position);



    float incidenceAngleFactor = dot(dirToLight, surfaceNormal);
    if (incidenceAngleFactor > 0) {
        float attenuationFactor = 1 / (distToLight * distToLight);

        float3 incomingRadiance = lightColor * lightIntensity;
        float3 irradiance = incomingRadiance * incidenceAngleFactor * attenuationFactor;
        float3 brdf = blinnPhongBRDF(dirToLight, dirToView, surfaceNormal, input);
        reflectedRadiance += irradiance * brdf;
    }
    float3 outRadiance = reflectedRadiance;
    return float4(outRadiance, 1);
}