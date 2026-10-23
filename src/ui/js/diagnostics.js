/* Read-only diagnostics for the existing host state/command-result contract. */
(function(global){
'use strict';
function create(options){
  var byId=function(id){return document.getElementById(id);};
  var shade=byId('diagnosticsShade'),entry=byId('pDiagnostics');
  var snapshot=null,readAt=null,returnFocus=null,busy=false,settingsDetails=null;
  var labels={completed:'已完成',started:'已启动 · 未确认完成',cancelled:'已取消',failed:'失败',unavailable:'当前不可用'};
  function node(tag,text,className){var el=document.createElement(tag);if(text!=null)el.textContent=String(text);if(className)el.className=className;return el;}
  function objects(value){return Array.isArray(value)?value.filter(function(item){return item&&typeof item==='object';}):[];}
  function messages(value){return Array.isArray(value)?value.filter(function(item){return item!=null;}).map(function(item){return typeof item==='object'?String(item.message||item.code||'未提供详情'):String(item);}):[];}
  function replace(id,children){var el=byId(id);el.textContent='';children.forEach(function(child){el.appendChild(child);});}
  function list(id,items,empty){replace(id,items.length?items:[node('li',empty,'diagnostics-item diagnostics-empty')]);}
  function time(value){var date=new Date(value);return Number.isFinite(date.getTime())?date.toLocaleTimeString('zh-CN',{hour12:false}):'时间未提供';}
  function badge(text,status){return node('span',text,'diagnostics-badge '+(Object.prototype.hasOwnProperty.call(labels,status)?status:''));}
  function render(){
    var plugins=objects(snapshot&&snapshot.plugins),commands=objects(snapshot&&snapshot.commands);
    var demo=options.isDemo();
    byId('diagnosticsSnapshot').textContent=demo?'演示模式：运行与诊断需连接 SketchUp。':snapshot?'SU 中枢 '+String(snapshot.version||'版本未提供')+' · 上次读取 '+time(readAt):'尚未读取到 SketchUp 状态，请连接后刷新。';
    byId('diagnosticsSettings').disabled=!snapshot||demo||busy;
    var counts=[['已安装',plugins.length],['已禁用',plugins.filter(function(p){return p.enabled===false;}).length],['依赖 / 版本问题',plugins.filter(function(p){return messages(p.dependencyErrors).length>0;}).length],['待重启',plugins.filter(function(p){return p.restartRequired;}).length]];
    replace('diagnosticsSummary',counts.map(function(item){var box=node('div',null,'diagnostics-metric');box.appendChild(node('b',snapshot?item[1]:'—'));box.appendChild(node('span',item[0]));return box;}));
    var storage=snapshot&&snapshot.settingsStorage;
    var readonly=!!(storage&&storage.readOnly);
    byId('diagnosticsStorage').textContent=!storage?'尚无设置存储状态。':readonly?'只读保护：设置暂不能保存。原文件已保留，请查看原因后处理。':'可读写'+(storage.schemaVersion!=null?' · 格式 '+storage.schemaVersion:'')+(storage.revision!=null?' · 修订 '+storage.revision:'');
    var reasons=settingsDetails?messages(settingsDetails.diagnostics):[];
    replace('diagnosticsStorageReasons',reasons.map(function(message){return node('li',message,'diagnostics-item');}));
    if(readonly&&!reasons.length)byId('diagnosticsStorageReasons').appendChild(node('li','详细原因见下方宿主诊断，也可打开设置查看。','diagnostics-item diagnostics-meta'));
    list('diagnosticsErrors',messages(snapshot&&snapshot.errors).map(function(message){return node('li',message,'diagnostics-item');}),snapshot?'宿主未报告诊断信息。':'等待宿主诊断信息。');
    var results=objects(snapshot&&snapshot.commandResults).slice(-30).map(function(result,index){return {result:result,index:index};});
    results.sort(function(a,b){var aa=Number(a.result.recordedAt)||0,bb=Number(b.result.recordedAt)||0;return bb-aa||b.index-a.index;});
    list('diagnosticsResults',results.map(function(record){
      var result=record.result,item=node('li',null,'diagnostics-item');
      var command=commands.find(function(c){return c.id===result.commandId;});
      var head=node('div',null,'diagnostics-item-head');
      head.appendChild(node('strong',command&&command.title||result.commandId||'未提供命令名称'));
      head.appendChild(badge(Object.prototype.hasOwnProperty.call(labels,result.status)?labels[result.status]:'状态未识别',result.status));item.appendChild(head);
      item.appendChild(node('p',result.message||'未提供结果说明。'));
      if(result.code)item.appendChild(node('p','结果码：'+String(result.code),'diagnostics-meta diagnostics-code'));
      if(result.commandId)item.appendChild(node('p','命令：'+String(result.commandId),'diagnostics-meta diagnostics-code'));
      item.appendChild(node('p',typeof result.recordedAt==='number'?time(result.recordedAt):'时间未提供','diagnostics-meta'));
      return item;
    }),snapshot?'本次会话尚无命令结果。运行命令后可在此查看。':'连接后可查看本次会话命令结果。');
    list('diagnosticsPlugins',plugins.map(function(plugin){
      var item=node('li',null,'diagnostics-item'),head=node('div',null,'diagnostics-item-head');
      head.appendChild(node('strong',plugin.name||plugin.id||'未命名插件'));
      head.appendChild(badge(plugin.enabled===false?'已禁用':'已启用',''));
      if(plugin.restartRequired)head.appendChild(badge('待重启','started'));
      var problems=messages(plugin.dependencyErrors);
      if(problems.length)head.appendChild(badge('依赖 / 版本问题','unavailable'));
      item.appendChild(head);item.appendChild(node('p',String(plugin.version||'版本未提供')+' · '+(plugin.loaded?'已加载':'尚未加载'),'diagnostics-meta'));
      problems.forEach(function(problem){item.appendChild(node('p',problem));});return item;
    }),snapshot?'宿主当前未列出已安装插件。':'连接后可查看已安装插件。');
  }
  function setState(value){snapshot=value;readAt=Date.now();settingsDetails=null;if(!shade.hidden)render();}
  function record(value){
    if(!snapshot||!value||!value.invocationId)return;
    var results=objects(snapshot.commandResults).filter(function(item){return item.invocationId!==value.invocationId;});results.push(value);
    snapshot=Object.assign({},snapshot,{commandResults:results.slice(-30)});
    if(!shade.hidden)render();
  }
  async function refresh(){
    if(busy||options.isDemo())return;
    busy=true;var button=byId('diagnosticsRefresh');button.disabled=true;button.textContent='刷新中…';
    byId('diagnosticsRefreshError').hidden=true;render();
    try{
      await options.refresh();
      // Detailed storage causes already exist on get_settings; no new host action.
      try{settingsDetails=await options.readSettings();}
      catch(error){byId('diagnosticsRefreshError').textContent='设置详情读取失败：'+error.message;byId('diagnosticsRefreshError').hidden=false;}
    }catch(error){byId('diagnosticsRefreshError').textContent='刷新失败：'+error.message+(snapshot?'。下方保留上次读取的状态。':'');byId('diagnosticsRefreshError').hidden=false;}
    finally{busy=false;button.disabled=false;button.textContent='刷新状态';render();}
  }
  function open(){returnFocus=document.activeElement;shade.hidden=false;entry.setAttribute('aria-expanded','true');render();byId('diagnosticsClose').focus();refresh();}
  function close(){shade.hidden=true;entry.setAttribute('aria-expanded','false');var target=returnFocus;returnFocus=null;(target&&target.isConnected?target:entry).focus();}
  entry.addEventListener('click',open);
  byId('diagnosticsClose').addEventListener('click',close);
  byId('diagnosticsRefresh').addEventListener('click',refresh);
  byId('diagnosticsSettings').addEventListener('click',function(){close();options.openSettings();});
  shade.addEventListener('click',function(event){if(event.target===shade)close();});
  document.addEventListener('focusin',function(event){if(!shade.hidden&&!shade.contains(event.target))byId('diagnosticsClose').focus();});
  document.addEventListener('keydown',function(event){
    if(shade.hidden||event.isComposing||event.keyCode===229)return;
    if(event.key==='Escape'){event.preventDefault();close();return;}
    if(event.key==='Tab'){
      var items=Array.from(shade.querySelectorAll('button:not(:disabled),summary')).filter(function(el){return el.offsetParent!==null;});
      var first=items[0],last=items[items.length-1];
      if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus();}
      else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus();}
    }
  });
  return {setState:setState,record:record,isOpen:function(){return !shade.hidden;}};
}
global.SUHubDiagnostics={create:create};
})(window);
