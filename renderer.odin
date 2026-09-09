package obj_viewer


import rd "../Redef"
import lg "core:math/linalg"
import "core:time"
import "core:log"
import "core:os"



PointLight :: struct {
	position: vec3,
	power:    f32,
	color:    vec3,
}

FragUBOGlobal :: struct {
	light_pos:       vec3,
	_:               f32,
	light_color:     vec3,
	light_intensity: f32,
	view_pos:        vec3,
	_:				 f32
}

VertexAABB :: struct {
	position: vec3,
}

Frame :: struct {
	frustum_planes: [6]vec4,
}

Camera :: struct {
	position: vec3,
	pitch:    f32,
	yaw:      f32,
}


Renderer :: struct {
	vs_ui:            rd.VertexShader,
	ps_ui:            rd.PixelShader,
	vs_text:          rd.VertexShader,
	ps_text:          rd.PixelShader,
	vs_gfx:           rd.VertexShader,
	ps_gfx:           rd.PixelShader,
	vs_skybox:        rd.VertexShader,
	ps_skybox:        rd.PixelShader,
	vs_aabb:          rd.VertexShader,
	ps_aabb:          rd.PixelShader,
	vs_ocean:         rd.VertexShader,
	ps_ocean:         rd.PixelShader,
	fallback_texture: rd.Texture,
	skybox_texture:   rd.TextureCube,
	p_light:          PointLight,
	crosshair:        rd.Texture,
	quad:             Quad,
	plane:			  Plane,
	font_atlases:	  [FontSize]rd.Texture,

	ps_fog:  		  rd.PixelShader,

    options: struct {
        fog: bool,
        fog_start,
        fog_end: f32
    }
}


init_renderer :: proc() {
	r := &g.renderer
	ok: bool

    compile_shaders()

	r.quad = init_quad()
	r.crosshair =  load_sprite("assets/images/crosshair.png")

	r.font_atlases = {
		._8  = load_sprite("assets/images/DejaVu Sans Mono-8.png"),
		._10 = load_sprite("assets/images/DejaVu Sans Mono-10.png"),
		._12 = load_sprite("assets/images/DejaVu Sans Mono-12.png"),
		._14 = load_sprite("assets/images/DejaVu Sans Mono-14.png"),
		._16 = load_sprite("assets/images/DejaVu Sans Mono-16.png"),
	}



	r.skybox_texture = load_cubemap_texture(
		{
			.PX = "assets/images/skybox_sea/px.png",
			.NX = "assets/images/skybox_sea/nx.png",
			.PY = "assets/images/skybox_sea/py.png",
			.NY = "assets/images/skybox_sea/ny.png",
			.PZ = "assets/images/skybox_sea/pz.png",
			.NZ = "assets/images/skybox_sea/nz.png",
		},
	)

	r.plane = new_plane(200)

	r.p_light.color = 1

}

compile_shaders :: proc() {
	r := &g.renderer

    defer free_all(context.temp_allocator)
    load_shader :: proc(path: string, loc := #caller_location) -> []byte {
        data, err := os.read_entire_file_from_path(path, context.temp_allocator)
        if err != nil {
            log.errorf("Error reading shader file: %v", path, location = loc)
        }
        return data
    } 

    shader_2D       := load_shader(resolve_project_path("shaders/2D.hlsl"))
    shader_text     := load_shader(resolve_project_path("shaders/text.hlsl"))
    shader_gfx      := load_shader(resolve_project_path("shaders/gfx.hlsl"))
    shader_skybox   := load_shader(resolve_project_path("shaders/skybox.hlsl"))
    shader_aabb     := load_shader(resolve_project_path("shaders/aabb.hlsl"))
    shader_ocean    := load_shader(resolve_project_path("shaders/ocean.hlsl"))

    compile_vs :: proc(
        shader: ^rd.VertexShader, 
        data: []byte, 
        entry: string, 
        $vertex_type: typeid) 
    {
        if shader.shader != nil do rd.destroy(shader)
        ok: bool
        shader^, ok = rd.load_vertex_shader(data, entry, vertex_type); assert(ok)
    }

    compile_ps :: proc(shader: ^rd.PixelShader, data: []byte, entry: string) {
        if shader^ != nil do rd.destroy(shader)
        ok: bool
        shader^, ok = rd.load_pixel_shader(data, entry); assert(ok)
    }

    compile_vs(&r.vs_ui, shader_2D, "vs_main", Vertex2D)
	compile_ps(&r.ps_ui, shader_2D, "ps_main")

	compile_vs(&r.vs_text, shader_text, "vs_main", Vertex2D)
	compile_ps(&r.ps_text, shader_text, "ps_main")

	compile_vs(&r.vs_gfx, shader_gfx, "vs_main", Vertex)
	compile_ps(&r.ps_gfx, shader_gfx, "ps_main")

	compile_vs(&r.vs_skybox, shader_skybox, "vs_main", None)
	compile_ps(&r.ps_skybox, shader_skybox, "ps_main")

	compile_vs(&r.vs_aabb, shader_aabb, "vs_main", VertexAABB)
	compile_ps(&r.ps_aabb, shader_aabb, "ps_main")

	compile_vs(&r.vs_ocean, shader_ocean, "vs_main", VertexAABB)
	compile_ps(&r.ps_ocean, shader_ocean, "ps_main")

	compile_ps(&r.ps_fog, shader_2D, "ps_fog")
}

