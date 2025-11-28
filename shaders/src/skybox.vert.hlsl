#include "common.hlsl"

struct Input {
	uint vertexId : SV_VertexID;
};



struct Output {
	float4 clipPosition : SV_Position;
	float3 texCoords : TEXCOORD0;
};

Output main(Input input) {
	float2 vertices[] = {
		float2(-1, -1),
		float2( 3, -1),
		float2(-1,  3),
	};
	float4 clipSpacePosition = float4(vertices[input.vertexId], 1, 1);

	float4 viewSpacePosition = mul(invProjectionMat, clipSpacePosition);

	float4 viewDir = mul(invViewMat, float4(viewSpacePosition.xyz, 0));

	Output output;
	output.clipPosition = clipSpacePosition;
	output.texCoords = viewDir.xyz;
	return output;
}