#include "common.hlsl"

struct Input {
    float3 position : TEXCOORD0;
    float3 normal   : TEXCOORD1;
    float2 uv       : TEXCOORD2;
};

struct Material {
    float3 diffuseColor;
    bool   hasDiffuseMap;
    float3 specularColor;
    bool   hasSpecularMap;
    float  specularFactor;
};

Texture2D<float4> diffMap  : register(t0, space2);
Texture2D<float4> specMap  : register(t1, space2);

SamplerState diffSmp : register(s0, space2);
SamplerState specSmp : register(s1, space2);

StructuredBuffer<Material> materials : register(t2, space2);

cbuffer Material : register(b1, space3) {
    uint material_index;
};

float4 main(Input input) : SV_Target0
{
    Material material = materials[material_index];
    // Assume input.position and input.normal are in world-space.
    // Normalize incoming normal.
    float3 N = normalize(input.normal);

    // Light vector (L) and distance-based attenuation
    float3 Lvec = lightPosition - input.position;
    float  dist = max(length(Lvec), 1e-4);
    float3 L = normalize(Lvec);

    // View vector
    float3 V = normalize(viewPosition - input.position);

    // Half-vector for Blinn-Phong
    float3 H = normalize(L + V);

    // Sample diffuse map if present, otherwise use material diffuseColor
    float3 baseDiffuse = material.diffuseColor;
    if (material.hasDiffuseMap)
    {
        float4 d = diffMap.Sample(diffSmp, input.uv);
        // assume texture in sRGB->linear already handled elsewhere; multiply RGB
        baseDiffuse = d.rgb;
    }

    // Sample specular map if present, otherwise use material specularColor
    float3 baseSpecular = material.specularColor;
    if (material.hasSpecularMap)
    {
        float4 s = specMap.Sample(specSmp, input.uv);
        baseSpecular = s.rgb;
    }

    // Diffuse term (Lambert)
    float NdotL = saturate(dot(N, L));
    float3 diffuse = baseDiffuse * NdotL;

    // Specular term (Blinn-Phong)
    float NdotH = saturate(dot(N, H));
    // specularFactor used as shininess exponent; clamp to avoid huge pow
    float shininess = max(material.specularFactor, 1.0);
    float specularPower = pow(NdotH, shininess);
    float3 specular = baseSpecular * specularPower;

    // Distance attenuation (inverse-square), scaled by lightIntensity
    float attenuation = lightIntensity / (dist * dist);
    // Optionally clamp attenuation to avoid extremely bright near values
    attenuation = min(attenuation, 128.0);

    // Small ambient term to avoid fully black shadows (tweak as desired)
    float3 ambient = 0.03 * baseDiffuse;

    // Compose final color
    float3 color = ambient + attenuation * (lightColor * (diffuse + specular));

    // Ensure color is in [0,1]
    color = saturate(color);

    return float4(color, 1.0f);
}