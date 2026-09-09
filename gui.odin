package obj_viewer

import "core:strings"
import rd "../Redef"
import lg "core:math/linalg"
import im "shared:imgui"
import im_d3d11 "shared:imgui/imgui_impl_dx11"
import im_win32 "shared:imgui/imgui_impl_win32"

init_imgui :: proc() {
    assert(rd.g.graphics_init)
    if g.ui_context != nil {
        im_win32.Shutdown()
        im_d3d11.Shutdown()
        im.Shutdown()
        im.DestroyContext(g.ui_context)
    }
    im.CHECKVERSION()
    g.ui_context = im.CreateContext()
	ok := im_win32.Init(auto_cast rd.g.window.handle); assert(ok)
	ok = im_d3d11.Init(rd.g.graphics.device, rd.g.graphics.ctx); assert(ok)
}
import "core:log"

draw_imgui :: proc(scene: ^Scene) {
	io := im.GetIO()
	io.DisplaySize = rd.get_window_size()
	io.DeltaTime = lg.max(g.dt, 1.0 / 1000.0)

	im_win32.NewFrame()
    im_d3d11.NewFrame()
    im.NewFrame()
    if im.Begin("Left panel", nil, {.NoTitleBar, .NoResize, .NoMove}) {
        defer im.End()
        im.SetWindowPos({0, 0})
        im.SetWindowSize({300, io.DisplaySize.y})
        if im.BeginTabBar("PropertiesTabs") {
            defer im.EndTabBar()

            // --- General Tab ---
            if im.BeginTabItem("General") {
                defer im.EndTabItem()
                im.DragFloat("FOV", &g.player.fov, 1, 50, 140)
                im.DragFloat("Mouse sense", &g.mouse_sense, 0.001, 0.001, 0.1)
                if im.Button("Recompile shaders") do compile_shaders()
                fog := &g.renderer.options
                im.Checkbox("Fog", &fog.fog)
                if fog.fog {
                    im.DragFloat("Near", &fog.fog_start, 1, 0, 200)
                    if fog.fog_start > fog.fog_end {
                        fog.fog_end = fog.fog_start
                    }
                    im.DragFloat("Far", &fog.fog_end, 1, 0, 200)
                    if fog.fog_start > fog.fog_end {
                        fog.fog_start = fog.fog_end
                    }
                }
                im.Checkbox("Draw AABBs", &g.draw_aabbs)
                im.LabelText("", "Point Light")
                im.DragFloat("intensity", &g.renderer.p_light.power, 1, 0, 10000)
                im.ColorPicker3("color", &g.renderer.p_light.color, {.InputRGB})
            }
        }
    }
	if im.Begin("Right panel", nil, {.NoTitleBar, .NoResize, .NoMove}) {
		rect := Rect{f32(io.DisplaySize.x)-300, 0, 300, f32(io.DisplaySize.y)}
        im.SetWindowPos({io.DisplaySize.x-rect.w, 0})
        im.SetWindowSize({rect.w, rect.h})
        if im.BeginTabBar("##") {
            defer im.EndTabBar()
            selected_entity_index := -1
            entities_tab(scene, rect, &selected_entity_index)

            selected_material_index := -1
            materials_tab(scene, rect, &selected_material_index)
        }

        im.End()
        im.Render()
        im_draw_data := im.GetDrawData(); assert(im_draw_data != nil)

        im_d3d11.RenderDrawData(im_draw_data)
    }
}

import "core:fmt"

