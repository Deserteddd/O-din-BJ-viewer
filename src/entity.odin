package obj_viewer

import "core:fmt"

Entity :: struct {
    id: i32,
    name: string,
    model: ^OBJModel,
    transform: Transform,
}

Transform :: struct {
    translation:    vec3,
    scale:          vec3,
    rotation:       quaternion128,
}

spawn :: proc(scene: ^Scene, at_origin: bool) -> (id: i32, ok: bool) {
    if len(scene.models) > 0 {
        id = entity_from_model(scene, scene.models[0].name) or_return
        set_entity_transform(scene, id, get_player_translation().x)
        screen_size := get_window_size()
        origin, dir := ray_from_screen(screen_size/2, screen_size)
        set_entity_transform(scene, id, origin + 10*dir)
        ok = true
    }
    return
}

entity_from_model :: proc(scene: ^Scene, model_name: string, entity_name: string = "") -> (id: i32, ok: bool) {
    entity: Entity
    for &model in scene.models {
        if model.name == model_name {
            entity.model = &model
            break
        }
    }
    if entity.model == nil do return

    id = lowest_free_id(scene.entities.id, len(scene.entities))
    if entity_name == "" do entity.name = fmt.aprintf("%v-%v", model_name, id)
    else do entity.name = entity_name
    entity.id = id
    entity.transform.scale = 1
    append_soa(&scene.entities, entity)
    ok = true
    return
}

set_entity_transform :: proc(scene: ^Scene, id: i32, pos: vec3, scale: vec3 = 1) {
    for &e in scene.entities {
        if e.id == id {
            e.transform.translation = pos
            e.transform.scale       = scale
            break
        }
    }
}


remove_selected_entity :: proc(scene: ^Scene) -> bool {
    if g.editor.selected_entity == -1 do return false
    for e, i in scene.entities {
        if e.id == g.editor.selected_entity {
            unordered_remove_soa(&scene.entities, i)
        }
    }
    return true
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
