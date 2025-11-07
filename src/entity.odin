package obj_viewer

import sdl "vendor:sdl3"

Entity :: struct {
    id: i32,
    model: ^OBJModel,
    transform: Transform,
}

Transform :: struct {
    translation:    vec3,
    rotation:       vec3,
    scale:          vec3
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
    id = lowest_free_id(state.entities.id, len(state.entities))
    entity.id = id
    append_soa(&state.entities, entity)
    ok = true
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

// _add_obj_model :: proc(data: OBJObjectData, state: ^AppState) {
//     using state.renderer
//     model: Model

//     copy_commands := sdl.AcquireGPUCommandBuffer(gpu); assert(copy_commands != nil)
//     copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)

//     model.textures = make([]^sdl.GPUTexture, len(data.textures))
//     for texture, i in data.textures {
//         size: [2]u32 = {u32(texture.size.x), u32(texture.size.y)}
//         model.textures[i] = upload_texture(gpu, copy_pass, texture.image, size)
//     }

//     model.aabbs = make([]AABB, len(data.vertex_groups))
//     model.bbox_vbos = make([]^sdl.GPUBuffer, len(data.vertex_groups))

//     vertices: [dynamic]OBJVertex; defer delete(vertices)

//     for object, i in data.vertex_groups {
//         bbox: AABB = {min = max(f32), max = min(f32)}
//         for vert in object {
//             using vert
//             if (position.x < bbox.min.x) do bbox.min.x = position.x;
//             if (position.y < bbox.min.y) do bbox.min.y = position.y;
//             if (position.z < bbox.min.z) do bbox.min.z = position.z;
//             if (position.x > bbox.max.x) do bbox.max.x = position.x;
//             if (position.y > bbox.max.y) do bbox.max.y = position.y;
//             if (position.z > bbox.max.z) do bbox.max.z = position.z;
//             append(&vertices, vert)
//         }
//         model.aabbs[i] = bbox
//     }

//     // Create and upload buffers
//     material_matrices := make([][4]vec4, len(data.materials)); defer delete(material_matrices)
//     for material, i in data.materials do material_matrices[i] = material_matrix(material)

//     for object, i in data.vertex_groups {
//         len_bytes := u32(24 * size_of(vec3))
//         transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
//             usage = sdl.GPUTransferBufferUsage.UPLOAD,
//             size = len_bytes,
//         }); assert(transfer_buffer != nil)
//         bbox_vertices    := get_bbox_vertices(model.aabbs[i])
//         bbox_vbo         := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.VERTEX}, bbox_vertices[:])
//         model.bbox_vbos[i] = bbox_vbo
//         sdl.ReleaseGPUTransferBuffer(gpu, transfer_buffer)
//     }
//     transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
//         usage = sdl.GPUTransferBufferUsage.UPLOAD,
//         size = u32(len(vertices) * size_of(OBJVertex) + len(material_matrices) * size_of(vec4) * 4),
//     }); assert(transfer_buffer != nil)
//     vbo              := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.VERTEX}, vertices[:])
//     material_buffer  := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.GRAPHICS_STORAGE_READ}, material_matrices[:])
//     sdl.ReleaseGPUTransferBuffer(gpu, transfer_buffer)
//     model.name = data.name
//     model.vbo = vbo
//     model.num_vertices = u32(len(vertices))
//     model.material_buffer = material_buffer

//     // End copy pass
//     sdl.EndGPUCopyPass(copy_pass)
//     ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)

//     append(&state.models, model)
// }