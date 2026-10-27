# Blender: a thin 13-inch notebook in the MacBook Air style, front view, with the SplitPipe screenshot on screen.
# Run: blender -b -P laptop.py -- <screen.png> <out.png> <samples> [width]
# Lighting uses Blender's bundled studio.exr (CC0, Poly Haven).
import bpy, bmesh, sys, math, os, glob
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
SCREEN, OUT, SAMPLES = argv[0], argv[1], int(argv[2])
RES_X = int(argv[3]) if len(argv) > 3 else 2400

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
cm = 0.01

# ---------- helpers ----------

def srgb(h):
    h = h.lstrip('#')
    c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return tuple(((x + 0.055) / 1.055) ** 2.4 if x > 0.04045 else x / 12.92 for x in c)

def rrect(w, h, radii, seg=18):
    """Points of a rounded rectangle centred at 0, counter-clockwise. radii = (tl, tr, br, bl)."""
    tl, tr, br, bl = radii
    pts = []
    def arc(cx, cy, r, a0, a1):
        if r <= 0:
            pts.append((cx, cy))
            return
        for i in range(seg + 1):
            a = math.radians(a0 + (a1 - a0) * i / seg)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    x, y = w / 2, h / 2
    arc(x - br, -y + br, br, -90, 0)
    arc(x - tr, y - tr, tr, 0, 90)
    arc(-x + tl, y - tl, tl, 90, 180)
    arc(-x + bl, -y + bl, bl, 180, 270)
    return pts

def prism(name, pts, depth, plane='XZ', bevel=0.0, bevel_seg=4, smooth_sides=True):
    """Extrude a 2D outline. plane XZ: outline in x/z, depth along +y. plane XY: outline in x/y, depth along +z."""
    bm = bmesh.new()
    def v(p, d):
        return Vector((p[0], d, p[1])) if plane == 'XZ' else Vector((p[0], p[1], d))
    a = [bm.verts.new(v(p, 0)) for p in pts]
    b = [bm.verts.new(v(p, depth)) for p in pts]
    n = len(pts)
    f1 = bm.faces.new(a)
    f2 = bm.faces.new(list(reversed(b)))
    sides = []
    for i in range(n):
        j = (i + 1) % n
        sides.append(bm.faces.new((a[i], a[j], b[j], b[i])))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    for f in sides:
        f.smooth = smooth_sides
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    scene.collection.objects.link(ob)
    if bevel > 0:
        m = ob.modifiers.new("Bevel", 'BEVEL')
        m.width = bevel
        m.segments = bevel_seg
        m.limit_method = 'ANGLE'
        m.angle_limit = math.radians(40)
        m.harden_normals = True
        m.use_clamp_overlap = True
    return ob

def flat_face(name, pts, uv=None):
    """Single n-gon in the XZ plane facing -y, with planar UVs when uv=(w, h)."""
    bm = bmesh.new()
    vs = [bm.verts.new(Vector((p[0], 0, p[1]))) for p in pts]
    f = bm.faces.new(vs)
    f.normal_update()
    if f.normal.y > 0:
        f.normal_flip()
    if uv:
        layer = bm.loops.layers.uv.new()
        w, h = uv
        for loop in f.loops:
            loop[layer].uv = (loop.vert.co.x / w + 0.5, loop.vert.co.z / h + 0.5)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    scene.collection.objects.link(ob)
    return ob

def principled(name, color, metal=0.0, rough=0.5, spec=0.5, aniso=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*srgb(color), 1)
    b.inputs["Metallic"].default_value = metal
    b.inputs["Roughness"].default_value = rough
    b.inputs["Specular IOR Level"].default_value = spec
    if aniso:
        b.inputs["Anisotropic"].default_value = aniso
    return m

# ---------- materials ----------

