package obj_viewer

import "core:log"
import "core:time"
import "core:fmt"
import lg "core:math/linalg"
import rd "../Redef"
import im "shared:imgui"

import b3 "vendor:box3d"


g := struct {
    player:         		Player,
    renderer:       		Renderer,
    world:					World,
    selected_entity:       	EntityID,
    selected_material:     	MaterialID,
    frame:          		uint,
    ui_context:     		^im.Context,
    mouse_sense,
    dt:             		f32,
    time:           		time.Time,
    lmb_click,
    rmb_click,
    vsync,
    fullscreen,
    running: 				bool,
    draw_aabbs: 			bool,

} {
    mouse_sense = 0.04,
    running = true,
    vsync   = true,
    renderer = {
        options = {
            fog = true,
            fog_start = 40,
            fog_end = 160,
        }
    }
}

main :: proc() {
    context.logger = log.create_console_logger()
    init()
    scene := load_scene("savefile")
    run(&scene)
    rd.destroy_window()
}

init :: proc() {
    ok := rd.create_window("Demo window", 1280, 720, ODIN_DEBUG); assert(ok)
    rd.set_relative_mouse_mode()

    init_renderer()
    init_imgui()
    init_physics()

    add_player()

    rd.set_vsync(g.vsync)
    g.player.fov = 90
    g.time = time.now()
    g.draw_aabbs = true
}

run :: proc(scene: ^Scene) {
    now := time.now()
    fps: f64 = 60
    main_loop: for {
        defer {
            free_all(context.temp_allocator)
            g.frame += 1
            g.lmb_click = false
            g.rmb_click = false
            if g.frame % 20 == 0 {
                fps = 1000/(time.duration_milliseconds(time.since(now))/20)
                now = time.now()
            }
        }
        g.dt = f32(rd.get_dt() / 1000)
        for event in rd.pump_event_iter(){
            #partial switch ev in event {
                case rd.Quit:
                    break main_loop
                case rd.KeyboardEvent:
                    mod := ev.mod
                    if ev.type == .KeyDown do #partial switch ev.key {
                        case .ESCAPE:
                            if ev.type == .KeyDown {
                                g.running = !g.running
                                rd.set_relative_mouse_mode(g.running)
                            }
                        case .F2:
                            if ev.type == .KeyDown {
                                g.vsync = !g.vsync
                                rd.set_vsync(g.vsync)
                                log.debugf("Vsync %v", g.vsync ? "on" : "off")
                            }
                        case .E:
                            reset_player_pos()
                            g.player.noclip = false
                        case .C: if .CONTROL in mod do break main_loop
                        case .Q: if !g.player.airborne || g.player.noclip do g.player.checkpoint = get_player_translation()
                        case .N: g.player.noclip = !g.player.noclip
                        case .S: if .CONTROL in mod && !g.running do write_save_file(scene^)
                        case .NUM1: if len(scene.assets) > 0 do spawn_entity(scene, scene.assets[0].name, false, true)
                        case .NUM2: if len(scene.assets) > 1 do spawn_entity(scene, scene.assets[1].name, false, true)
                        case .NUM3: if len(scene.assets) > 2 do spawn_entity(scene, scene.assets[2].name, false, true)
                        case .NUM4: if len(scene.assets) > 3 do spawn_entity(scene, scene.assets[3].name, false, true)
                        case .NUM5: if len(scene.assets) > 4 do spawn_entity(scene, scene.assets[4].name, false, true)
                        case .NUM6: if len(scene.assets) > 5 do spawn_entity(scene, scene.assets[5].name, false, true)
                    }
                case rd.MouseEvent:
                #partial switch ev.type {
                    case .LPress: g.lmb_click = true
                    case .RPress: g.rmb_click = true
                }
            }
        }
        update(scene)
        rd.clear()
        draw_scene(scene)
        if g.draw_aabbs do draw_aabbs(scene)
        post_process()
        draw_text(fmt.aprintf("%v", i32(fps)), 0, ._12, {0, 1, 0})
        if !g.running do draw_imgui(scene)
        else do draw_sprite(g.renderer.crosshair)
        rd.frame_end()
    }
}

