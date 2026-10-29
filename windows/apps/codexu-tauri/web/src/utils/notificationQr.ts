import { qrcodegen } from '../vendor/qrcodegen/qrcodegen';
/** Encode only the transient native pairing payload. No URL/image/network API. */
export function notificationQr(content:string):{size:number;path:string}{
 if(!content||new TextEncoder().encode(content).length>4096||/[\x00-\x1f\x7f]/.test(content))throw Error('invalid_qr_content');
 const code=qrcodegen.QrCode.encodeText(content,qrcodegen.QrCode.Ecc.MEDIUM);const border=4;let path='';
 for(let y=0;y<code.size;y++){let x=0;while(x<code.size){if(!code.getModule(x,y)){x++;continue;}const start=x;while(x<code.size&&code.getModule(x,y))x++;const width=x-start;path+=`M${start+border},${y+border}h${width}v1h-${width}z`;}}
 return {size:code.size+border*2,path};
}