alu = principled("Aluminium", "#86898f", metal=1.0, rough=0.36)          # space grey, bead-blasted
alu_edge = principled("AluminiumEdge", "#c9cbcf", metal=1.0, rough=0.18)  # diamond-cut edges read brighter
glass = principled("BezelGlass", "#020203", rough=0.14, spec=0.18)
black = principled("NotchBlack", "#000000", rough=1.0, spec=0.0)
lens = principled("Lens", "#14181f", metal=0.0, rough=0.15, spec=0.8)
hinge_m = principled("Hinge", "#0b0c0e", metal=0.0, rough=0.7, spec=0.2)
foot_m = principled("Feet", "#111214", rough=0.8)

# ---------- dimensions (13-inch class) ----------

W = 30.41 * cm
LID_H = 21.5 * cm - 0.6 * cm
LID_T = 0.39 * cm
BASE_D = 21.5 * cm
BASE_T = 0.75 * cm
R_LID = 1.05 * cm
OPEN = math.radians(12)  # lid leans back from vertical

# Base: outline in x/y (top view), thickness up +z
base = prism("Base", rrect(W, BASE_D, (R_LID,) * 4), BASE_T, plane='XY', bevel=0.16 * cm, bevel_seg=6)
base.location = (0, BASE_D / 2, 0.12 * cm)
base.data.materials.append(alu)

# Thumb cut in the front edge
bpy.ops.mesh.primitive_cylinder_add(radius=2.3 * cm, depth=1.2 * cm, location=(0, -1.95 * cm, BASE_T + 0.38 * cm), vertices=96)
cut = bpy.context.object
cut.rotation_euler = (math.radians(90), 0, 0)
cut.scale = (1, 0.42, 1)
cut.location = (0, 0.05 * cm, BASE_T + 0.12 * cm + 0.6 * cm)
cut.hide_render = cut.hide_viewport = True
mod = base.modifiers.new("Thumb", 'BOOLEAN')
mod.object = cut
mod.operation = 'DIFFERENCE'
base.modifiers.move(base.modifiers.find("Thumb"), 0)

# Feet
for x in (-W / 2 + 2.2 * cm, W / 2 - 2.2 * cm):
    for y in (2.0 * cm, BASE_D - 2.0 * cm):
        bpy.ops.mesh.primitive_cylinder_add(radius=0.55 * cm, depth=0.12 * cm, location=(x, y, 0.06 * cm))
        bpy.context.object.data.materials.append(foot_m)

# Keyboard deck: a dark key field near the hinge and a glass trackpad at the front
deck_z = 0.12 * cm + BASE_T + 0.0006
keys_m = principled("Keys", "#0d0e10", rough=0.55, spec=0.3)
pad_m = principled("Trackpad", "#7d8086", metal=0.6, rough=0.22)
bpy.ops.mesh.primitive_plane_add(size=1)
keys = bpy.context.object
keys.scale = (27.6 * cm, 10.2 * cm, 1)
keys.location = (0, BASE_D - 1.3 * cm - 5.1 * cm, deck_z)
keys.data.materials.append(keys_m)
# Key gaps as thin lighter lines so the field reads as keys from a low angle
for row in range(6):
    bpy.ops.mesh.primitive_plane_add(size=1)
    gap = bpy.context.object
    gap.scale = (27.6 * cm, 0.12 * cm, 1)
    gap.location = (0, BASE_D - 1.3 * cm - 0.2 * cm - row * 1.75 * cm, deck_z + 0.0002)
    gap.data.materials.append(principled("KeyGap", "#33363c", metal=0.8, rough=0.4))
bpy.ops.mesh.primitive_plane_add(size=1)
pad = bpy.context.object
pad.scale = (13.4 * cm, 8.1 * cm, 1)
pad.location = (0, 1.2 * cm + 4.05 * cm, deck_z)
pad.data.materials.append(pad_m)

# Hinge barrel behind the lid foot
bpy.ops.mesh.primitive_cylinder_add(radius=0.33 * cm, depth=W - 6 * cm, location=(0, BASE_D - 0.55 * cm, BASE_T + 0.32 * cm), rotation=(0, math.radians(90), 0), vertices=48)
hinge = bpy.context.object
hinge.data.materials.append(hinge_m)
for p in hinge.data.polygons:
    p.use_smooth = True

