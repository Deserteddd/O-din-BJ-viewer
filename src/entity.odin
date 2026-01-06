package obj_viewer

import "core:fmt"
import "core:slice"

EntityID :: distinct i32

Entity :: struct {
    id: EntityID,
    name: string,
    model: ^OBJModel,
    transform: Transform,
}

Transform :: struct {
    translation:    vec3,
    scale:          vec3,
    rotation:       quaternion128,
}

spawn :: proc(scene: ^Scene, under_player: bool) -> (id: EntityID, ok: bool) {
    if len(scene.models) > 0 {
        id = entity_from_model(scene, scene.models[0].name) or_return
        if under_player {
            set_entity_transform(scene, id, get_player_translation().x)
        } else {
            screen_size := get_window_size()
            origin, dir := ray_from_screen(screen_size/2, screen_size)
            set_entity_transform(scene, id, origin + 10*dir)
        }
        ok = true
    }
    return
}

entity_from_model :: proc(scene: ^Scene, model_name: string, entity_name: string = "") -> (id: EntityID, ok: bool) {
    entity: Entity
    for &model in scene.models {
        if model.name == model_name {
            entity.model = &model
            break
        }
    }
    if entity.model == nil do return
    ids := slice.from_ptr(scene.entities.id, len(scene.entities))
    id = lowest_free_id(ids)
    if entity_name == "" do entity.name = fmt.aprintf("%v-%v", model_name, id)
    else do entity.name = entity_name
    entity.id = id
    entity.transform.scale = 1
    append_soa(&scene.entities, entity)
    ok = true
    return
}

set_entity_transform :: proc(scene: ^Scene, id: EntityID, pos: vec3, scale: vec3 = 1) {
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
            ordered_remove_soa(&scene.entities, i)
        }
    }
    return true
}

lowest_free_id :: proc(ids: []EntityID) -> EntityID {
    len := len(ids)
    for &val, i in ids {
        for {
            // val := ids[i];
            if val <= 0 || int(val) > len {
                break;
            }
            correct_index := val - 1;
            if ids[correct_index] == val {
                break;
            }
            temp := val;
            val = ids[correct_index];
            ids[correct_index] = temp;
        }
    }

    for val, i in ids {
        if int(val) != i + 1 {
            return EntityID(i + 1);
        }
    }

    return EntityID(len + 1);
}