materials_tab :: proc(scene: ^Scene, rect: Rect, selected_material_index: ^int) {
    if im.BeginTabItem("Materials") {
        defer im.EndTabItem()
        if im.BeginListBox(" ", {rect.w-rect.w/10, rect.h/8}) {
            for ro, i in scene.renderables {
                im.PushIDInt(i32(ro.materials.id))
                name_cstr := strings.unsafe_string_to_cstring(fmt.aprintf("material-%v", ro.materials.id))
                selected := ro.materials.id == g.selected_material
                if im.Selectable(name_cstr, selected) {
                    g.selected_material = ro.materials.id
                }
                if selected {
                    // im.ScrollToItem()
                    selected_material_index^ = i
                }
                im.PopID()
            }
            im.EndListBox()
        }
        // Selected material options
        if selected_material_index^ != -1 && im.BeginChild("Lapsonen") {
            update_params_buff: bool
            defer im.EndChild()
            im.Separator()
            s := &scene.renderables[selected_material_index^]
            im.LabelText("", "Physics")

            im.Separator()
            if im.Button("Delete") {
                ok := remove_entity(scene, g.selected_entity)
                assert(ok)
            }

            im.LabelText("##", "Params")

            base_color := &s.materials.params[0].base_color_factor
            if im.ColorPicker4("Base color", base_color) {
                update_params_buff = true
            }

            if update_params_buff {
                rd.destroy(s.materials.params_buffer)
                s.materials.params_buffer = rd.create_structured_buffer(s.materials.params, {.Pixel})
            }
        }
    }
}

entities_tab :: proc(scene: ^Scene, rect: Rect, selected_entity_index: ^int) {
    // Entities Tab
    if im.BeginTabItem("Entities") {
        defer im.EndTabItem()

        if im.BeginListBox(" ", {rect.w-rect.w/10, rect.h/8}) {
            for e, i in scene.entities {
                im.PushIDInt(i32(e.id))
                name_cstr := strings.unsafe_string_to_cstring(e.name)
                selected := e.id == g.selected_entity
                if im.Selectable(name_cstr, selected) {
                    g.selected_entity = e.id
                }
                if selected {
                    // im.ScrollToItem()
                    selected_entity_index^ = i
                }
                im.PopID()
            }
            im.EndListBox()
        }
        // Selected entity options
        if selected_entity_index^ != -1 && im.BeginChild("Lapsonen") {
        	selected_index := selected_entity_index^
	        s := scene.entities[selected_index]
            defer {
	            scene.entities[selected_index] = s // Dumb hack to work with soa pointers
            	im.EndChild()
             	for &axis in s.physics.scale do axis = max(0.01, axis)
            }
            im.Separator()
            im.LabelText("", "Physics")
            if im.DragFloat3("Position", &s.physics.position, 0.01) {
            	set_physics_position(&s)
            }
            im.DragFloat3("Scale",    &s.physics.scale, 0.01)
            im.Separator()
            if im.Button("Delete") {
                ok := remove_entity(scene, g.selected_entity)
                assert(ok)
            }
            if im.Button("Duplicate") {
                index := entity_from_asset(scene, s.asset_name)
                offset := s.physics.aabb.min * 2 * s.physics.scale
                scene.entities[index].physics = s.physics
                scene.entities[index].physics.position += {offset.x, 0, 0}
                scene.entities[index].in_frustum = true


                g.selected_entity = scene.entities[index].id
            }

            if im.Checkbox("Dynamic", &s.physics.dyn) do add_physics_body(&s)

            im.LabelText("##", "Material overrides")
            // Color override
            {
                enabled := .Color in s.material_overrides.attributes
                if im.Checkbox("Color", &enabled) {
                    if enabled do s.material_overrides.attributes += {.Color}
                    else do s.material_overrides.attributes -= {.Color}
                }
                if enabled do im.ColorEdit4("##", &s.material_overrides.color)
            }

            // Metal override
            {
                enabled := .Metallic in s.material_overrides.attributes
                if im.Checkbox("Metal", &enabled) {
                    if enabled do s.material_overrides.attributes += {.Metallic}
                    else do s.material_overrides.attributes -= {.Metallic}
                }
                if enabled do im.SliderFloat("##", &s.material_overrides.metallic, 0, 1);
            }

            // Rough override
            {
                enabled := .Roughness in s.material_overrides.attributes
                if im.Checkbox("Rough", &enabled) {
                    if enabled do s.material_overrides.attributes += {.Roughness}
                    else do s.material_overrides.attributes -= {.Roughness}
                }
                if enabled do im.SliderFloat("###", &s.material_overrides.roughness, 0, 1);
            }


        }
    }
}