# Lid group, pivoting at the back of the base
pivot = bpy.data.objects.new("LidPivot", None)
scene.collection.objects.link(pivot)
pivot.location = (0, BASE_D - 0.5 * cm, BASE_T + 0.32 * cm)
pivot.rotation_euler = (-OPEN, 0, 0)

def on_lid(ob, z_bottom=0.0):
    ob.parent = pivot
    return ob

# Lid shell: outline in x/z, thickness toward +y (away from the viewer)
lid = prism("Lid", rrect(W, LID_H, (R_LID, R_LID, 0.5 * cm, 0.5 * cm)), LID_T, plane='XZ', bevel=0.09 * cm, bevel_seg=5)
lid.location = (0, -LID_T * 0.15, LID_H / 2 + 0.25 * cm)
lid.data.materials.append(alu)
on_lid(lid)

# Black glass, inset by the thin aluminium rim
RIM = 0.07 * cm
GLASS_H = LID_H - 2 * RIM
gl = flat_face("Glass", rrect(W - 2 * RIM, GLASS_H, (R_LID - RIM, R_LID - RIM, 0.45 * cm, 0.45 * cm)))
gl.location = (0, -LID_T * 0.15 - 0.004 * cm, LID_H / 2 + 0.25 * cm)
gl.data.materials.append(glass)
on_lid(gl)

# Display: 2560 x 1664, rounded top corners
SIDE = 0.52 * cm
SW = W - 2 * SIDE
SH = SW * 1664 / 2560
TOP = 0.62 * cm
disp_top = LID_H + 0.25 * cm - RIM - TOP
disp = flat_face("Display", rrect(SW, SH, (0.62 * cm, 0.62 * cm, 0.02 * cm, 0.02 * cm)), uv=(SW, SH))
disp.location = (0, -LID_T * 0.15 - 0.008 * cm, disp_top - SH / 2)
on_lid(disp)
sm = bpy.data.materials.new("DisplayMat")
sm.use_nodes = True
nt = sm.node_tree
for n in list(nt.nodes):
    nt.nodes.remove(n)
uvn = nt.nodes.new("ShaderNodeUVMap")
tex = nt.nodes.new("ShaderNodeTexImage")
tex.image = bpy.data.images.load(SCREEN)
tex.interpolation = 'Cubic'
emit = nt.nodes.new("ShaderNodeEmission")
emit.inputs["Strength"].default_value = 1.0
gloss = nt.nodes.new("ShaderNodeBsdfGlossy")
gloss.inputs["Roughness"].default_value = 0.04
lw = nt.nodes.new("ShaderNodeLayerWeight")
lw.inputs["Blend"].default_value = 0.12
mix = nt.nodes.new("ShaderNodeMixShader")
fac = nt.nodes.new("ShaderNodeMath")
fac.operation = 'MULTIPLY'
fac.inputs[1].default_value = 0.35
outn = nt.nodes.new("ShaderNodeOutputMaterial")
nt.links.new(uvn.outputs["UV"], tex.inputs["Vector"])
nt.links.new(tex.outputs["Color"], emit.inputs["Color"])
nt.links.new(lw.outputs["Fresnel"], fac.inputs[0])
nt.links.new(fac.outputs[0], mix.inputs["Fac"])
nt.links.new(emit.outputs[0], mix.inputs[1])
nt.links.new(gloss.outputs[0], mix.inputs[2])
nt.links.new(mix.outputs[0], outn.inputs["Surface"])
disp.data.materials.append(sm)

# Notch with the camera lens
NW, NH = 3.2 * cm, 0.62 * cm
notch = flat_face("Notch", rrect(NW, NH, (0, 0, 0.26 * cm, 0.26 * cm)))
notch.location = (0, -LID_T * 0.15 - 0.012 * cm, disp_top - NH / 2 + 0.002 * cm)
notch.data.materials.append(black)
on_lid(notch)
bpy.ops.mesh.primitive_circle_add(radius=0.085 * cm, fill_type='NGON', vertices=32, rotation=(math.radians(90), 0, 0))
cam_lens = bpy.context.object
cam_lens.location = (0, -LID_T * 0.15 - 0.016 * cm, disp_top + 0.3 * cm)
cam_lens.data.materials.append(lens)
on_lid(cam_lens)

