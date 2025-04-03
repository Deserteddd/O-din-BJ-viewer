glslc ./shaders/triangle.glsl.vert -o ./shaders/spv/triangle.vert.spv
glslc ./shaders/triangle.glsl.frag -o ./shaders/spv/triangle.frag.spv
glslc ./shaders/bbox.vert -o ./shaders/spv/bbox.vert.spv
glslc ./shaders/bbox.frag -o ./shaders/spv/bbox.frag.spv

odin run ./src -debug

