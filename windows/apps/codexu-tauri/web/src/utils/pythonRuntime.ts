import {parseRuntimeComponent,type RuntimeComponent} from './runtimeSetup';

export type PythonRuntime = RuntimeComponent;
export function parsePythonRuntime(raw:unknown):PythonRuntime {
 const result=parseRuntimeComponent(raw);
 if(result.state==='ready'){
  const match=/^3\.(\d+)\.(\d+)$/.exec(result.version!);
  if(!match||!Number.isSafeInteger(Number(match[1]))||Number(match[1])<9||!Number.isSafeInteger(Number(match[2])))throw Error('python_response_invalid');
 }
 return result;
}
