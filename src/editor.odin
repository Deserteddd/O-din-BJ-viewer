package obj_viewer

import "core:time"
import "core:fmt"
import sdl "vendor:sdl3"
import im "shared:imgui"
import im_sdl "shared:imgui/imgui_impl_sdl3"
import im_sdlgpu "shared:imgui/imgui_impl_sdlgpu3"

Editor :: struct {
    selected_entity: i32,
    sidebar_left:    Panel,
    sidebar_right:   Panel,
    dragging:        bool,
    drag_position:   vec2,
    drag_start:      vec2,
}

Panel :: struct {
    rect: Rect,
}

update_editor :: proc(state: ^AppState, keys: KeyboardEvents) -> (exit: bool) {
    using state
    for elem in 0..<keys.len {
        key := keys.data[elem].key
        mod := keys.data[elem].mod
        #partial switch key {
            case .S:
                if .LCTRL in mod do write_save_file(state^)
            case .C:
                if .LCTRL in mod do return true
            case .ESCAPE:
                if editor.dragging {
                    stop_dragging(&editor) 
                } else {
                    toggle_mode(state)
                }
            case .DELETE:
                remove_selected_entity(state)
            case .RETURN:
                stop_dragging(&editor)
        }
    } 
    if g.lmb_down {
        fmt.println("Yess")
        m_pos: vec2
        win_size := get_window_size()
        _ = sdl.GetMouseState(&m_pos.x, &m_pos.y)
        if m_pos.x > editor.sidebar_left.rect.w && m_pos.x < editor.sidebar_right.rect.x {
            ray_origin, ray_dir := ray_from_screen(player, m_pos, win_size)
            closest_hit: f32 = max(f32)
            closest_entity: i32 = -1
            for &entity in entities {
                aabbs := entity_aabbs(entity)
                for aabb in aabbs {
                    intersection := ray_intersect_aabb(ray_origin, ray_dir, aabb)
                    if intersection != -1 && intersection < closest_hit {
                        closest_hit = intersection
                        closest_entity = entity.id
                    }

                }
            }
            editor.selected_entity = closest_entity
        }
    }
    if editor.dragging {
        m_pos: vec2
        _ = sdl.GetRelativeMouseState(&m_pos.x, &m_pos.y)
        editor.drag_position += m_pos
        io := im.GetIO()
        im.IO_AddMousePosEvent(io, editor.drag_position.x-editor.drag_position.y, editor.drag_position.y)
    }
    return
}

editor_init :: proc()

start_dragging :: proc(editor: ^Editor) {
    editor.dragging = true
    x, y: f32
    _ = sdl.GetMouseState(&x, &y)
    editor.drag_position = {x, y}
    editor.drag_start    = {x, y}
    ok := sdl.SetWindowRelativeMouseMode(g.window, true); assert(ok)
    _ = sdl.GetRelativeMouseState(nil, nil)
}

stop_dragging :: proc(editor: ^Editor) {
    if !editor.dragging do return
    editor.dragging = false
    editor.drag_position = 0
    ok := sdl.SetWindowRelativeMouseMode(g.window, false); assert(ok)
    sdl.WarpMouseInWindow(g.window, editor.drag_start.x, editor.drag_start.y)
}

draw_editor :: proc(editor: ^Editor, frame: Frame) {
    draw_rect(editor.sidebar_left.rect, frame)
    draw_rect(editor.sidebar_right.rect, frame)
}

draw_imgui :: proc(state: ^AppState, frame: Frame) {
    using state, frame
    im_sdlgpu.NewFrame()
    im_sdl.NewFrame()
    im.NewFrame()
    if g.mode == .EDIT {
        if im.Begin("Properties", nil, {.NoTitleBar, .NoResize, .NoMove}) {
            im.SetWindowPos(0)
            im.SetWindowSize({editor.sidebar_left.rect.w, editor.sidebar_left.rect.h})
            if im.BeginTabBar("PropertiesTabs") {
                defer im.EndTabBar()
                if im.BeginTabItem("Entity") {
                    defer im.EndTabItem()
                    for &e in entities {
                        if e.id == editor.selected_entity {
                            if im.DragFloat3("Position", &e.transform.translation, 0.01) do editor.dragging = true
                            if im.DragFloat3("Scale",    &e.transform.scale, 0.01) do editor.dragging = true
                            for &axis in e.transform.scale do axis = max(0.01, axis)
                            break
                        }
                    }
                }

                // --- General Tab ---
                if im.BeginTabItem("General") {
                    defer im.EndTabItem()
                    im.LabelText("", "General")
                    if im.DragFloat("FOV", &g.fov, 1, 50, 140) do editor.dragging = true
                    im.LabelText("", "Point Light")
                    if im.DragFloat("intensity", &renderer.light.power, 1, 0, 10000) do editor.dragging = true
                    im.ColorPicker3("color", &renderer.light.color, {.InputRGB})
                }
            }
        }
    } else if im.Begin("info", nil, {.NoTitleBar, .NoMouseInputs, .NoMove}) {
        w, h: i32
        sdl.GetWindowSize(g.window, &w, &h)
        im.SetWindowPos(vec2{f32(w-140), 0})
        im.SetWindowSize(vec2{140, 0})
        frame_time_float := i32(round(1/f32(time.duration_seconds(debug_info.frame_time))))
        im.SetNextItemWidth(50)
        im.DragInt("FPS", &frame_time_float)
        rendered := i32(debug_info.draw_call_count)
        im.SetNextItemWidth(50)
        im.DragInt("Draw calls", &rendered)
        im.SetNextItemWidth(50)
        im.LabelText("", "Player")
        im.DragFloat("Vel", &debug_info.player_speed)
        im.DragFloat("X", &player.position.x)
        im.DragFloat("Y", &player.position.y)
        im.DragFloat("Z", &player.position.z)
    }
    im.End()
    im.Render()
    im_draw_data := im.GetDrawData()
    im_sdlgpu.PrepareDrawData(im_draw_data, cmd_buff)
    im_color_target := sdl.GPUColorTargetInfo {
        texture = swapchain,
        load_op = .LOAD,
        store_op = .STORE
    }
    im_render_pass := sdl.BeginGPURenderPass(cmd_buff, &im_color_target, 1, nil); assert(im_render_pass != nil)
    im_sdlgpu.RenderDrawData(im_draw_data, cmd_buff, im_render_pass)
    sdl.EndGPURenderPass(im_render_pass)
}

init_imgui :: proc(state: ^AppState) {
    assert(g.window != nil)
    if state.ui_context != nil {
        im_sdlgpu.Shutdown()
        im_sdl.Shutdown()
        im.Shutdown()
        im.DestroyContext(state.ui_context)
    }
    im.CHECKVERSION()
    state.ui_context = im.CreateContext()
    using state.renderer
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