import "core:hash"
import "core:slice"

create_render_object :: proc(asset: ^Asset) -> Renderable {
	assert(asset != nil)
	ro: Renderable
	ro.vbo = rd.create_vertex_buffer(asset.data.vertices)
	ro.ibo = rd.create_index_buffer(asset.data.indices)
	ro.materials = MaterialCollection {
        id = MaterialID(hash.adler32(transmute([]byte)asset.name)),
        params = slice.clone(asset.data.materials),
        params_buffer = rd.create_structured_buffer(asset.data.materials, {.Pixel}),
    }

	primitives: [dynamic]Primitive
	for p in asset.data.primitives {
		append(&primitives, p)
	}
	ro.primitives = primitives[:]

	if len(asset.data.textures) > 0 {
		width := asset.data.textures[0].width
		height := asset.data.textures[0].height
		ro.materials.textures = rd.create_texture_buffer(asset.data.images, width, height)
	}

	aabb_verts := aabb_vertices(asset.data.header.aabb)
	ro.aabb = rd.create_vertex_buffer(aabb_verts[:])

	return ro
}

create_frag_ubo :: #force_inline proc() -> FragUBOGlobal {
	return FragUBOGlobal {
		view_pos = camera_position(),
		light_pos = g.renderer.p_light.position,
		light_color = g.renderer.p_light.color,
		light_intensity = g.renderer.p_light.power,
	}
}

draw_scene :: proc(scene: ^Scene) {
	proj_matrix := create_proj_matrix()
	view_matrix := create_view_matrix()
	vp := proj_matrix * view_matrix
	rd.push_constant_data(.Vertex, &vp, 0)

	frag_ubo := create_frag_ubo()
	rd.push_constant_data(.Pixel, &frag_ubo, 0)

	rd.bind(&g.renderer.skybox_texture, 0)
	rd.set_blend_mode(.Opaque)
	for &ro in scene.renderables {
		rd.bind(&g.renderer.vs_gfx)
		rd.bind(&g.renderer.ps_gfx)
		rd.bind(&ro.materials.textures, 1)
		rd.bind(&ro.materials.params_buffer, 2)
		rd.bind(&ro.vbo)
		rd.bind(&ro.ibo)

		for entity in scene.entities {
			if entity.renderable != &ro do continue
            // if !entity.in_frustum do continue
            override_values := entity.material_overrides
            rd.push_constant_data(.Pixel, &override_values, 2)

			model_matrix := lg.matrix4_from_trs(
				entity.physics.position,
				entity.physics.rotation,
				entity.physics.scale,
			)

			// material_overrides := transmute(u32)entity.material_overrides
            // rd.push_constant_data(.Pixel, &material_overrides, 2)
			rd.push_constant_data(.Vertex, &model_matrix, 1)
			for &primitive in ro.primitives {
				rd.push_constant_data(.Pixel, &primitive.material_id, 1)
				rd.draw_indexed(primitive.index_start, primitive.index_count)
			}

			// Selected entity's 
			if !g.running && g.selected_entity == entity.id {
				rd.bind(&g.renderer.vs_aabb); defer rd.bind(&g.renderer.vs_gfx)
				rd.bind(&g.renderer.ps_aabb); defer rd.bind(&g.renderer.ps_gfx)
				rd.bind(&ro.aabb); defer rd.bind(&ro.vbo)
                model_matrix = lg.matrix4_from_trs(
                    entity.physics.position,
                    lg.QUATERNIONF32_IDENTITY,
                    entity.physics.scale,
                )
			    rd.push_constant_data(.Vertex, &model_matrix, 1)
                select: b32 = true
                rd.push_constant_data(.Pixel, &select, 1)
				rd.set_primitive_topology(.lineList); defer rd.set_primitive_topology(.triangleList)
				rd.draw(24)
	            rd.push_constant_data(.Pixel, &frag_ubo, 0)

			}
		}
	}

    // Ocean
	// rd.bind(&g.renderer.ps_ocean)
	// rd.bind(&g.renderer.vs_ocean)
	// rd.bind(&g.renderer.plane.vbo)
	// rd.bind(&g.renderer.plane.ibo)

	// time := time.duration_seconds(time.since(g.time))
	// rd.push_constant_data(.Vertex, &time, 1)

	// ocean_ubo := struct {
	// 	vp: matrix[4,4]f32,
	// 	position: vec2
	// } {
	// 	vp, g.player.position.xz
	// }

    // rd.push_constant_data(.Vertex, &ocean_ubo, 0)
    // rd.draw_indexed(0, g.renderer.plane.num_indices)


    // Skybox
	inv_view_mat := lg.inverse(view_matrix)
	inv_proj_mat := lg.inverse(proj_matrix)
	inv_matricies: struct {v: mat4, p: mat4} = {inv_view_mat, inv_proj_mat}

	rd.push_constant_data(.Vertex, &inv_matricies, 0)
	rd.set_blend_mode(.Skybox)
    rd.bind(&g.renderer.skybox_texture, 1)
	rd.bind(&g.renderer.vs_skybox)
	rd.bind(&g.renderer.ps_skybox)
	rd.draw(3)
}

