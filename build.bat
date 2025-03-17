glslc ./shaders/shader.vert -o ./shaders/spv/shader.vert.spv
if %errorlevel% neq 0 exit /b 1
glslc ./shaders/shader.frag -o ./shaders/spv/shader.frag.spv
if %errorlevel% neq 0 exit /b 1
glslc ./shaders/shader2D.vert -o ./shaders/spv/shader2D.vert.spv
if %errorlevel% neq 0 exit /b 1
glslc ./shaders/shader2D.frag -o ./shaders/spv/shader2D.frag.spv
if %errorlevel% neq 0 exit /b 1

odin run ./src -debug

