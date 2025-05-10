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

Texture2D<float4> base_color_tex : register(t0, space2);
Texture2D<float4> metallic_roughness_tex : register(t1, space2);

SamplerState base_color_smp : register(s0, space2);
SamplerState metallic_roughness_smp : register(s1, space2);

cbuffer LIGHT : register(b0, space3) {
    float3 lightPosition;
    float3 lightColor;
    float lightIntensity;
    float3 viewPosition;
};

cbuffer MATERIAL : register(b1, space3) {
    float4 base_color;
    float metallic_factor;
    float roughness_factor;
};

float3 blinnPhongBRDF(float3 dirToLight, float3 dirToView, float3 surfaceNormal, Input input) {
    float3 materialDiffuseReflection = base_color_tex.Sample(base_color_smp, input.uv).rgb;
    float shininess = metallic_factor;

    float3 halfWayDir = normalize(dirToLight + dirToView);
    float specularDot = max(0, dot(halfWayDir, surfaceNormal));
    float specularFactor = pow(specularDot, shininess);

    float3 specularReflection = metallic_roughness_tex.Sample(metallic_roughness_smp, input.uv).b * specularFactor;
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