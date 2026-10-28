'use strict';
// This sandboxed frame has no Tauri, Node, filesystem, account or network API.
// The parent can send only an already validated native statistics projection.
(() => {
  const send = (type, payload = {}) => parent.postMessage({channel:'aigoodbro-token-monitor',type,...payload},'*');
  let snapshotID = null;
  window.webkit={messageHandlers:{
    chartPreferences:{postMessage:value=>{if(value?.snapshotID===snapshotID)send('preferences',value);}},
    chartSize:{postMessage:value=>{if(value?.snapshotID===snapshotID)send('size',value);}},
  }};
  window.addEventListener('message',event=>{
    const message=event.data;
    if(event.source!==parent||message?.channel!=='aigoodbro-token-monitor')return;
    if(message.type==='hello'){send('ready');return;}
    if(message.type!=='render'||typeof message.snapshotID!=='string')return;
    try{
      snapshotID=message.snapshotID;
      window.__renderTrend(message.snapshot,{snapshotID,language:message.language==='en'?'en':'zh-Hans',homePreferences:message.preferences,summaryTotals:null});
      const preset=window.TokenMonitorThemePresets.THEME_PRESETS.find(item=>item.id===(message.light?'porcelain':'default'));
      const colors={...preset.colors};for(const key of ['accent','bg','text','muted'])if(/^#[a-f0-9]{6}$/i.test(message.appearance?.[key]||''))colors[key]=message.appearance[key];
      // getSettings resolves asynchronously in the original controller. Keep
      // the shared settings object consistent so its later boot continuation
      // cannot overwrite the host's confirmed appearance.
      window.AiGoodBroDashboard.settings.themeColors=colors;
      for(const {name,value} of window.TokenMonitorThemePresets.themeCssVarEntries(colors)){
        if(value)document.documentElement.style.setProperty(name,value);else document.documentElement.style.removeProperty(name);
      }
      document.documentElement.style.backgroundColor=colors.bg;
      send('rendered',{snapshotID});
    }catch{send('failed',{snapshotID});}
  });
  send('ready');
})();
