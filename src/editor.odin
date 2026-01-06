package obj_viewer

import "core:strings"
import "core:fmt"
import "core:log"
import sa "core:container/small_array"
import sdl "vendor:sdl3"
import im "shared:imgui"
import im_sdl "shared:imgui/imgui_impl_sdl3"
import im_sdlgpu "shared:imgui/imgui_impl_sdlgpu3"

Editor :: struct {
    selected_entity: i32,
    dragging:        bool,
    drag_position:   vec2,
    drag_start:      vec2,
    panels:          [PanelLocation]Panel,
}

PanelLocation :: enum {
    LEFT,
    RIGHT
}

Panel :: struct {
    rect: Rect,
}

update_editor :: proc(scene: ^Scene, keys: KeyboardEvents) -> (exit: bool) {
    for k in keys.data {
        #partial switch k.key {
            case .S:
                if .LCTRL in k.mod do write_save_file(scene^)
            case .C:
                if .LCTRL in k.mod do return true
            case .ESCAPE:
                if g.editor.dragging do stop_dragging() 
                else do toggle_mode()
            case .DELETE: remove_selected_entity(scene)
            case .RETURN: stop_dragging()
            case .DOWN: cycle_editor_selected(scene^)
            case .UP:   cycle_editor_selected(scene^, false)
            case .TAB:  
                cycle_editor_selected(scene^, .LSHIFT not_in k.mod)
        }
    } 
    if g.lmb_down {
        m_pos: vec2
        _ = sdl.GetMouseState(&m_pos.x, &m_pos.y)
        if !click(m_pos) {
            win_size := get_window_size()
            ray_origin, ray_dir := ray_from_screen(m_pos, win_size)
            closest_hit: f32 = max(f32)
            closest_entity: i32 = -1
            for &entity in scene.entities {
                aabbs := entity_aabbs(entity)
                for aabb in aabbs {
                    intersection := ray_intersect_aabb(ray_origin, ray_dir, aabb)
                    if intersection != -1 && intersection < closest_hit {
                        closest_hit = intersection
                        closest_entity = entity.id
                    }

                }
            }
            g.editor.selected_entity = closest_entity
        }
    }
    if g.editor.dragging {
        m_pos: vec2
        _ = sdl.GetRelativeMouseState(&m_pos.x, &m_pos.y)
        g.editor.drag_position += {m_pos.x, 0}
        io := im.GetIO()
        im.IO_AddMousePosEvent(io, g.editor.drag_position.x-g.editor.drag_position.y, g.editor.drag_position.y)
    }
    return
}

cycle_editor_selected :: proc(scene: Scene, forward := true) {
    using g.editor
    if forward {
        selected_entity += 1
        if int(selected_entity) > len(scene.entities) do selected_entity = 1
    } else {
        selected_entity -= 1
        if selected_entity == 0 do selected_entity = i32(len(scene.entities))
    }
}

// Return true if a UI element was clicked
click :: proc(m_pos: vec2) -> (clicked_ui_element: bool) {
    for panel, i in g.editor.panels {
        if !in_bounds(m_pos, panel.rect) do continue
        clicked_ui_element = true
    }
    return
}

init_editor :: proc(winsize: [2]i32) {
    using g.editor 
    panels[.LEFT] = {
        rect = {0, 0, 300, f32(winsize.y)},
    }
    panels[.RIGHT] = {
        rect = {f32(winsize.x)-300, 0, 300, f32(winsize.y)},
    }

}

start_dragging :: proc(loc := #caller_location) {
    if g.editor.dragging do return
    g.editor.dragging = true
    x, y: f32
    _ = sdl.GetMouseState(&x, &y)
    g.editor.drag_position = {x, y}
    g.editor.drag_start    = {x, y}
    ok := sdl.SetWindowRelativeMouseMode(g.window, true); assert(ok)
    _ = sdl.GetRelativeMouseState(nil, nil)
}

stop_dragging :: proc(loc := #caller_location) {
    if !g.editor.dragging do return
    g.editor.dragging = false
    g.editor.drag_position = 0
    ok := sdl.SetWindowRelativeMouseMode(g.window, false); assert(ok)
    sdl.WarpMouseInWindow(g.window, g.editor.drag_start.x, g.editor.drag_start.y)
}

