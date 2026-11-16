class_name WorldGen
extends RefCounted
## Deterministic procedural world generator (no graphics, pure data).
## Same seed => identical world on every platform running the same engine build.

const W := 240
const H := 120
const LAND_THRESHOLD := 0.02


static func generate(seed_value: int, land_count: int = 130, sea_count: int = 30) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = seed_value
	noise.frequency = 0.019
	noise.fractal_octaves = 5

	var moist := FastNoiseLite.new()
	moist.seed = seed_value + 7919
	moist.frequency = 0.05

	var elev := PackedFloat32Array()
	var moisture := PackedFloat32Array()
	elev.resize(W * H)
	moisture.resize(W * H)
	var land_cells: Array[int] = []
	var sea_cells: Array[int] = []
	for y in H:
		for x in W:
			var e := noise.get_noise_2d(x, y) * 1.4
			var ex := absf(float(x) / W * 2.0 - 1.0)
			var ey := absf(float(y) / H * 2.0 - 1.0)
			e -= pow(maxf(ex, ey), 4.0) * 1.2
			e += 0.12
			var i := y * W + x
			elev[i] = e
			moisture[i] = moist.get_noise_2d(x, y)
			if e > LAND_THRESHOLD:
				land_cells.append(i)
			else:
				sea_cells.append(i)

	var land_pts := _pick_points(rng, land_cells, mini(land_count, land_cells.size()), 6.5)
	var sea_pts := _pick_points(rng, sea_cells, mini(sea_count, sea_cells.size()), 10.0)
	var n_land := land_pts.size()
	var n_total := n_land + sea_pts.size()

	var cell_prov := PackedInt32Array()
	cell_prov.resize(W * H)
	var prov_cells: Array = []
	for _p in n_total:
		prov_cells.append(PackedInt32Array())
	for y in H:
		for x in W:
			var i := y * W + x
			var is_land := elev[i] > LAND_THRESHOLD
			var pts: Array[Vector2i] = land_pts if is_land else sea_pts
			var base := 0 if is_land else n_land
			var best := 0
			var best_d := 1 << 30
			for k in pts.size():
				var dx := pts[k].x - x
				var dy := pts[k].y - y
				var d := dx * dx + dy * dy
				if d < best_d:
					best_d = d
					best = k
			cell_prov[i] = base + best
			prov_cells[base + best].append(i)

	var provinces: Array = []
	for p in n_total:
		var is_land_p := p < n_land
		var seed_pt: Vector2i = land_pts[p] if is_land_p else sea_pts[p - n_land]
		var cells: PackedInt32Array = prov_cells[p]
		var sum_e := 0.0
		var sum_m := 0.0
		for c in cells:
			sum_e += elev[c]
			sum_m += moisture[c]
		var n := maxi(cells.size(), 1)
		var avg_e := sum_e / n
		var avg_m := sum_m / n
		var lat := absf(float(seed_pt.y) / H * 2.0 - 1.0)
		var terrain := "sea"
		if is_land_p:
			if avg_e > 0.42:
				terrain = "mountain"
			elif avg_e > 0.28:
				terrain = "hills"
			elif avg_m < -0.2 and lat < 0.75:
				terrain = "desert"
			elif avg_m > 0.12:
				terrain = "forest"
			else:
				terrain = "plains"
		var pop := 0
		var industry := 0
		if is_land_p:
			var factor := 1.0
			match terrain:
				"mountain": factor = 0.5
				"desert": factor = 0.6
				"hills": factor = 0.8
			pop = int(cells.size() * rng.randi_range(2, 6) * factor)
			industry = rng.randi_range(1, 4)
		provinces.append({
			"id": p,
			"land": is_land_p,
			"center": Vector2(seed_pt.x, seed_pt.y),
			"cell_count": cells.size(),
			"terrain": terrain,
			"pop": pop,
			"industry": industry,
			"neighbors": [],
			"land_neighbors": [],
		})

	# adjacency from cell edges
	var nb: Array = []
	for _p in n_total:
		nb.append({})
	for y in H:
		for x in W:
			var a := cell_prov[y * W + x]
			if x + 1 < W:
				_link(nb, a, cell_prov[y * W + x + 1])
			if y + 1 < H:
				_link(nb, a, cell_prov[(y + 1) * W + x])
	for p in n_total:
		var keys: Array = nb[p].keys()
		keys.sort()
		provinces[p]["neighbors"] = keys
		var ln: Array = []
		if provinces[p]["land"]:
			for q in keys:
				if provinces[q]["land"]:
					ln.append(q)
		provinces[p]["land_neighbors"] = ln

	return {
		"seed": seed_value,
		"w": W,
		"h": H,
		"cell_prov": cell_prov,
		"elev": elev,
		"prov_cells": prov_cells,
		"provinces": provinces,
		"land_count": n_land,
	}


