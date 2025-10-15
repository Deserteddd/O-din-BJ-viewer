package obj_viewer

import sdl "vendor:sdl3"

Entity :: struct {
    id: i32,
    model: ^Model,
    transform: Transform,
}

Transform :: struct {
    translation: vec3,
    rotation: quaternion128,
    scale:      vec3
}

entity_from_model :: proc(state: ^AppState, model_name: string) -> (id: i32, ok: bool) {
    entity: Entity
    for &model in state.models {
        if model.name == model_name {
            entity.model = &model
            break
        }
    }
    if entity.model == nil do return
    ok = true
    id = lowest_free_id(state.entities.id, len(state.entities))
    entity.id = id
    append_soa(&state.entities, entity)
    return
}

lowest_free_id :: proc(ids: [^]i32, len: int) -> i32 {
    ids := new_clone(ids, context.temp_allocator)
    len := i32(len)
    for i in 0..<len {
        for {
            val := ids[i];
            if val <= 0 || val > len {
                break;
            }
            correct_index := val - 1;
            if ids[correct_index] == val {
                break;
            }
            temp := ids[i];
            ids[i] = ids[correct_index];
            ids[correct_index] = temp;
        }
    }

    for i in 0..<len {
        if ids[i] != i + 1 {
            return i + 1;
        }
    }

    return len + 1;
}

set_entity_position :: proc(state: ^AppState, id: i32, pos: vec3) {
    for &e in state.entities {
        if e.id == id {
            e.transform.translation = pos
            break
        }
    }
}

import "core:fmt"

add_obj_model :: proc(data: OBJObjectData, state: ^AppState) {
    using state.renderer
    model: Model

    img_sizes: [4][2]i32
    i: int
    textures: [dynamic]^sdl.GPUTexture; defer if len(textures) == 0 do delete(textures)

    copy_commands := sdl.AcquireGPUCommandBuffer(gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)

    for i<len(data.texture_data.textures) {
        defer i += 1
        img_sizes[i] = data.texture_data.sizes[i]
        size := img_sizes[i]
        assert(size.x >= 1)
        assert(size.y >= 1)
        pixels := data.texture_data.textures[i]
        texture := upload_texture(gpu, copy_pass, pixels, transmute([2]u32)size)
        fmt.println("YES")

        append(&textures, texture)
    }
    model.textures = textures[:]
    bbox: AABB = {min = max(f32), max = min(f32)}
    for vert, v in data.vertices { // This seems very slow. Try making it branchless
        using vert
        if (position.x < bbox.min.x) do bbox.min.x = position.x;
        if (position.y < bbox.min.y) do bbox.min.y = position.y;
        if (position.z < bbox.min.z) do bbox.min.z = position.z;
        if (position.x > bbox.max.x) do bbox.max.x = position.x;
        if (position.y > bbox.max.y) do bbox.max.y = position.y;
        if (position.z > bbox.max.z) do bbox.max.z = position.z;
    }
    model.bbox = bbox

    // Create and upload buffers
    len_bytes := u32(len(data.vertices) * size_of(OBJVertex))
    material_matrices := make([dynamic][4]vec4, 0, len(data.materials)); defer delete(material_matrices)
    for material in data.materials do append(&material_matrices, material_matrix(material))
    transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = len_bytes,
    }); assert(transfer_buffer != nil)
    vbo              := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.VERTEX}, data.vertices[:])
    material_buffer  := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.GRAPHICS_STORAGE_READ}, material_matrices[:])
    model.num_vertices = u32(len(data.vertices))
    model.name = data.name

    // End copy pass
    sdl.ReleaseGPUTransferBuffer(gpu, transfer_buffer)
    sdl.EndGPUCopyPass(copy_pass)
    ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)

    // Assignments
    model.vbo = vbo
    model.material_buffer = material_buffer
    append(&state.models, model)
}

_get_bbox_vertices :: proc(bbox: AABB) -> [24]vec3 {
    using bbox
    return {
        vec3{min.x, min.y, min.z},
        vec3{max.x, min.y, min.z},

        vec3{max.x, max.y, min.z},
        vec3{min.x, max.y, min.z},

        vec3{min.x, min.y, min.z},
        vec3{min.x, min.y, max.z},

        vec3{max.x, min.y, max.z},
        vec3{min.x, min.y, max.z},

        vec3{max.x, max.y, max.z},
        vec3{min.x, max.y, max.z},

        vec3{max.x, min.y, max.z},
        vec3{max.x, min.y, min.z},

        vec3{max.x, max.y, min.z},
        vec3{max.x, max.y, max.z},

        vec3{min.x, max.y, min.z},
        vec3{min.x, max.y, max.z},
        
        // Vertical bars
        vec3{min.x, min.y, min.z},
        vec3{min.x, max.y, min.z},

        vec3{max.x, min.y, min.z},
        vec3{max.x, max.y, min.z},

        vec3{min.x, min.y, max.z},
        vec3{min.x, max.y, max.z},

        vec3{max.x, min.y, max.z},
        vec3{max.x, max.y, max.z},
    }
}