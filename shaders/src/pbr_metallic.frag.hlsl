#define PI 3.14159265

struct Input {
    float4 clipPosition : SV_Position;
    float3 position : TEXCOORD0;
    float3 normal : TEXCOORD1;
    float2 uv : TEXCOORD2;
    float3 tangent : TEXCOORD3;
};

struct Material {
    float4 albedo;
    float metallic;
    float roughness;
};

Texture2D<float4> albedoMap : register(t0, space2);
Texture2D<float4> metalRoughMap : register(t1, space2);
Texture2D<float4> normalMap : register(t2, space2);

SamplerState albedoSmp : register(s0, space2);
SamplerState metalRoughSmp : register(s1, space2);
SamplerState normalSmp : register(s2, space2);

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

float3 fresnelSchlick(float cosTheta, float3 F0) {
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}

float DistributionGGX(float3 N, float3 H, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH = max(dot(N, H), 0.0);
    float NdotH2 = NdotH * NdotH;

    float denom = NdotH2 * (a2 - 1.0) + 1.0;
    denom = PI * denom * denom;

    return a2 / denom;
}

float GeometrySchlickGGX(float NdotV, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    return NdotV / (NdotV * (1.0 - k) + k);
}

float GeometrySmith(float3 N, float3 V, float3 L, float roughness) {
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float ggx1 = GeometrySchlickGGX(NdotV, roughness);
    float ggx2 = GeometrySchlickGGX(NdotL, roughness);
    return ggx1 * ggx2;
}

void dcr(Input input) {
    float r = metalRoughMap.Sample(metalRoughSmp, input.uv).r;
    float a = albedoMap.Sample(albedoSmp, input.uv).g;
    float n = normalMap.Sample(normalSmp, input.uv).b;
    if (r < -1000 || a < -1000 || n < -1000) discard;
}

float4 main(Input input) : SV_Target0 {
    // dcr(input);
    float3 albedo = albedoMap.Sample(albedoSmp, input.uv).rgb;
    float3 normal = normalMap.Sample(normalSmp, input.uv).rgb;
    float3 metallic_roughness = metalRoughMap.Sample(metalRoughSmp, input.uv).rgb;
    float metallic = metallic_roughness.b * metallic_factor;
    float roughness = metallic_roughness.g * roughness_factor;

    float3 N = normalize(input.normal);
    float3 V = normalize(viewPosition - input.position);
    float3 F0 = float3(0.04, 0.04, 0.04);
    F0 = lerp(F0, albedo, metallic);

    float3 Lo = float3(0, 0, 0);

    float3 L = normalize(lightPosition - input.position);
    float3 H = normalize(V + L);
    float distance      = length(lightPosition - input.position);
    float attenuation   = 1 / (distance * distance);
    float3 radiance     = lightColor * attenuation * lightIntensity;

    float NDF = DistributionGGX(N, H, roughness);
    float G   = GeometrySmith(N, V, L, roughness);
    float3 F  = fresnelSchlick(max(dot(H, V), 0), F0);

    float3 kS = F;
    float3 kD = float3(1, 1, 1) - kS;
    kD *= 1.0 - metallic;

    float3 numerator  = NDF * G * F;
    float denominator = 4.0 * max(dot(N, V), 0) * max(dot(N, L), 0.0) + 0.0001;
    float3 specular   = numerator / denominator;
    float NdotL = max(dot(N, L), 0);
    Lo += (kD * albedo / PI + specular) * radiance * NdotL;

    float3 ambient = float3(0.03, 0.03, 0.03) * albedo; // * ao
    float3 color = ambient + Lo;
    color = color / (color + float3(1, 1, 1));

    return float4(color, 1);
}