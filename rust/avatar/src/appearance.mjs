// 本文件的目的：在已授权修改的官方角色上制作轻量通话服装；原 VRM 文件不改写。
// 保留原蒙皮、纹理、表情与弹簧骨；新增衣领/门襟/发饰都是实际几何，不是平面贴图替身。
import {BufferGeometry,Float32BufferAttribute,Mesh,MeshStandardMaterial,DoubleSide,
 SphereGeometry,TubeGeometry,CatmullRomCurve3,Vector3,Color} from 'three';
export function dressAvatar(vrm){
 const report={name:'澄 · 通话装',addedMeshes:0,addedVertices:0,modifiedMaterials:[]};
 const cloth=new Color('#376b70'),cuff=new Color('#e7dcca');
 vrm.scene.traverse(node=>{
  if(!node.isMesh)return;
  const materials=Array.isArray(node.material)?node.material:[node.material];
  for(const material of materials){
   if(material.name==='Tops_01_CLOTH'){
    // 样例袖口与身体共用已蒙皮网格，以顶点色分区，抬臂时不会出现独立袖口脱离。
    const g=node.geometry.clone(),p=g.attributes.position,colors=[];
    for(let i=0;i<p.count;i++){
     const end=Math.abs(p.getX(i))>.277&&p.getY(i)>1.21;
     const c=(end?cuff:cloth).clone();
     if(!end)c.multiplyScalar(.93+.07*Math.max(0,Math.min(1,(p.getY(i)-.85)/.48)));
     colors.push(c.r,c.g,c.b);
    }
    g.setAttribute('color',new Float32BufferAttribute(colors,3));node.geometry=g;
    // VRM/MToon 默认忽略顶点色，必须显式开启，否则字段存在但画面仍是白色上衣。
    material.vertexColors=true;material.ignoreVertexColor=false;material.color.set('#ffffff');material.needsUpdate=true;
    // 锁定的 Three r186 将 vColor 改为 vec4，MToon 3.5.5 此分支仍直接乘 vec3。
    // 只适配本地服装材质的 RGB 乘法，保留原透明度；不改依赖文件或人物其他材质。
    material.fragmentShader=material.fragmentShader.replaceAll('rgb *= vColor;','rgb *= vColor.rgb;');
    report.modifiedMaterials.push(material.name);
   }
   if(material.name.includes('HAIR')){material.color.set('#a3adbf');report.modifiedMaterials.push(material.name);}
  }
 });
 const ivory=new MeshStandardMaterial({color:'#e9dfcf',roughness:.84,side:DoubleSide});
 const seam=new MeshStandardMaterial({color:'#274f55',roughness:.85,side:DoubleSide});
 const brass=new MeshStandardMaterial({color:'#c8a36a',metalness:.65,roughness:.36});
 const chest=vrm.humanoid.getRawBoneNode('upperChest')??vrm.humanoid.getRawBoneNode('chest');
 const head=vrm.humanoid.getRawBoneNode('head');
 // 设计坐标是该固定样例的米制静止世界坐标；绑定前变换到真实骨骼局部坐标。
 // 不是通用服装插件，换角色时不能复用这些尺寸，必须重新适配。
 const local=(bone,v)=>bone.worldToLocal(new Vector3(...v));
 const add=(bone,geometry,material)=>{
  const mesh=new Mesh(geometry,material);mesh.name='CB_Outfit_'+report.addedMeshes;bone.add(mesh);
  report.addedMeshes++;report.addedVertices+=geometry.attributes.position.count;return mesh;
 };
 const panel=(vertices,material)=>{
  const g=new BufferGeometry();g.setAttribute('position',new Float32BufferAttribute(vertices.flatMap(v=>local(chest,v).toArray()),3));
  g.setIndex([0,1,2,0,2,3]);g.computeVertexNormals();add(chest,g,material);
 };
 for(const side of [-1,1]){
  const collar=[[.017,1.311,.038],[.080,1.281,.068],[.053,1.226,.127],[.008,1.269,.102]].map(([x,y,z])=>[x*side,y,z]);
  panel(collar,ivory);
  const edge=new CatmullRomCurve3(collar.map(v=>local(chest,v)));
  add(chest,new TubeGeometry(edge,16,.0012,4,false),brass);
 }
 // 门襟分段随胸部，保持与原上衣曲面的距离，避免深度冲突。
 const rows=[[1.265,.109],[1.22,.135],[1.15,.145],[1.08,.144],[1.01,.134]];
 for(let i=0;i<rows.length-1;i++){
  const [a,az]=rows[i],[b,bz]=rows[i+1];panel([[-.009,a,az],[.009,a,az],[.009,b,bz],[-.009,b,bz]],seam);
 }
 for(const [y,z] of [[1.237,.131],[1.173,.148],[1.104,.148],[1.036,.143]]){
  const button=add(chest,new SphereGeometry(.004,8,6),brass);button.position.copy(local(chest,[0,y,z]));button.scale.z=.45;
 }
 // 两枚细发夹沿头部绑定，保留发丝弹簧效果；不改变头脸比例或原表情网格。
 for(const shift of [0,.013]){
  const curve=new CatmullRomCurve3([[.063,1.498+shift,.086],[.079,1.509+shift,.079],[.091,1.519+shift,.063]].map(v=>local(head,v)));
  add(head,new TubeGeometry(curve,10,.0024,6,false),brass);
 }
 return report;
}
