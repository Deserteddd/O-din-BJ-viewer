#if __SHADER_TARGET_STAGE == __SHADER_STAGE_VERTEX
cbuffer Global : register(b0, space1) {
    float4x4 vp;
    float4x4 invViewMat;
	float4x4 invProjectionMat;
}

#elif __SHADER_TARGET_STAGE == __SHADER_STAGE_PIXEL

cbuffer UBO : register(b0, space3) {
    float3 lightPosition;
    float3 lightColor;
    float lightIntensity;
    float3 viewPosition;
};

#endif