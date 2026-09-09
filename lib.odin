package obj_viewer
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import lg "core:math/linalg"
import rd "../Redef"

vec2 :: [2]f32
vec3 :: [3]f32
vec4 :: [4]f32
mat4 :: matrix[4,4]f32

None :: struct{}

to_radians :: math.to_radians_f32

abs :: lg.abs

Scene :: struct {
    assets:             []Asset,
    renderables:        []Renderable,
    meshes:             []Mesh,
    entities:       #soa[dynamic]Entity,
}

in_bounds :: proc(p: vec2, rect: Rect) -> bool {
    return p.x >= rect.x && p.x < rect.x + rect.w && p.y >= rect.y && p.y < rect.y + rect.h
}

to_vec4 :: proc(v: vec3, f: f32) -> vec4 { return vec4{v.x, v.y, v.z, f} }

norm :: proc(v: vec3) -> f32 { return math.sqrt_f32(v.x*v.x + v.y*v.y + v.z*v.z) }

random_range :: proc(min: f32, max: f32) -> f32 {
    return rand.float32() * (max - min) + min
}

aabb_vertices :: proc(bbox: AABB) -> [24]vec3 {
    min := bbox.min
    max := bbox.max

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

vector_normalize :: proc(v: ^vec3) -> f32 {
    length := linalg.length(v^)
    if length != 0 {
        ilength := 1/length
        v^ *= ilength
    }
    return length
}

aabb_intersects_frustum :: proc(frustum_planes: [6]vec4, aabb: AABB) -> bool {
    p_vertex: vec3
    for p in frustum_planes {
        p_vertex = {
            p.x >= 0 ? aabb.max.x : aabb.min.x,
            p.y >= 0 ? aabb.max.y : aabb.min.y,
            p.z >= 0 ? aabb.max.z : aabb.min.z,
        }

        if linalg.dot(p.xyz, p_vertex) + p.w < 0 {
            return false
        }
    }
    return true
}

aabbs_collide :: proc(a: AABB, b: AABB) -> bool {
    return (a.min.x <= b.max.x && a.max.x >= b.min.x) &
    (a.min.y <= b.max.y && a.max.y >= b.min.y) &
    (a.min.z <= b.max.z && a.max.z >= b.min.z)
}

resolve_aabb_collision_mtv :: proc(moving: AABB, solid: AABB) -> vec3 {
	mtv: vec3

	x_overlap := min(moving.max.x, solid.max.x) - max(moving.min.x, solid.min.x)
	y_overlap := min(moving.max.y, solid.max.y) - max(moving.min.y, solid.min.y)
	z_overlap := min(moving.max.z, solid.max.z) - max(moving.min.z, solid.min.z)

	if x_overlap <= 0 || y_overlap <= 0 || z_overlap <= 0 {
		return mtv // No collision
	}

	center_moving := (moving.min + moving.max) * 0.5
	center_solid  := (solid.min + solid.max) * 0.5

	direction := center_moving - center_solid

	// Resolve along axis of least penetration
	if x_overlap <= y_overlap && x_overlap <= z_overlap {
        if direction.x < 0 do mtv.x = -x_overlap; else do mtv.x = x_overlap
	} else if y_overlap <= z_overlap {
        if direction.y < 0 do mtv.y = -y_overlap; else do mtv.y = y_overlap
	} else {
        if direction.z < 0 do mtv.z = -z_overlap; else do mtv.z = z_overlap
	}

	return mtv
}

ray_from_screen :: proc(
    screen_pos:    vec2,
    viewport_size: vec2
) -> (origin, direction: vec3) {
    proj_matrix := create_proj_matrix()
    view_matrix := create_view_matrix()
    vp := proj_matrix * view_matrix
    // normalize to NDC (-1..1)
    ndc_x := (2.0 * screen_pos.x) / viewport_size.x - 1.0
    ndc_y := 1.0 - (2.0 * screen_pos.y) / viewport_size.y // flip y if needed
    // ndc_x, ndc_y: f32 = 0, 0
    near_point := vec4{ndc_x, ndc_y, -1.0, 1.0}
    far_point  := vec4{ndc_x, ndc_y,  1.0, 1.0}

    inv_viewproj := linalg.inverse(vp)

    near_world := inv_viewproj * near_point
    far_world  := inv_viewproj * far_point

    // Perspective divide
    near_world /= near_world.w
    far_world  /= far_world.w
    origin    = near_world.xyz
    direction = linalg.normalize(far_world.xyz - near_world.xyz)
    return
}

ray_intersect_aabb :: proc(origin: vec3, dir: vec3, box: AABB) -> f32 {
    inv_dir := 1.0 / dir
    t1 := (box.min.x - origin.x) * inv_dir.x
    t2 := (box.max.x - origin.x) * inv_dir.x
    tmin := min(t1, t2)
    tmax := max(t1, t2)

    ty1 := (box.min.y - origin.y) * inv_dir.y
    ty2 := (box.max.y - origin.y) * inv_dir.y
    tmin = max(tmin, min(ty1, ty2))
    tmax = min(tmax, max(ty1, ty2))

    tz1 := (box.min.z - origin.z) * inv_dir.z
    tz2 := (box.max.z - origin.z) * inv_dir.z
    tmin = max(tmin, min(tz1, tz2))
    tmax = min(tmax, max(tz1, tz2))

    if tmax >= max(tmin, 0.0) {
        return tmin // hit distance
    }
    return -1.0 // no hit
}

closest_point_on_triangle :: proc(p, a, b, c: vec3) -> vec3 {
    // Check if P in vertex region outside A
    ab := b - a
    ac := c - a
    ap := p - a
    d1 := lg.dot(ab, ap)
    d2 := lg.dot(ac, ap)
    if d1 <= 0.0 && d2 <= 0.0 do return a // barycentric coordinates (1,0,0)
    // Check if P in vertex region outside B
    bp := p - b
    d3 := lg.dot(ab, bp)
    d4 := lg.dot(ac, bp)
    if d3 >= 0.0 && d4 <= d3 do return b // barycentric coordinates (0,1,0)
    // Check if P in edge region of AB, if so return projection of P onto AB
    vc := d1 * d4 - d3 * d2
    if vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0 {
        v := d1 / (d1 - d3)
        return a + v * ab // barycentric coordinates (1-v,v,0)
    }
    // Check if P in vertex region outside C
    cp := p - c
    d5 := lg.dot(ab, cp)
    d6 := lg.dot(ac, cp)
    if d6 >= 0.0 && d5 <= d6 do return c // barycentric coordinates (0,0,1)
    // Check if P in edge region of AC, if so return projection of P onto AC
    vb := d5 * d2 - d1 * d6
    if vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0 {
        w := d2 / (d2 - d6)
        return a + w * ac // barycentric coordinates (1-w,0,w)
    }
    // Check if P in edge region of BC, if so return projection of P onto BC
    va := d3 * d6 - d5 * d4
    if va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0 {
        w := (d4 - d3) / ((d4 - d3) + (d5 - d6))
        return b + w * (c - b) // barycentric coordinates (0,1-w,w)
    }
    // P inside face region. Compute Q through its barycentric coordinates (u,v,w)
    denom := 1.0 / (va + vb + vc)
    v := vb * denom
    w := vc * denom
    return a + ab * v + ac * w // = u*a + v*b + w*c, u = va * denom = 1.0-v-w
}

Plane :: struct {
    scale:          vec3,
    num_indices:    u32,
    vbo:            rd.VertexBuffer,
    ibo:            rd.IndexBuffer,
}

new_plane :: proc(n: u16) -> Plane {
    scale: f32 = 2
    n_int := int(n)
    side := n_int + 1
    half := f32(n) * 0.5
    vertices := make([]VertexAABB, side*side, context.temp_allocator)
    for x in 0..<side {
        for y in 0..<side {
            index := side*x + y
            vertices[index] = VertexAABB {
                position = {(f32(x) - half) * scale, 0, (f32(y) - half) * scale},
            }
        }
    }
    indices := make([]u32, n_int*n_int*6, context.temp_allocator)
    idx := 0

    for x in 0..<n_int {
        for y in 0..<n_int {
            v0 := u32(side*x     + y)
            v1 := u32(side*(x+1) + y)
            v2 := u32(side*(x+1) + (y+1))
            v3 := u32(side*x     + (y+1))

            // Triangle 1
            indices[idx] = v0; idx += 1
            indices[idx] = v2; idx += 1
            indices[idx] = v1; idx += 1

            // Triangle 2
            indices[idx] = v0; idx += 1
            indices[idx] = v3; idx += 1
            indices[idx] = v2; idx += 1
        }
    }

    vbo := rd.create_vertex_buffer(vertices)
    ibo := rd.create_index_buffer(indices)
    return {
        num_indices = u32(len(indices)),
        scale = {scale, 1, scale},
        vbo = vbo,
        ibo = ibo
    }
}