static func _link(nb: Array, a: int, b: int) -> void:
	if a != b:
		nb[a][b] = true
		nb[b][a] = true


static func _pick_points(rng: RandomNumberGenerator, cells: Array[int], count: int, min_dist: float) -> Array[Vector2i]:
	var pts: Array[Vector2i] = []
	if cells.is_empty():
		return pts
	var attempts := 0
	var md := min_dist
	while pts.size() < count and attempts < count * 60:
		attempts += 1
		if attempts % (count * 20) == 0:
			md *= 0.7
		var c := cells[rng.randi_range(0, cells.size() - 1)]
		var p := Vector2i(c % W, c / W)
		var ok := true
		for q in pts:
			if Vector2(p).distance_to(Vector2(q)) < md:
				ok = false
				break
		if ok:
			pts.append(p)
	return pts


## Connected groups of land provinces (landmasses), biggest first.
static func landmasses(world: Dictionary) -> Array:
	var provs: Array = world["provinces"]
	var seen := {}
	var comps: Array = []
	for p in provs:
		if not p["land"] or seen.has(p["id"]):
			continue
		var comp: Array[int] = []
		var queue: Array[int] = [p["id"]]
		seen[p["id"]] = true
		while not queue.is_empty():
			var cur: int = queue.pop_front()
			comp.append(cur)
			for q in provs[cur]["land_neighbors"]:
				if not seen.has(q):
					seen[q] = true
					queue.append(q)
		comps.append(comp)
	comps.sort_custom(func(a, b): return a.size() > b.size())
	return comps


static func main_landmass(world: Dictionary) -> Array[int]:
	var comps := landmasses(world)
	var out: Array[int] = []
	if not comps.is_empty():
		out.assign(comps[0])
	return out


## Farthest-point selection of capitals over every landmass with >= 6 provinces.
static func pick_capitals(world: Dictionary, count: int, rng: RandomNumberGenerator) -> Array[int]:
	var land: Array[int] = []
	for comp in landmasses(world):
		if comp.size() >= 6:
			land.append_array(comp)
	land.sort()
	var provs: Array = world["provinces"]
	var caps: Array[int] = []
	if land.is_empty():
		return caps
	caps.append(land[rng.randi_range(0, land.size() - 1)])
	while caps.size() < mini(count, land.size()):
		var best := -1
		var best_d := -1.0
		for p in land:
			if caps.has(p):
				continue
			var dmin := 1e9
			for c in caps:
				dmin = minf(dmin, provs[p]["center"].distance_to(provs[c]["center"]))
			if dmin > best_d:
				best_d = dmin
				best = p
		caps.append(best)
	return caps


## Multi-source BFS: every landmass province goes to the nearest capital.
static func assign_owners(world: Dictionary, capitals: Array[int]) -> PackedInt32Array:
	var provs: Array = world["provinces"]
	var owner := PackedInt32Array()
	owner.resize(provs.size())
	owner.fill(-1)
	var queue: Array[int] = []
	for i in capitals.size():
		owner[capitals[i]] = i
		queue.append(capitals[i])
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		for q in provs[cur]["land_neighbors"]:
			if owner[q] == -1:
				owner[q] = owner[cur]
				queue.append(q)
	return owner