# Small shadow-catcher floor, only as large as the contact shadow needs
bpy.ops.mesh.primitive_plane_add(size=1, location=(0, BASE_D / 2, 0))
floor = bpy.context.object
floor.scale = (W * 1.6, BASE_D * 1.8, 1)
floor.is_shadow_catcher = True

# ---------- light ----------

world = bpy.data.worlds.new("World")
scene.world = world
world.use_nodes = True
wn = world.node_tree
bg = wn.nodes["Background"]
env = wn.nodes.new("ShaderNodeTexEnvironment")
hdr = glob.glob(os.path.join(os.path.dirname(bpy.app.binary_path), "..", "Resources", "*", "datafiles", "studiolights", "world", "studio.exr"))
env.image = bpy.data.images.load(hdr[0])
mapping = wn.nodes.new("ShaderNodeMapping")
coord = wn.nodes.new("ShaderNodeTexCoord")
mapping.inputs["Rotation"].default_value = (0, 0, math.radians(200))
wn.links.new(coord.outputs["Generated"], mapping.inputs["Vector"])
wn.links.new(mapping.outputs["Vector"], env.inputs["Vector"])
wn.links.new(env.outputs["Color"], bg.inputs["Color"])
bg.inputs["Strength"].default_value = 0.4

def softbox(name, loc, size, power, target=(0, 0.1, 0.1)):
    l = bpy.data.lights.new(name, 'AREA')
    l.shape = 'RECTANGLE'
    l.size, l.size_y = size
    l.energy = power
    o = bpy.data.objects.new(name, l)
    o.location = loc
    scene.collection.objects.link(o)
    o.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()

softbox("TopStrip", (0, -0.25, 0.75), (1.2, 0.25), 30)      # long highlight on the base and top edge
softbox("Left", (-0.9, -0.5, 0.35), (0.5, 0.8), 28)
softbox("Right", (0.9, -0.5, 0.35), (0.5, 0.8), 22)

# ---------- camera ----------

cam_d = bpy.data.cameras.new("Cam")
cam_d.lens = 135
cam = bpy.data.objects.new("Cam", cam_d)
scene.collection.objects.link(cam)
scene.camera = cam
bpy.context.view_layer.update()
centre = disp.matrix_world.translation.copy()
cam.location = Vector((0, centre.y - 2.6, centre.z + 0.02))
aim = centre + Vector((0, 0, -0.016))
cam.rotation_euler = (aim - cam.location).to_track_quat('-Z', 'Y').to_euler()

# Negative fill: a black card behind the camera, so the front edges reflect dark instead of the bright studio
bpy.ops.mesh.primitive_plane_add(size=1)
flag = bpy.context.object
flag.scale = (2.4, 0.5, 1)
flag.rotation_euler = (math.radians(90), 0, 0)
flag.location = (0, cam.location.y - 0.4, 0.12)
flag.data.materials.append(principled("Flag", "#000000", rough=1.0, spec=0.0))
flag.visible_camera = False
flag.visible_shadow = False

# A dark card behind the laptop for the deck to reflect, also invisible to the camera
bpy.ops.mesh.primitive_plane_add(size=1)
back = bpy.context.object
back.scale = (3.0, 0.6, 1)
back.rotation_euler = (math.radians(90), 0, 0)
back.location = (0, BASE_D + 1.2, 0.2)
back.data.materials.append(principled("BackCard", "#3a3d44", rough=1.0, spec=0.0))
back.visible_camera = False
back.visible_shadow = False

# ---------- render ----------

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
scene.render.resolution_x = RES_X
scene.render.resolution_y = int(RES_X * 0.72)
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'
scene.view_settings.view_transform = 'Standard'
scene.render.filepath = OUT
bpy.ops.render.render(write_still=True)
