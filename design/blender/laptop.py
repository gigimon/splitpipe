# Blender: a generic thin laptop, front view, with the SplitPipe screenshot on the screen.
# Run: blender -b -P laptop.py -- <screen.png> <out.png> <samples>
import bpy, bmesh, sys, math
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
SCREEN, OUT, SAMPLES = argv[0], argv[1], int(argv[2])

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
cm = 0.01

def rounded_slab(name, w, d, h, r, edge=0.0):
    """Box w x d x h (x, y, z) with corners of radius r rounded in the x/z plane (the face plane)."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co = Vector((v.co.x * w, v.co.y * d, v.co.z * h))
    edges = [e for e in bm.edges if abs((e.verts[0].co - e.verts[1].co).normalized().y) > 0.99]
    bmesh.ops.bevel(bm, geom=edges, offset=r, segments=16, affect='EDGES', profile=0.5)
    if edge > 0:
        bmesh.ops.bevel(bm, geom=list(bm.edges), offset=edge, segments=3, affect='EDGES', profile=0.5, clamp_overlap=True)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    scene.collection.objects.link(ob)
    for p in me.polygons:
        p.use_smooth = True
    return ob

def mat(name, color, metal=0.0, rough=0.5, coat=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Metallic"].default_value = metal
    b.inputs["Roughness"].default_value = rough
    if coat:
        b.inputs["Coat Weight"].default_value = coat
    return m

def srgb(h):
    h = h.lstrip('#')
    c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return tuple(((x + 0.055) / 1.055) ** 2.4 if x > 0.04045 else x / 12.92 for x in c)

alu = mat("Anodized", srgb("#1a202c"), metal=0.9, rough=0.55)
alu_dark = mat("AnodizedDark", srgb("#1c2230"), metal=1.0, rough=0.45)
glass = mat("Bezel", srgb("#050608"), rough=0.22)
glass.node_tree.nodes["Principled BSDF"].inputs["Specular IOR Level"].default_value = 0.25
black = mat("Black", srgb("#010101"), rough=1.0)
black.node_tree.nodes["Principled BSDF"].inputs["Specular IOR Level"].default_value = 0.0

# Laptop dimensions (roughly a 13-inch thin notebook)
W, LID_H, LID_T = 30.4 * cm, 20.6 * cm, 0.45 * cm
BASE_D, BASE_T = 21.4 * cm, 0.95 * cm
OPEN = math.radians(6)  # lid tilt back from vertical

# Base: lying on z=0, front edge at y=0, back edge at y=BASE_D
base = rounded_slab("Base", W, BASE_T, BASE_D, 1.4 * cm, edge=0.12 * cm)
base.rotation_euler = (math.radians(90), 0, 0)
base.location = (0, BASE_D / 2, BASE_T / 2)
base.data.materials.append(alu)

# Lid pivot at the back top edge of the base
pivot = bpy.data.objects.new("LidPivot", None)
scene.collection.objects.link(pivot)
pivot.location = (0, BASE_D - 0.3 * cm, BASE_T + 0.05 * cm)
pivot.rotation_euler = (-OPEN, 0, 0)

lid = rounded_slab("Lid", W, LID_T, LID_H, 1.1 * cm, edge=0.1 * cm)
lid.parent = pivot
lid.location = (0, LID_T / 2, LID_H / 2)
lid.data.materials.append(alu)

# Black glass front of the lid (faces -y, toward the camera)
front = rounded_slab("Glass", W - 0.05 * cm, 0.04 * cm, LID_H - 0.05 * cm, 1.08 * cm)
front.parent = pivot
front.location = (0, -0.01 * cm, LID_H / 2)
front.data.materials.append(glass)

# Screen: active area 2560x1664 (1.538:1)
SW = W - 2 * 0.85 * cm
SH = SW / (2560 / 1664)
bpy.ops.mesh.primitive_plane_add(size=1)
scr = bpy.context.object
scr.name = "Screen"
scr.scale = (SW, SH, 1)
scr.rotation_euler = (math.radians(90), 0, 0)
scr.parent = pivot
top_bezel = 0.75 * cm
scr.location = (0, -0.035 * cm, LID_H - top_bezel - SH / 2)
sm = bpy.data.materials.new("ScreenMat")
sm.use_nodes = True
nt = sm.node_tree
for n in list(nt.nodes):
    nt.nodes.remove(n)
tex = nt.nodes.new("ShaderNodeTexImage")
tex.image = bpy.data.images.load(SCREEN)
tex.interpolation = 'Cubic'
emit = nt.nodes.new("ShaderNodeEmission")
emit.inputs["Strength"].default_value = 1.0
gloss = nt.nodes.new("ShaderNodeBsdfGlossy")
gloss.inputs["Roughness"].default_value = 0.05
gloss.inputs["Color"].default_value = (1, 1, 1, 1)
fres = nt.nodes.new("ShaderNodeFresnel")
fres.inputs["IOR"].default_value = 1.5
mix = nt.nodes.new("ShaderNodeMixShader")
add_mul = nt.nodes.new("ShaderNodeMath")
add_mul.operation = 'MULTIPLY'
add_mul.inputs[1].default_value = 0.35
out = nt.nodes.new("ShaderNodeOutputMaterial")
nt.links.new(tex.outputs["Color"], emit.inputs["Color"])
nt.links.new(fres.outputs["Fac"], add_mul.inputs[0])
nt.links.new(add_mul.outputs[0], mix.inputs["Fac"])
nt.links.new(emit.outputs[0], mix.inputs[1])
nt.links.new(gloss.outputs[0], mix.inputs[2])
nt.links.new(mix.outputs[0], out.inputs["Surface"])
scr.data.materials.append(sm)

# UVs of a default plane already map 0..1; flip nothing.

# Notch over the top centre of the screen
notch = rounded_slab("Notch", 3.1 * cm, 0.02 * cm, 0.62 * cm * 2, 0.28 * cm)
notch.parent = pivot
notch.location = (0, -0.05 * cm, LID_H - top_bezel)
notch.data.materials.append(black)
for p_ in notch.data.polygons:
    p_.use_smooth = False

# Hinge shadow strip
bpy.ops.mesh.primitive_cylinder_add(radius=0.32 * cm, depth=W - 3.2 * cm, rotation=(0, math.radians(90), 0))
hinge = bpy.context.object
hinge.location = (0, BASE_D - 0.35 * cm, BASE_T + 0.05 * cm)
hinge.data.materials.append(alu_dark)

# Front thumb cut on the base
bpy.ops.mesh.primitive_cylinder_add(radius=1.6 * cm, depth=0.5 * cm, location=(0, -0.95 * cm, BASE_T + 0.02 * cm))
cut = bpy.context.object
cut.scale = (1, 0.7, 1)
mod = base.modifiers.new("Thumb", 'BOOLEAN')
mod.object = cut
mod.operation = 'DIFFERENCE'
cut.hide_render = True
cut.hide_viewport = True

# Shadow catcher floor
bpy.ops.mesh.primitive_plane_add(size=2, location=(0, BASE_D / 2, 0))
floor = bpy.context.object
floor.is_shadow_catcher = True

# Lighting: soft studio
world = bpy.data.worlds.new("World")
scene.world = world
world.use_nodes = True
bg = world.node_tree.nodes["Background"]
grad = world.node_tree.nodes.new("ShaderNodeTexGradient")
coord = world.node_tree.nodes.new("ShaderNodeTexCoord")
mapn = world.node_tree.nodes.new("ShaderNodeMapping")
mapn.inputs["Rotation"].default_value = (0, math.radians(-90), 0)
ramp = world.node_tree.nodes.new("ShaderNodeValToRGB")
ramp.color_ramp.elements[0].color = (0.02, 0.025, 0.035, 1)
ramp.color_ramp.elements[1].color = (0.32, 0.35, 0.42, 1)
world.node_tree.links.new(coord.outputs["Generated"], mapn.inputs["Vector"])
world.node_tree.links.new(mapn.outputs["Vector"], grad.inputs["Vector"])
world.node_tree.links.new(grad.outputs["Fac"], ramp.inputs["Fac"])
world.node_tree.links.new(ramp.outputs["Color"], bg.inputs["Color"])
bg.inputs["Strength"].default_value = 0.6

def area(name, loc, rot, size, power):
    l = bpy.data.lights.new(name, 'AREA')
    l.size = size
    l.energy = power
    o = bpy.data.objects.new(name, l)
    o.location = loc
    o.rotation_euler = rot
    scene.collection.objects.link(o)

area("Key", (-0.45, -0.55, 0.65), (math.radians(55), 0, math.radians(-40)), 0.6, 220)
area("Fill", (0.55, -0.45, 0.35), (math.radians(65), 0, math.radians(50)), 0.8, 90)
area("Top", (0, 0.1, 0.9), (0, 0, 0), 1.0, 55)

# Camera: perpendicular to the lid, centred on the screen, slightly above so the base reads
cam_d = bpy.data.cameras.new("Cam")
cam_d.lens = 85
cam = bpy.data.objects.new("Cam", cam_d)
scene.collection.objects.link(cam)
scene.camera = cam
bpy.context.view_layer.update()
center = scr.matrix_world.translation.copy()
normal = (scr.matrix_world.to_3x3() @ Vector((0, 0, 1))).normalized()  # plane normal after rotation
if normal.y > 0:
    normal = -normal
dist = 1.6
cam.location = center + Vector((0, -dist, 0.035))
direction = center + Vector((0, 0, -0.018)) - cam.location
cam.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()

scene.render.engine = 'CYCLES'
prefs = bpy.context.preferences.addons["cycles"].preferences
try:
    prefs.compute_device_type = 'METAL'
    prefs.get_devices()
    for d in prefs.devices:
        d.use = True
    scene.cycles.device = 'GPU'
except Exception:
    pass
scene.cycles.samples = SAMPLES
scene.cycles.use_denoising = True
scene.render.film_transparent = True
scene.render.resolution_x = 2200
scene.render.resolution_y = 1500
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'
scene.view_settings.view_transform = 'Standard'
scene.render.filepath = OUT
bpy.ops.render.render(write_still=True)
