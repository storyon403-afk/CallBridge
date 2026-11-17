"""按已确认的角色参考重建猪猪侠；参数化曲面提供可复现网格，不复用旧 OBJ。"""
import math
import numpy as np


def build(Buffer, add_vrm, glb, t_pose):
    # 单位为米，+Z 面向镜头；整体高度适配现有半身取景，角色比例在资源内定义。
    definitions = [('hips', None, (0, .77, 0)), ('spine', 'hips', (0, .87, 0)),
                   ('chest', 'spine', (0, 1.00, 0)), ('neck', 'chest', (0, 1.08, 0)),
                   ('head', 'neck', (0, 1.28, 0))]
    for side, s in [('left', 1), ('right', -1)]:
        for name, parent, p in [
            ('Shoulder', 'chest', (.15, 1.015, 0)), ('UpperArm', side+'Shoulder', (.215, 1.00, 0)),
            ('LowerArm', side+'UpperArm', (.325, .91, 0)), ('Hand', side+'LowerArm', (.415, .84, 0)),
            ('UpperLeg', 'hips', (.095, .74, 0)), ('LowerLeg', side+'UpperLeg', (.098, .63, 0)),
            ('Foot', side+'LowerLeg', (.098, .535, .025))]:
            definitions.append((side+name, parent, (s*p[0], p[1], p[2])))
    ids = {name: i for i, (name, _, _) in enumerate(definitions)}
    world = {name: np.array(p) for name, _, p in definitions}
    nodes = [dict(name=name, translation=(world[name]-(world[parent] if parent else 0)).tolist(),
                  children=[ids[n] for n,p,_ in definitions if p==name]) for name,parent,_ in definitions]
    binary = Buffer()
    inverse=[]
    for name,_,_ in definitions:
        m=np.eye(4);m[:3,3]=-world[name];inverse.append(m.T.flatten())
    inv=binary.array(inverse,'MAT4')
    palette = {
        'suit': ('#B7192D', .53), 'cap': ('#BE1D2C', .43), 'seam': ('#8D1423', .65),
        'skin': ('#F3BBA5', .7), 'lip': ('#D88C78', .76), 'nostril': ('#864538', .8),
        'blush': ('#EFA99B', .8), 'gold': ('#E9B847', .39), 'gold-edge': ('#AD741F', .47),
        'white': ('#FFF4E8', .22), 'iris': ('#793B18', .28), 'iris-light': ('#B77635', .32),
        'iris-dark': ('#3A2116', .3), 'black': ('#171317', .32), 'shine': ('#FFFFFF', .12),
    }
    materials=[]
    for name,(hexcolor,roughness) in palette.items():
        # glTF 颜色因子是线性空间，不能直接写入网页 sRGB 数值，否则颜色会发灰。
        srgb=np.array([int(hexcolor[i:i+2],16)/255 for i in (1,3,5)])
        linear=np.where(srgb<=.04045,srgb/12.92,((srgb+.055)/1.055)**2.4)
        materials.append(dict(name=name,pbrMetallicRoughness=dict(baseColorFactor=[*linear.tolist(),1],
                            metallicFactor=.12 if name.startswith('gold') else 0,roughnessFactor=roughness)))
    mid={m['name']:i for i,m in enumerate(materials)}
    groups={}

    def emit(vertices, faces, mat, bone, center=None):
        v=np.array(vertices); f=np.array(faces,dtype=int)
        normal=np.cross(v[f[:,1]]-v[f[:,0]],v[f[:,2]]-v[f[:,0]])
        if center is not None and np.sum(normal*(v[f].mean(1)-center))<0:
            f=f[:,[0,2,1]];normal=-normal
        n=np.zeros_like(v)
        for i in range(3): np.add.at(n,f[:,i],normal)
        n/=np.maximum(np.linalg.norm(n,axis=1,keepdims=True),1e-15)
        g=groups.setdefault(mat,dict(p=[],n=[],j=[],w=[],f=[]))
        offset=len(g['p']);g['p'].extend(v);g['n'].extend(n);g['f'].extend((f+offset).tolist())
        for point in v:
            influence=bone(point) if callable(bone) else [(bone,1.)]
            g['j'].append([ids[b] for b,w in influence]+[0]*(4-len(influence)))
            g['w'].append([w for b,w in influence]+[0]*(4-len(influence)))

    def ellipsoid(center, scale, mat, bone='head', power=1, rotate=0, resolution=40):
        c=np.array(center);v=[];faces=[];rings=resolution//2;segments=resolution
        co,si=math.cos(rotate),math.sin(rotate)
        for i in range(rings+1):
            theta=math.pi*i/rings
            for j in range(segments):
                phi=2*math.pi*j/segments
                q=np.array([math.sin(theta)*math.cos(phi),math.cos(theta),math.sin(theta)*math.sin(phi)])
                q=np.sign(q)*np.abs(q)**power*np.array(scale)
                q[:2]=[co*q[0]-si*q[1],si*q[0]+co*q[1]];v.append(q+c)
        for i in range(rings):
            for j in range(segments):
                a=i*segments+j;b=i*segments+(j+1)%segments;c1=a+segments;d=b+segments
                if i>0:faces.append([a,b,c1])
                if i<rings-1:faces.append([b,d,c1])
        emit(v,faces,mat,bone,c)

    def tube(points, radii, mat, bone='head', sides=12):
        points=np.array(points);v=[];f=[]
        if np.isscalar(radii):radii=[radii]*len(points)
        for i,p in enumerate(points):
            direction=points[min(i+1,len(points)-1)]-points[max(0,i-1)];direction/=np.linalg.norm(direction)
            axis=np.array([0.,0.,1.])
            if abs(direction@axis)>.95:axis=np.array([0.,1.,0.])
            u=np.cross(direction,axis);u/=np.linalg.norm(u);w=np.cross(direction,u)
            for j in range(sides):
                a=j*2*math.pi/sides;v.append(p+radii[i]*(math.cos(a)*u+math.sin(a)*w))
        for i in range(len(points)-1):
            for j in range(sides):
                a=i*sides+j;b=i*sides+(j+1)%sides;f.extend([[a,b,a+sides],[b,b+sides,a+sides]])
        # 曲线两端使用三角扇封口，防止动作后露出空腔。
        v.extend([points[0],points[-1]])
        for j in range(sides):
            f.append([len(v)-2,(j+1)%sides,j]);a=(len(points)-1)*sides
            f.append([len(v)-1,a+j,a+(j+1)%sides])
        emit(v,f,mat,bone)

    def torso(p):
        t=float(np.clip((p[1]-.79)/.23,0,1));return [('hips',1-t),('chest',t)]

    # 连体衣为宽腹窄肩的圆润外轮廓，配胸标、纽扣和顺轮廓缝线。
    ellipsoid((0,.865,0),(.221,.245,.164),'suit',torso,power=.94,resolution=64)
    ellipsoid((0,1.055,0),(.112,.045,.09),'seam','neck')
    ellipsoid((0,.865,.158),(.083,.058,.014),'gold-edge',torso,power=.85)
    ellipsoid((0,.868,.169),(.076,.051,.012),'gold',torso,power=.85)
    for s in [-1,1]:
        ellipsoid((s*.023,.87,.181),(.009,.025,.0025),'gold-edge',torso)
        ellipsoid((s*.086,.971,.145),(.018,.018,.009),'gold-edge',torso)
        ellipsoid((s*.086,.974,.152),(.013,.013,.005),'gold',torso)
        t=np.linspace(0,1,36)
        tube([(s*(.13+.045*math.sin(math.pi*q)),1.035-.35*q,.115+.015*math.sin(math.pi*q)) for q in t],.0025,'seam',torso)

    # 手臂先按自然 A 姿态建立，再由共享转换器同时烘焙 T 姿态及逆绑定。
    for side,s in [('left',1),('right',-1)]:
        def armweight(p,side=side,s=s):
            t=float(np.clip((abs(p[0])-.29)/.08,0,1));return [(side+'UpperArm',1-t),(side+'LowerArm',t)]
        ellipsoid((s*.275,.956,0),(.073,.115,.069),'suit',armweight,rotate=s*.8)
        ellipsoid((s*.357,.885,.001),(.058,.083,.062),'gold',side+'LowerArm',rotate=s*.88)
        ellipsoid((s*.345,.9,.001),(.065,.024,.067),'gold-edge',side+'LowerArm',rotate=s*.88)
        ellipsoid((s*.345,.903,.004),(.064,.021,.068),'gold',side+'LowerArm',rotate=s*.88)
        ellipsoid((s*.425,.825,.004),(.051,.061,.034),'gold',side+'Hand',rotate=s*.75)
        # 指形单独塑造但与手骨刚性绑定，避免声称不存在的逐指追踪。
        for j in range(4):
            ellipsoid((s*(.445+.014*j),.79+.012*j,.004),(.013,.034-.002*abs(j-1),.018),'gold',side+'Hand',rotate=s*.75,resolution=24)
        ellipsoid((s*.397,.813,.032),(.022,.037,.024),'gold',side+'Hand',rotate=-s*.35)
        ellipsoid((s*.098,.664,0),(.083,.109,.078),'suit',side+'UpperLeg')
        ellipsoid((s*.098,.574,.012),(.083,.084,.087),'gold',side+'Foot',power=.75)
        ellipsoid((s*.098,.617,.005),(.09,.024,.091),'gold',side+'LowerLeg',power=.82)
        ellipsoid((s*.098,.514,.045),(.087,.046,.116),'gold',side+'Foot',power=.82)
        ellipsoid((s*.098,.489,.046),(.089,.014,.114),'gold-edge',side+'Foot',power=.72)

    # 头套保留后脑及脸缘；脸的圆角方形轮廓与上窄下宽的嘴鼻区分开建模。
    ellipsoid((0,1.297,-.018),(.303,.286,.245),'cap',power=.86,resolution=72)
    ellipsoid((0,1.285,.026),(.280,.252,.233),'skin',power=.86,resolution=80)
    for s in [-1,1]:
        ellipsoid((s*.295,1.326,-.015),(.048,.06,.032),'skin',rotate=s*.5)
        ellipsoid((s*.314,1.326,.008),(.018,.032,.007),'blush',rotate=s*.5)
        ellipsoid((s*.277,1.392,.055),(.019,.035,.022),'white',rotate=s*.2)
        # 红帽双峰、黄色帽沿和眉上红色隆起，是角色的主要识别特征。
        ellipsoid((s*.126,1.537,.018),(.139,.099,.16),'cap',rotate=-s*.16,resolution=48)
        ellipsoid((s*.126,1.548,.153),(.101,.048,.019),'gold',rotate=-s*.17)
        ellipsoid((s*.129,1.516,.16),(.154,.053,.069),'cap',rotate=-s*.22,resolution=56)
    ellipsoid((0,1.529,.161),(.035,.028,.048),'cap',rotate=math.pi/4)

    # 大棕眼使用真正的凸面几何；虹膜辐射纹、外环、瞳孔和两级高光均随头部运动。
    for s in [-1,1]:
        x=s*.121;y=1.342
        ellipsoid((x,y,.242),(.077,.088,.022),'skin',rotate=-s*.08)
        ellipsoid((x,y+.002,.248),(.069,.079,.027),'white',rotate=-s*.08)
        ellipsoid((x-s*.004,y-.003,.273),(.052,.060,.016),'iris-dark')
        ellipsoid((x-s*.004,y-.003,.279),(.047,.055,.012),'iris')
        for j in range(44):
            a=2*math.pi*j/44
            r1=.034+.002*math.sin(j*11);r2=.046
            pts=[(x-s*.004+r*math.cos(a),y-.003+r*1.16*math.sin(a),.288-.006*(r/.047)**2) for r in np.linspace(r1,r2,3)]
            tube(pts,.0009,'iris-light' if j%3 else 'iris-dark',sides=6)
        ellipsoid((x-s*.004,y-.001,.291),(.034,.042,.008),'black')
        ellipsoid((x-.019,y+.026,.299),(.014,.018,.003),'shine',rotate=-.4,resolution=24)
        ellipsoid((x+.017,y-.028,.299),(.005,.006,.002),'shine',resolution=20)
        points=[]
        for t in np.linspace(0,1,24):
            points.append((s*(.067+.101*t),1.432+.020*math.sin(math.pi*t)-.009*t,.253-.016*t))
        tube(points,[.003+.009*math.sin(math.pi*t)**.6 for t in np.linspace(0,1,24)],'black',sides=12)

    # 鼻盘前凸而鼻孔内凹，笑线两端上扬；避免旧素材的小黑点眼和扁平鼻子。
    ellipsoid((0,1.235,.257),(.085,.058,.037),'lip',power=.9)
    ellipsoid((0,1.239,.269),(.079,.052,.035),'skin',power=.88,resolution=56)
    for s in [-1,1]:
        ellipsoid((s*.026,1.243,.303),(.009,.019,.003),'nostril',rotate=-s*.12,resolution=32)
        ellipsoid((s*.029,1.248,.305),(.003,.009,.001),'lip',rotate=-s*.12,resolution=20)
    t=np.linspace(-1,1,56)
    smile=[(.151*q,1.177+.041*q*q,.257-.041*q*q) for q in t]
    tube(smile,[.0015+.0025*(1-q*q) for q in t],'nostril')
    tube([(x,y-.008,z-.001) for x,y,z in smile],[.001+.004*(1-q*q) for q in t],'lip')
    for s in [-1,1]:
        ellipsoid((s*.15,1.221,.218),(.021,.013,.002),'blush',rotate=s*.4)

    meshes=[]
    for name,g in groups.items():
        if len(g['p'])>65535:raise ValueError('Material vertex budget exceeded: '+name)
        attrs={'POSITION':binary.array(g['p'],'VEC3',bounds=True),'NORMAL':binary.array(g['n'],'VEC3'),
               'JOINTS_0':binary.array(g['j'],'VEC4','<u2'),'WEIGHTS_0':binary.array(g['w'],'VEC4')}
        indices=binary.array(np.array(g['f']).flatten(),'SCALAR','<u2')
        meshes.append(dict(name=name,primitives=[dict(attributes=attrs,indices=indices,material=mid[name])]))
        nodes.append(dict(name='GG-Bond-'+name,mesh=len(meshes)-1,skin=0))
    doc=dict(asset=dict(version='2.0',generator='CallBridge reference sculpture 2'),scene=0,
             scenes=[dict(nodes=[0]+list(range(len(definitions),len(nodes))))],nodes=nodes,meshes=meshes,
             materials=materials,skins=[dict(joints=list(range(len(definitions))),skeleton=0,inverseBindMatrices=inv)],
             accessors=binary.accessors,bufferViews=binary.views,buffers=[dict(byteLength=len(binary.data))])
    add_vrm(doc,'gg-bond',ids)
    payload=t_pose(doc,bytes(binary.data),ids)
    root=len(doc['nodes'])
    doc['nodes'].append(dict(name='PortraitPlacement',scale=[.86]*3,translation=[0,.24,0],children=doc['scenes'][0]['nodes']))
    doc['scenes'][0]['nodes']=[root]
    return glb(doc,payload)
