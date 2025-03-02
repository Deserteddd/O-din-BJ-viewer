glslc ./shaders/triangle.glsl.vert -o ./shaders/spv/triangle.vert.spv
glslc ./shaders/triangle.glsl.frag -o ./shaders/spv/triangle.frag.spv

odin run ./src -debug