update :: proc(scene: ^Scene) -> (exit: bool) {

	b3.World_Step(g.world.world_id, g.dt, 4)
	for &entity, i in scene.entities {
		if entity.physics.b3 == {} {
			fmt.println(entity.physics)
		}
		entity.physics.position = b3.Body_GetPosition(entity.physics.b3.body)
		entity.physics.speed = b3.Body_GetLinearVelocity(entity.physics.b3.body)

		// Remove long gone entities
		if lg.distance(entity.physics.position, vec3{}) >= 500 {
			remove_entity(scene, entity.id)
		}
    }

    if !g.running {
        if g.lmb_click {
            mpos := rd.get_mouse_position()
            win_size := rd.get_window_size()
            if mpos.x < 300 || mpos.x > win_size.x - 300 do return // Check click in viewport
            ray_origin, ray_dir := ray_from_screen(mpos, win_size)
            closest_hit: f32 = max(f32)
            closest_entity: EntityID
            for &entity in scene.entities {
                ensure(entity.id != 0)
                intersection := ray_intersect_aabb(ray_origin, ray_dir, get_entity_aabb(entity))
                if intersection != -1 && intersection < closest_hit {
                    closest_hit = intersection
                    closest_entity = entity.id
                }
            }
            if closest_entity != 0 {
                g.selected_entity = closest_entity
            } else {
                g.selected_entity = 0
            }
        }
        return
    }
	update_camera()
   	update_player()

	return
}
update_ :: proc(scene: ^Scene) -> (exit: bool) {
    if !g.running {
        if g.lmb_click {
            mpos := rd.get_mouse_position()
            win_size := rd.get_window_size()
            if mpos.x < 300 || mpos.x > win_size.x - 300 do return // Check click in viewport
            ray_origin, ray_dir := ray_from_screen(mpos, win_size)
            closest_hit: f32 = max(f32)
            closest_entity: EntityID
            for &entity in scene.entities {
                ensure(entity.id != 0)
                intersection := ray_intersect_aabb(ray_origin, ray_dir, get_entity_aabb(entity))
                if intersection != -1 && intersection < closest_hit {
                    closest_hit = intersection
                    closest_entity = entity.id
                }
            }
            if closest_entity != 0 {
                g.selected_entity = closest_entity
            } else {
                g.selected_entity = 0
            }
        }
        return
    }
    p := &g.player
    update_camera()
    update_player()
    //
    if g.lmb_click {
        index := spawn_entity(scene, "mappi", true, false)
        scene.entities[index].physics.scale = {1, 0.2, 1}
        scene.entities[index].physics.position += {0, 2, 0}
    }

    proj_matrix := create_proj_matrix()
    view_matrix := create_view_matrix()
    vp := proj_matrix * view_matrix
    frustum := get_furustum_planes(vp)

    win_size := rd.get_window_size()
    origin, dir := ray_from_screen(win_size / 2, win_size)
    closest_hit: f32 = max(f32)
    closest_entity_index := -1
    found_collision: bool
    airborne_at_start := p.airborne

    for &entity, i in scene.entities {

        if entity.physics.b3 == {} do fmt.println(entity.asset_name)
        // Get aabb and check visibility
        aabb := get_entity_aabb(entity)
        entity.in_frustum = aabb_intersects_frustum(frustum,  aabb)

        // Check collisions
        if aabbs_collide(p.bbox, aabb) && !p.noclip {
            found_collision = true
            mtv := resolve_aabb_collision_mtv(p.bbox, aabb)
            for axis, j in mtv do if axis != 0 {
                p.speed[j] *= 0.9
                if j == 1 {
                    if axis > 0 {
                        p.airborne = false
                    } else {
                        p.speed.y = -0.1
                    }
                }
            }
            p.position += mtv
            p.bbox.min += mtv
            p.bbox.max += mtv
        }

        // Hit scan
        intersection := ray_intersect_aabb(origin, dir, get_entity_aabb(entity))
        if intersection != -1 && intersection < closest_hit {
            closest_hit = intersection
            closest_entity_index = i
        }
    }

    if !p.noclip {
        if !found_collision do g.player.airborne = true

        if !airborne_at_start && !p.airborne {
            p.speed *= 0.8
        }

        if lg.length(p.speed.xz) > 20 do p.speed.xz *= 0.9
    }

    if g.rmb_click do remove_entity_by_index(scene, closest_entity_index)

    g.renderer.p_light.position = g.player.position + {0, 2, 0}
    return
}

update_camera :: proc() {
    mouse_move := rd.get_relative_mouse_movement()
    mouse_move.x *= g.mouse_sense
    mouse_move.y *= g.mouse_sense
    g.player.rotation.y += mouse_move.x
    g.player.rotation.x = lg.min(g.player.rotation.x + mouse_move.y, 90)
    if g.player.rotation.x < -90 do g.player.rotation.x = -90
}