draw_aabbs :: proc(scene: ^Scene) {
	proj_matrix := create_proj_matrix()
	view_matrix := create_view_matrix()
	vp := proj_matrix * view_matrix
	rd.push_constant_data(.Vertex, &vp, 0)

    rd.bind(&g.renderer.vs_aabb)
    rd.bind(&g.renderer.ps_aabb)
    rd.set_primitive_topology(.lineList); defer rd.set_primitive_topology(.triangleList)

    for entity in scene.entities {
        if entity.renderable == nil do continue
        // if !entity.in_frustum do continue

        rd.bind(&entity.renderable.aabb);
        model_matrix := lg.matrix4_from_trs(
            entity.physics.position,
            lg.QUATERNIONF32_IDENTITY,
            entity.physics.scale,
        )
        rd.push_constant_data(.Vertex, &model_matrix, 1)
        select: b32 = entity.id == g.selected_entity
        rd.push_constant_data(.Pixel, &select, 1)
        rd.draw(24)
    }
}

import d3d "vendor:directx/d3d11"
post_process :: proc() {

	// Apply fog
    if g.renderer.options.fog {
	win_size := rd.get_window_size()
	ubo := UBO2D {
		rect     = {0, 0, win_size.x, win_size.y},
		win_size = win_size,
		use_tex  = true,
	}
	depth_texture := rd.get_depth_texture()

	view_matrix := create_view_matrix()
	proj_matrix := create_proj_matrix()
	
	inv_view_mat := lg.inverse(view_matrix)
	inv_proj_mat := lg.inverse(proj_matrix)
	b0: struct {_: mat4, _: mat4, _, _: f32} = {
        inv_view_mat, 
        inv_proj_mat, 
        g.renderer.options.fog_start,
        g.renderer.options.fog_end
    }

	r := &g.renderer
	rd.g.graphics.ctx->OMSetRenderTargets(1, &rd.g.graphics.target, nil)
	rd.set_blend_mode(.Alpha)
	rd.bind(&r.vs_ui)
	rd.bind(&g.renderer.ps_fog)
	rd.bind(&r.quad.vbo)
	rd.bind(&r.quad.ibo)
	rd.bind(depth_texture, 0)
	rd.push_constant_data(.Vertex, &ubo, 0)
	rd.push_constant_data(.Pixel, &b0, 0)
	rd.draw_indexed(0, 6)
	rd.g.graphics.ctx->OMSetRenderTargets(1, &rd.g.graphics.target, rd.g.graphics.dsv)
    }
}



get_furustum_planes :: proc(vp: matrix[4, 4]f32) -> [6]vec4 {
	t := lg.transpose(vp)
	return {t[3] + t[0], t[3] + t[0], t[3] + t[1], t[3] + t[1], t[3] + t[2], t[3] + t[2]}
}


