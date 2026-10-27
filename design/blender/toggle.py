# Blender: a panel-mount metal toggle switch (the "kill switch"), rendered as a turntable sprite.
# Run: blender -b -P toggle.py -- <out_dir> <frames> <samples> <size>
import bpy, bmesh, sys, math, os
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
OUT, FRAMES, SAMPLES, SIZE = argv[0], int(argv[1]), int(argv[2]), int(argv[3])

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

def srgb(h):
    h = h.lstrip('#')
    c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return tuple(((x + 0.055) / 1.055) ** 2.4 if x > 0.04045 else x / 12.92 for x in c)

def mat(name, color, metal=0.0, rough=0.5, coat=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*srgb(color), 1)
    b.inputs["Metallic"].default_value = metal
    b.inputs["Roughness"].default_value = rough
    b.inputs["Coat Weight"].default_value = coat
    return m

body_m = mat("Body", "#8f1d24", rough=0.3, coat=0.6)
chrome = mat("Chrome", "#d9dde4", metal=1.0, rough=0.16)
nickel = mat("Nickel", "#aab0ba", metal=1.0, rough=0.3)
brass = mat("Pins", "#c9a86a", metal=1.0, rough=0.3)

root = bpy.data.objects.new("Switch", None)
scene.collection.objects.link(root)

def link(ob, m):
    ob.data.materials.append(m)
    ob.parent = root
    for p in ob.data.polygons:
        p.use_smooth = True
    return ob

def bevel(ob, w, seg=4):
    mod = ob.modifiers.new("Bevel", 'BEVEL')
    mod.width = w
    mod.segments = seg
    mod.limit_method = 'ANGLE'

# Body: a rounded block
bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, 0.5))
body = bpy.context.object
body.scale = (1.5, 1.05, 1.0)
bpy.ops.object.transform_apply(scale=True)
bevel(body, 0.09, 6)
link(body, body_m)

# Mounting plate on top of the body
bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, 1.03))
plate = bpy.context.object
plate.scale = (1.62, 1.16, 0.06)
bpy.ops.object.transform_apply(scale=True)
bevel(plate, 0.025, 3)
link(plate, nickel)

# Hex nut
bpy.ops.mesh.primitive_cylinder_add(vertices=6, radius=0.46, depth=0.2, location=(0, 0, 1.16))
nut = bpy.context.object
bevel(nut, 0.03, 2)
link(nut, nickel)

# Threaded bushing: cylinder with rings
bpy.ops.mesh.primitive_cylinder_add(vertices=64, radius=0.29, depth=0.62, location=(0, 0, 1.55))
link(bpy.context.object, chrome)
for i in range(9):
    bpy.ops.mesh.primitive_torus_add(major_radius=0.29, minor_radius=0.03, major_segments=64, minor_segments=12,
                                     location=(0, 0, 1.3 + i * 0.062))
    link(bpy.context.object, chrome)

# Lever: pivot at the top of the bushing, tilted toward the viewer
pivot = bpy.data.objects.new("LeverPivot", None)
scene.collection.objects.link(pivot)
pivot.parent = root
pivot.location = (0, 0, 1.82)
pivot.rotation_euler = (math.radians(-22), 0, 0)

bpy.ops.mesh.primitive_uv_sphere_add(radius=0.2, location=(0, 0, 0))
collar = bpy.context.object
collar.parent = pivot
collar.data.materials.append(chrome)
for p in collar.data.polygons:
    p.use_smooth = True

bpy.ops.mesh.primitive_cone_add(vertices=64, radius1=0.12, radius2=0.19, depth=1.45, location=(0, 0, 0.75))
lever = bpy.context.object
lever.parent = pivot
lever.data.materials.append(chrome)
for p in lever.data.polygons:
    p.use_smooth = True
bpy.ops.mesh.primitive_uv_sphere_add(radius=0.19, location=(0, 0, 1.47))
tip = bpy.context.object
tip.scale = (1, 1, 0.75)
tip.parent = pivot
tip.data.materials.append(chrome)
for p in tip.data.polygons:
    p.use_smooth = True

# Solder pins under the body
for x in (-0.45, 0, 0.45):
    bpy.ops.mesh.primitive_cube_add(size=1, location=(x, 0, -0.32))
    pin = bpy.context.object
    pin.scale = (0.14, 0.04, 0.64)
    bpy.ops.object.transform_apply(scale=True)
    bevel(pin, 0.01, 2)
    link(pin, brass)

# Soft shadow on a transparent floor
bpy.ops.mesh.primitive_plane_add(size=20, location=(0, 0, -0.64))
bpy.context.object.is_shadow_catcher = True

# World: dark studio gradient for reflections
world = bpy.data.worlds.new("World")
scene.world = world
world.use_nodes = True
nt = world.node_tree
bg = nt.nodes["Background"]
coord = nt.nodes.new("ShaderNodeTexCoord")
sep = nt.nodes.new("ShaderNodeSeparateXYZ")
ramp = nt.nodes.new("ShaderNodeValToRGB")
ramp.color_ramp.elements[0].position = 0.45
ramp.color_ramp.elements[0].color = (0.015, 0.02, 0.03, 1)
ramp.color_ramp.elements[1].position = 0.75
ramp.color_ramp.elements[1].color = (0.55, 0.6, 0.7, 1)
math_n = nt.nodes.new("ShaderNodeMath")
math_n.operation = 'MULTIPLY_ADD'
math_n.inputs[1].default_value = 0.5
math_n.inputs[2].default_value = 0.5
nt.links.new(coord.outputs["Generated"], sep.inputs[0])
nt.links.new(sep.outputs["Z"], ramp.inputs["Fac"])
nt.links.new(ramp.outputs["Color"], bg.inputs["Color"])
bg.inputs["Strength"].default_value = 0.8

def area(name, loc, size, power, color=(1, 1, 1)):
    l = bpy.data.lights.new(name, 'AREA')
    l.size = size
    l.energy = power
    l.color = color
    o = bpy.data.objects.new(name, l)
    o.location = loc
    scene.collection.objects.link(o)
    t = o.constraints.new('TRACK_TO')
    t.target = root
    t.track_axis = 'TRACK_NEGATIVE_Z'
    t.up_axis = 'UP_Y'

area("Key", (-4, -5, 6), 4, 900)
area("Rim", (5, 4, 4), 3, 700, (0.75, 0.8, 1.0))
area("Fill", (5, -5, 1.5), 5, 250)

cam_d = bpy.data.cameras.new("Cam")
cam_d.lens = 70
cam = bpy.data.objects.new("Cam", cam_d)
scene.collection.objects.link(cam)
scene.camera = cam
cam.location = (0, -11.2, 5.0)
aim = bpy.data.objects.new("Aim", None)
scene.collection.objects.link(aim)
aim.location = (0, 0, 1.3)
tc = cam.constraints.new('TRACK_TO')
tc.target = aim
tc.track_axis = 'TRACK_NEGATIVE_Z'
tc.up_axis = 'UP_Y'

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
scene.render.resolution_x = SIZE
scene.render.resolution_y = SIZE
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'
scene.view_settings.view_transform = 'Standard'

# Turntable from -40 to +40 degrees around the vertical axis
os.makedirs(OUT, exist_ok=True)
for i in range(FRAMES):
    a = -40 + 80 * i / max(1, FRAMES - 1)
    root.rotation_euler = (0, 0, math.radians(a))
    scene.render.filepath = os.path.join(OUT, f"f{i:02d}.png")
    bpy.ops.render.render(write_still=True)
