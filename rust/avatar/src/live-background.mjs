// 本文件的目的：不用离场底图，为人物遮挡区域生成轻量的空间补洞底层。
// 只从当前帧已判为背景的像素取色，不复制人物颜色；补洞是近似延展，不是真实场景重建。
export function extendBackground(rgba,mask,width,height){
 if(!Number.isInteger(width)||!Number.isInteger(height)||width<1||height<1||width>80||height>60||rgba.length!==width*height*4||mask.length!==rgba.length)throw Error('背景补洞尺寸无效');
 const n=width*height,owner=new Int32Array(n),queue=new Int32Array(n),out=new Uint8ClampedArray(rgba.length);owner.fill(-1);
 let head=0,tail=0;
 // 多源广度优先传播，每格最多进队一次，时间/内存均有界；任何非零遮罩都不作为背景来源。
 for(let i=0;i<n;i++)if(mask[i*4+3]===0){owner[i]=i;queue[tail++]=i;}
 if(tail===0)return null;
 const visit=(from,to)=>{if(owner[to]<0){owner[to]=owner[from];queue[tail++]=to;}};
 while(head<tail){const i=queue[head++],x=i%width;if(x>0)visit(i,i-1);if(x+1<width)visit(i,i+1);if(i>=width)visit(i,i-width);if(i+width<n)visit(i,i+width);}
 for(let i=0;i<n;i++){const src=owner[i]*4;out[i*4]=rgba[src];out[i*4+1]=rgba[src+1];out[i*4+2]=rgba[src+2];out[i*4+3]=255;}
 return out;
}