create_view_matrix :: proc() -> lg.Matrix4f32 {
	pitch_matrix := lg.matrix4_rotate_f32(to_radians(g.player.rotation.x), {1, 0, 0})
	yaw_matrix := lg.matrix4_rotate_f32(to_radians(g.player.rotation.y), {0, 1, 0})
	position_matrix := lg.inverse(lg.matrix4_translate_f32(camera_position()))
	return pitch_matrix * yaw_matrix * position_matrix
}

create_proj_matrix :: proc(loc := #caller_location) -> mat4 {
	win_size := rd.get_window_size()
	aspect := win_size.x / win_size.y
	return lg.matrix4_perspective_f32(to_radians(g.player.fov), aspect, 0.01, 1000)
}

// ----------------------------
//        2D Renderer
// ----------------------------
Vertex2D :: struct {
	position: vec2,
	uv:       vec2,
}

Rect :: struct {
	x, y, w, h: f32,
}

Quad :: struct {
	vbo: rd.VertexBuffer,
	ibo: rd.IndexBuffer,
}

UBO2D :: struct {
	rect:     Rect,
	win_size: vec2,
	use_tex:  b32,
	color:    vec4,
}


TextUBO :: struct {
	win_size: vec2,
	pos:	  vec2,
	src:	  Rect,
	tex_size: vec2
}

FontSize :: enum {
	_8,
	_10,
	_12,
	_14,
	_16
}

init_quad :: proc() -> Quad {
	verts := [4]Vertex2D {
		Vertex2D{{-1, -1}, {0, 0}}, // Bottom-left
		Vertex2D{{1, -1}, {1, 0}}, // Bottom-right
		Vertex2D{{1, 1}, {1, 1}}, // Top-right
		Vertex2D{{-1, 1}, {0, 1}}, // Top-left
	}
	indices := [6]u16 {
		0,
		2,
		1, // First triangle
		2,
		0,
		3, // Second triangle
	}

	vbo := rd.create_vertex_buffer(verts[:])
	ibo := rd.create_index_buffer(indices[:])
	return Quad{vbo, ibo}
}

draw_sprite :: proc(sprite: rd.Texture, pos: vec2 = 0, scale: f32 = 1) {
	rd.set_blend_mode(.Alpha)
	sprite := sprite
	win_size := rd.get_window_size()

	x := pos == 0 ? win_size.x / 2 - f32(sprite.width) / 2 : pos.x
	y := pos == 0 ? win_size.y / 2 - f32(sprite.height) / 2 : pos.y

	ubo := UBO2D {
		rect     = {x, y, f32(sprite.width) * scale, f32(sprite.height) * scale},
		win_size = win_size,
		use_tex  = true,
	}

	r := &g.renderer
	rd.bind(&r.vs_ui)
	rd.bind(&r.ps_ui)
	rd.bind(&r.quad.vbo)
	rd.bind(&r.quad.ibo)
	rd.bind(&sprite)
	rd.push_constant_data(.Vertex, &ubo, 0)
	rd.draw_indexed(0, 6)
}


draw_text :: proc(text: string, pos: vec2, size: FontSize, color: vec3) {
	rd.set_blend_mode(.Alpha)
	sprite := g.renderer.font_atlases[size]
    color := color
	win_size := rd.get_window_size()

	r := &g.renderer
	rd.bind(&r.vs_text)
	rd.bind(&r.ps_text)
	rd.bind(&r.quad.vbo)
	rd.bind(&r.quad.ibo)
	rd.bind(&sprite)

	get_atlas_position :: proc(c: rune) -> vec2 {
		col := int(c)/16
		row := int(c)%16
		return {f32(row), f32(col)}
	}

	col: f32 = 0
	row: f32 = 0
	for char, i in text {
		if char == '\n' {
			row += 1
			col = 0
			continue
		}
		defer col += 1
		atlas_slot := get_atlas_position(char)
		ubo := TextUBO {
			win_size = win_size,
			src      = {
				atlas_slot.x*32+1, atlas_slot.y*32+1, 
				f32(sprite.width)/16-1, f32(sprite.height)/16-1
			},
			tex_size = {f32(sprite.width), f32(sprite.height)},
			pos		 = pos + {col * (8 + f32(size)-1), row * 32}
		}

		rd.push_constant_data(.Vertex, &ubo, 0)
		rd.push_constant_data(.Pixel, &ubo, 0)
        rd.push_constant_data(.Pixel, &color, 1)
		rd.draw_indexed(0, 6)
	}

}