draw_editor :: proc(frame: Frame) {
    bind_pipeline(frame, .QUAD)
    for panel in g.editor.panels {
        draw_rect(panel.rect, frame)
    }
}
draw_imgui :: proc(scene: ^Scene, frame: Frame) {
    im_sdlgpu.NewFrame()
    im_sdl.NewFrame()
    im.NewFrame()
    w, h: i32
    sdl.GetWindowSize(g.window, &w, &h)
    if g.mode == .EDIT {
        if im.Begin("properties", nil, {.NoTitleBar, .NoResize, .NoMove}) {
            defer im.End()
            im.SetWindowPos(0)
            im.SetWindowSize({g.editor.panels[.LEFT].rect.w, g.editor.panels[.RIGHT].rect.h})
            if im.BeginTabBar("PropertiesTabs") {
                defer im.EndTabBar()

                // --- General Tab ---
                if im.BeginTabItem("General") {
                    defer im.EndTabItem()
                    if im.DragFloat("FOV", &g.fov, 1, 50, 140) do start_dragging()
                    im.LabelText("", "Point Light")
                    if im.DragFloat("intensity", &g.renderer.light.power, 1, 0, 10000) do start_dragging()
                    im.ColorPicker3("color", &g.renderer.light.color, {.InputRGB})
                }
            }
        }
        if im.Begin("entities", nil, {.NoTitleBar, .NoResize, .NoMove}) {
            defer im.End()
            rect := g.editor.panels[.RIGHT].rect

            im.SetWindowPos({f32(w)-rect.w, 0})
            im.SetWindowSize({rect.w, rect.h})

            selected_entity_index: int
            if im.BeginListBox("Entities",) {
                for e, i in scene.entities {
                    im.PushIDInt(e.id)
                    name_cstr := strings.unsafe_string_to_cstring(e.name)
                    selected := g.editor.selected_entity == e.id
                    if im.Selectable(name_cstr, selected) {
                        g.editor.selected_entity = e.id
                    }
                    if selected {
                        im.ScrollToItem()
                        selected_entity_index = i
                    }
                    im.PopID()
                }
                im.EndListBox()
            }
            e := &scene.entities[selected_entity_index]
            if im.DragFloat3("Position", &e.transform.translation, 0.01) do start_dragging()
            if im.DragFloat3("Scale",    &e.transform.scale, 0.01) do start_dragging()
            for &axis in e.transform.scale do axis = max(0.01, axis)

        }
    } else if im.Begin("info", nil, {.NoTitleBar, .NoMouseInputs, .NoMove}) {

        im.SetWindowPos(vec2{f32(w-140), 0})
        im.SetWindowSize(vec2{140, 0})
        rendered := i32(g.debug_info.draw_call_count)
        im.SetNextItemWidth(50)
        im.DragInt("Draw calls", &rendered)
        im.SetNextItemWidth(50)
        im.LabelText("", "Player")
        im.DragFloat("Vel", &g.debug_info.player_speed)
        im.DragFloat("X", &g.player.position.x)
        im.DragFloat("Y", &g.player.position.y)
        im.DragFloat("Z", &g.player.position.z)
        im.End()
    }
    im.Render()
    im_draw_data := im.GetDrawData()
    im_sdlgpu.PrepareDrawData(im_draw_data, frame.cmd_buff)
    im_color_target := sdl.GPUColorTargetInfo {
        texture = frame.swapchain,
        load_op = .LOAD,
        store_op = .STORE
    }
    im_render_pass := sdl.BeginGPURenderPass(frame.cmd_buff, &im_color_target, 1, nil); assert(im_render_pass != nil)
    im_sdlgpu.RenderDrawData(im_draw_data, frame.cmd_buff, im_render_pass)
    sdl.EndGPURenderPass(im_render_pass)
}

init_imgui :: proc() {
    assert(g.window != nil)
    if g.ui_context != nil {
        im_sdlgpu.Shutdown()
        im_sdl.Shutdown()
        im.Shutdown()
        im.DestroyContext(g.ui_context)
    }
    im.CHECKVERSION()
    g.ui_context = im.CreateContext()
    im_sdl.InitForSDLGPU(g.window)
    im_sdlgpu.Init(&{
        Device = g.gpu,
        ColorTargetFormat = sdl.GetGPUSwapchainTextureFormat(g.gpu, g.window)
    })
    style := im.GetStyle()
    for &color in style.Colors {
        color.rgb = pow(color.rgb, 2.2)
    }
}