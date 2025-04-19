glslc ./shaders/shader.vert -o ./shaders/spv/shader.vert.spv
if %errorlevel% neq 0 exit /b 1
glslc ./shaders/shader.frag -o ./shaders/spv/shader.frag.spv
if %errorlevel% neq 0 exit /b 1
glslc ./shaders/bbox.vert -o ./shaders/spv/bbox.vert.spv
if %errorlevel% neq 0 exit /b 1
glslc ./shaders/bbox.frag -o ./shaders/spv/bbox.frag.spv
if %errorlevel% neq 0 exit /b 1
glslc ./shaders/shadow.vert -o ./shaders/spv/shadow.vert.spv
if %errorlevel% neq 0 exit /b 1
odin run ./src

