#!/usr/bin/env python3
"""将锁定的网络素材转换为自包含 VRM；只写本地，不安装、不启动采集或发送。"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import struct
import urllib.request

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'build/official-plugins/sources'
OUTPUT = ROOT / 'build/official-plugins/characters'
LOCK = json.loads((ROOT / 'plugins/official/characters/sources.json').read_text())


def source(slug, name):
    payload = (SOURCES / name).read_bytes()
    if hashlib.sha256(payload).hexdigest() != LOCK[slug]['files'][name]:
        raise ValueError('Source digest mismatch: ' + name)
    return payload


def glb(document, binary):
    encoded = json.dumps(document, ensure_ascii=False, separators=(',', ':')).encode()
    encoded += b' ' * (-len(encoded) % 4)
    binary += b'\0' * (-len(binary) % 4)
    return (struct.pack('<4sII', b'glTF', 2, 28 + len(encoded) + len(binary))
            + struct.pack('<I4s', len(encoded), b'JSON') + encoded
            + struct.pack('<I4s', len(binary), b'BIN\0') + binary)


def meta(slug):
    record = LOCK[slug]
    # 原始署名、来源和改动随模型携带；未确定的授权不能被转换器写成 CC0。
    return dict(name=record['name'], version='1.0.0', authors=[record['author']],
                licenseUrl='https://vrm.dev/licenses/1.0/',
                references=[record['source']], copyrightInformation=record['publication_review'],
                thirdPartyLicenses=record['license'],
                avatarPermission='onlySeparatelyLicensedPerson', commercialUsage='personalNonProfit',
                creditNotation='required', allowRedistribution=False, modification='allowModification',
                otherLicenseUrl=('https://creativecommons.org/licenses/by/4.0/' if slug == 'spider-man'
                                 else record['source']))


def add_vrm(document, slug, bones):
    document.setdefault('extensionsUsed', []).append('VRMC_vrm')
    document.setdefault('extensions', {})['VRMC_vrm'] = dict(
        specVersion='1.0', meta=meta(slug), humanoid={'humanBones': {k: {'node': v} for k, v in bones.items()}})
    document['asset'].setdefault('extras', {})['callbridgeAdaptation'] = {
        'source': LOCK[slug]['source'], 'version': '1.0.0',
        'changes': ('Humanoid mapping, T-pose mesh/bind baking, portrait scale, texture downsampling; original skin weights retained.'
                    if slug == 'spider-man' else
                    'New parametric sculpture based on the approved 1905 reference; body/arm rig, rigid fingers and face. No upstream OBJ reused.')}


def t_pose(doc, payload, bones):
    # 宿主按 VRM 的 T 姿态驱动手臂；源 A 姿态必须同时烘焙网格与逆绑定矩阵，不能只改骨名。
    binary = bytearray(payload)
    nodes = doc['nodes']
    parents = {c: i for i, node in enumerate(nodes) for c in node.get('children', [])}

    def local(node):
        if 'matrix' in node: return np.array(node['matrix']).reshape(4, 4).T
        x, y, z, w = node.get('rotation', [0, 0, 0, 1])
        matrix = np.eye(4)
        matrix[:3, :3] = np.array([
            [1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)],
            [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)],
            [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]]) @ np.diag(node.get('scale', [1, 1, 1]))
        matrix[:3, 3] = node.get('translation', [0, 0, 0])
        return matrix

    def worlds():
        cache = {}
        def visit(i):
            if i not in cache: cache[i] = (visit(parents[i]) if i in parents else np.eye(4)) @ local(nodes[i])
            return cache[i]
        return [visit(i) for i in range(len(nodes))]

    def read(index):
        a = doc['accessors'][index]; v = doc['bufferViews'][a['bufferView']]
        columns = {'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}[a['type']]
        dtype = np.dtype({5121: 'u1', 5123: '<u2', 5126: '<f4'}[a['componentType']])
        start = v.get('byteOffset', 0) + a.get('byteOffset', 0)
        return np.ndarray((a['count'], columns), dtype=dtype, buffer=binary, offset=start,
                          strides=(v.get('byteStride', columns * dtype.itemsize), dtype.itemsize)).copy()

    def append(values, kind, bounds=False):
        values = np.asarray(values, dtype='<f4')
        binary.extend(b'\0' * (-len(binary) % 4))
        doc['bufferViews'].append({'buffer': 0, 'byteOffset': len(binary), 'byteLength': values.nbytes})
        binary.extend(values.tobytes())
        a = dict(bufferView=len(doc['bufferViews'])-1, componentType=5126, count=len(values), type=kind)
        if bounds: a.update(min=values.min(0).tolist(), max=values.max(0).tolist())
        doc['accessors'].append(a)
        return len(doc['accessors'])-1

    old = worlds()
    for side, sign in [('left', 1), ('right', -1)]:
        for name, child in [('UpperArm', 'LowerArm'), ('LowerArm', 'Hand')]:
            world = worlds(); i, end = bones[side + name], bones[side + child]
            direction = world[end][:3, 3] - world[i][:3, 3]; direction /= np.linalg.norm(direction)
            target = np.array([sign, 0, 0]); v = np.cross(direction, target); cosine = float(direction @ target)
            if cosine < -.99999: raise ValueError('Opposite arm axis requires an explicit source correction')
            skew = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
            rotation = np.eye(3) + skew + skew @ skew / (1 + cosine)
            changed = world[i].copy(); changed[:3, :3] = rotation @ changed[:3, :3]
            matrix = np.linalg.inv(world[parents[i]]) @ changed
            for key in ['translation', 'rotation', 'scale']: nodes[i].pop(key, None)
            nodes[i]['matrix'] = matrix.T.flatten().tolist()
    new = worlds()
    for skin_index, skin in enumerate(doc['skins']):
        inverse = read(skin['inverseBindMatrices']).reshape(-1, 4, 4).transpose(0, 2, 1)
        mesh_nodes = [i for i, node in enumerate(nodes) if node.get('skin') == skin_index]
        reference = old[mesh_nodes[0]]
        for i in mesh_nodes:
            if not np.allclose(old[i], reference): raise ValueError('Shared skin has different mesh transforms')
            transforms = np.array([np.linalg.inv(old[i]) @ new[joint] @ bind
                                   for joint, bind in zip(skin['joints'], inverse)])
            for primitive in doc['meshes'][nodes[i]['mesh']]['primitives']:
                attrs = primitive['attributes']; joints = read(attrs['JOINTS_0']); weights = read(attrs['WEIGHTS_0'])
                combined = (transforms[joints] * weights[:, :, None, None]).sum(1)
                positions = read(attrs['POSITION']); homogeneous = np.column_stack([positions, np.ones(len(positions))])
                points = np.einsum('nij,nj->ni', combined, homogeneous)[:, :3]
                attrs['POSITION'] = append(points, 'VEC3', True)
                for key in ['NORMAL', 'TANGENT']:
                    if key not in attrs: continue
                    values = read(attrs[key]); normal_matrix = np.linalg.inv(combined[:, :3, :3]).transpose(0, 2, 1)
                    rotated = np.einsum('nij,nj->ni', normal_matrix if key == 'NORMAL' else combined[:, :3, :3], values[:, :3])
                    rotated /= np.maximum(np.linalg.norm(rotated, axis=1, keepdims=True), 1e-12)
                    if key == 'TANGENT': rotated = np.column_stack([rotated, values[:, 3]])
                    attrs[key] = append(rotated, 'VEC4' if key == 'TANGENT' else 'VEC3')
        skin['inverseBindMatrices'] = append([ (np.linalg.inv(new[joint]) @ reference).T.flatten()
                                             for joint in skin['joints']], 'MAT4')
    doc['buffers'] = [{'byteLength': len(binary)}]
    return bytes(binary)


def spider_man():
    data = source('spider-man', 'spider-man-homecoming-tech-suit.glb')
    length = struct.unpack_from('<I', data, 12)[0]
    doc = json.loads(data[20:20 + length])
    binary = data[28 + length:]
    # 原模型的二十张贴图超出宿主总像素预算；重排视图以移除旧贴图而非重复塞入二进制。
    images = {image['bufferView']: image for image in doc['images']}
    compact = bytearray()
    for index, view in enumerate(doc['bufferViews']):
        start = view.get('byteOffset', 0)
        payload = binary[start:start + view['byteLength']]
        if index in images:
            picture = Image.open(io.BytesIO(payload))
            picture.thumbnail((1024, 1024), Image.Resampling.LANCZOS)
            stream = io.BytesIO()
            picture.save(stream, format='PNG', compress_level=9)
            payload = stream.getvalue()
        compact.extend(b'\0' * (-len(compact) % 4))
        view['byteOffset'], view['byteLength'] = len(compact), len(payload)
        compact.extend(payload)
    doc['buffers'] = [{'byteLength': len(compact)}]
    names = {n['name'].split('_')[0].replace('mixamorig:', ''): i
             for i, n in enumerate(doc['nodes'])
             if n.get('name', '').startswith('mixamorig:') and '_end_' not in n['name']}
    mapping = {'hips': 'Pelvis', 'spine': 'Spine', 'chest': 'Spine1', 'upperChest': 'Spine3',
               'neck': 'Neck', 'head': 'Head'}
    for side in ['Left', 'Right']:
        for target, original in [('Shoulder', 'Shoulder'), ('UpperArm', 'Arm'), ('LowerArm', 'ForeArm'),
                                 ('Hand', 'Hand'), ('UpperLeg', 'UpLeg'), ('LowerLeg', 'Leg'),
                                 ('Foot', 'Foot'), ('Toes', 'ToeBase')]:
            mapping[side.lower() + target] = side + original
        for finger in ['Thumb', 'Index', 'Middle', 'Ring', 'Little']:
            segments = ['Metacarpal', 'Proximal', 'Distal'] if finger == 'Thumb' else ['Proximal', 'Intermediate', 'Distal']
            for number, segment in enumerate(segments, 1):
                mapping[side.lower() + finger + segment] = side + 'Hand' + ('Pinky' if finger == 'Little' else finger) + str(number)
    bones = {name: names[original] for name, original in mapping.items()}
    compact = t_pose(doc, bytes(compact), bones)
    # 角色固定为约 1.7 米，适配当前半身相机；不修改宿主相机或角色运行时。
    root = len(doc['nodes'])
    doc['nodes'].append({'name': 'CallBridgePortraitScale', 'scale': [.78, .78, .78],
                         'children': doc['scenes'][doc.get('scene', 0)]['nodes']})
    doc['scenes'][doc.get('scene', 0)]['nodes'] = [root]
    add_vrm(doc, 'spider-man', bones)
    return glb(doc, bytes(compact))


class Buffer:
    def __init__(self):
        self.data = bytearray()
        self.views = []
        self.accessors = []

    def view(self, data):
        self.data.extend(b'\0' * (-len(self.data) % 4))
        self.views.append({'buffer': 0, 'byteOffset': len(self.data), 'byteLength': len(data)})
        self.data.extend(data)
        return len(self.views) - 1

    def array(self, values, kind, dtype='<f4', bounds=False):
        array = np.array(values, dtype=dtype)
        item = dict(bufferView=self.view(array.tobytes()), componentType=5123 if dtype == '<u2' else 5126,
                    count=len(array), type=kind)
        if bounds:
            item.update(min=array.min(axis=0).tolist(), max=array.max(axis=0).tolist())
        self.accessors.append(item)
        return len(self.accessors) - 1


def gg_bond():
    from gg_bond_geometry import build
    return build(Buffer, add_vrm, glb, t_pose)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fetch-spider-man', action='store_true', help='Explicitly download the pinned public GLB')
    args = parser.parse_args()
    SOURCES.mkdir(parents=True, exist_ok=True)
    if args.fetch_spider_man:
        record = LOCK['spider-man']; name = next(iter(record['files']))
        with urllib.request.urlopen(record['download'], timeout=60) as response:
            payload = response.read(64 * 1024 * 1024 + 1)
        if hashlib.sha256(payload).hexdigest() != record['files'][name]:
            raise SystemExit('Downloaded source digest mismatch')
        (SOURCES / name).write_bytes(payload)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for slug, builder in [('spider-man', spider_man), ('gg-bond', gg_bond)]:
        payload = builder(); path = OUTPUT / (slug + '.vrm'); path.write_bytes(payload)
        print(json.dumps({'file': str(path), 'bytes': len(payload), 'sha256': hashlib.sha256(payload).hexdigest()}))


if __name__ == '__main__':
    main()
