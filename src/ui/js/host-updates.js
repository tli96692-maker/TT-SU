/* Host release reminders. Downloads remain an explicit browser action. */
(function(global){
'use strict';
function repositoryName(value){
  if(typeof value!=='string')return null;
  var name=value.trim();
  if(/^https:\/\//i.test(name)){
    try{var url=new URL(name);if(url.origin!=='https://github.com'||url.username||url.password||url.search||url.hash)return null;name=url.pathname.replace(/^\//,'').replace(/\/$/,'');}catch(error){return null;}
  }
  if(!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(name)||name.split('/').some(function(part){return part==='.'||part==='..';}))return null;
  return name;
}
function safeReleaseUrl(value,repository,download){
  var repo=repositoryName(repository);if(!repo||typeof value!=='string')return null;
  try{
    var url=new URL(value);
    if(url.origin!=='https://github.com'||url.username||url.password||url.search||url.hash)return null;
    var prefix='/'+repo+'/releases/'+(download?'download/':'tag/');
    if(url.pathname.slice(0,prefix.length).toLowerCase()!==prefix.toLowerCase())return null;
    var parts=url.pathname.slice(prefix.length).split('/');
    if(parts.length!==(download?2:1)||parts.some(function(part){return !part||part==='.'||part==='..';}))return null;
    if(download&&!/\.rbz$/i.test(parts[1]))return null;
    return url.href;
  }catch(error){return null;}
}
function create(options){
  var byId=function(id){return document.getElementById(id);};
  var entry=byId('pHostUpdates'),shade=byId('hostUpdatesShade');
  var config=null,result=null,busy=false,automaticStarted=false,returnFocus=null,initialized=false;
  var statuses={
    idle:['尚未检查','检查此渠道的 SU 中枢发行版本。'],
    checking:['正在检查更新','检查完成后会更新此处状态，可以先关闭窗口。'],
    available:['有可用更新','可查看发布说明，再下载 RBZ 手动安装。'],
    up_to_date:['当前渠道无需更新','发行信息未发现比当前安装版本更新的版本。'],
    no_release:['尚无可用发行版','当前渠道尚未提供可安装的发行版。'],
    incompatible:['发行版不兼容当前环境','请查看兼容要求，当前不提供下载入口。'],
    compatibility_unknown:['兼容性尚未确认','当前环境信息不足，确认兼容性前不提供下载入口。'],
    source_unavailable:['无法访问发行仓库','仓库或发行资源不可用，当前无法确认是否有新版本。'],
    offline:['暂时无法检查更新','网络连接不可用，当前无法确认是否为最新版本。'],
    rate_limited:['检查暂受限','GitHub 请求频率受限，请稍后再试；当前无法确认是否为最新版本。'],
    invalid_response:['发行信息无效','无法确认发行信息，请稍后重试或联系维护者。'],
    unconfigured:['尚未配置更新仓库','此版本尚未绑定 GitHub 更新仓库。'],
    invalid_configuration:['更新配置无效','请联系维护者检查发行仓库和渠道配置。'],
    unsupported:['当前宿主不支持更新检查','请安装包含更新检查功能的完整宿主版本。'],
    demo:['演示模式','演示模式不会检查或下载更新，请从 SketchUp 打开 SU 中枢。']
  };
  function status(){if(options.isDemo())return 'demo';if(busy)return 'checking';return result&&result.status||'idle';}
  function text(id,value){byId(id).textContent=value==null||value===''?'—':String(value);}
  function render(){
    var key=status(),description=statuses[key]||statuses.invalid_response;
    var repo=repositoryName(config&&config.repository),data=result||{};
    text('hostUpdatesCurrent',config&&config.currentVersion||options.currentVersion()||'尚未读取');
    text('hostUpdatesRepository',repo?'TT中枢 · '+repo:'未配置');
    var channel=config&&config.channel;
    text('hostUpdatesChannel',{stable:'正式版',beta:'测试版',preview:'预览版'}[channel]||channel||'未配置');
    text('hostUpdatesVersion',data.version||'尚未读取');text('hostUpdatesPublished',data.publishedAt||'尚未读取');
    text('hostUpdatesStateLabel',description[0]);
    text('hostUpdatesMessage',description[1]+(!busy&&data.message?' '+String(data.message):''));
    byId('hostUpdatesStatus').dataset.state=key;
    text('hostUpdatesCompatibility',key==='incompatible'?'此发行版不适用于当前 SketchUp / 平台环境。':data.compatible===true?'发行信息标记为兼容当前环境；具体支持范围请查看发布说明。':'兼容性尚未确认，请在下载前核对发布说明中的 SketchUp 版本与平台要求。');
    text('hostUpdatesNotes',data.notes||'尚无发布说明。');
    var release=safeReleaseUrl(data.releaseUrl,repo,false),download=safeReleaseUrl(data.downloadUrl,repo,true);
    byId('hostUpdatesRelease').hidden=!release||busy||options.isDemo();
    byId('hostUpdatesDownload').hidden=key!=='available'||!download||data.compatible!==true;
    var checksum=typeof data.sha256==='string'&&/^[a-f0-9]{64}$/i.test(data.sha256)?data.sha256:null;
    byId('hostUpdatesChecksumSection').hidden=!checksum||options.isDemo();text('hostUpdatesChecksum',checksum);
    byId('hostUpdatesCheck').disabled=busy||options.isDemo()||!options.available();
    byId('hostUpdatesCheck').textContent=busy?'检查中…':'检查更新';
    var update=result&&result.status==='available'&&result.compatible===true;
    byId('hostUpdateNotice').hidden=!update||options.isDemo();
    text('hostUpdateNoticeText',update?'中枢有可用更新：'+String(result.version||'新版本'):'');
  }
  function validateResult(value){
    if(!value||!Object.prototype.hasOwnProperty.call(statuses,value.status)||['idle','checking','demo','unsupported'].indexOf(value.status)>=0)return {status:'invalid_response',message:'宿主未提供可识别的更新状态。'};
    if(['available','up_to_date','no_release','incompatible','compatibility_unknown'].indexOf(value.status)>=0&&value.ok!==true)return {status:'invalid_response',message:'宿主未确认此次发行查询成功。'};
    if(value.releaseUrl&&!safeReleaseUrl(value.releaseUrl,config&&config.repository,false)||value.downloadUrl&&!safeReleaseUrl(value.downloadUrl,config&&config.repository,true))return {status:'invalid_response',message:'发行链接与配置仓库不一致或格式不受支持，已停用链接。'};
    if(value.status==='available'&&value.compatible!==true)return Object.assign({},value,{status:'incompatible'});
    return value;
  }
  async function check(){
    if(busy)return;
    initialized=true;
    if(options.isDemo()){result={status:'demo'};render();return;}
    if(!options.available()){result={status:'unsupported'};render();return;}
    busy=true;byId('hostUpdatesActionError').hidden=true;render();
    try{
      config=await options.request('get_host_update_config');
      if(!config||config.status!=='ready'||config.ok!==true){
        result={status:config&&config.status==='unconfigured'?'unconfigured':'invalid_configuration',message:config&&config.message};
      }else if(!repositoryName(config.repository)){
        result={status:'invalid_configuration',message:'未提供有效的 GitHub 仓库。'};
      }else{result=validateResult(await options.request('check_host_update'));}
    }catch(error){result={status:'offline',message:error&&error.message||'请求未完成。'};}
    finally{busy=false;render();}
  }
  function autoCheck(){
    if(automaticStarted||options.isDemo()||!options.available())return;
    automaticStarted=true;check();
  }
  function open(){
    options.beforeOpen();returnFocus=entry;shade.hidden=false;entry.setAttribute('aria-expanded','true');render();byId('hostUpdatesClose').focus();
    if(!initialized)check();
  }
  function close(){shade.hidden=true;entry.setAttribute('aria-expanded','false');var target=returnFocus;returnFocus=null;(target&&target.isConnected?target:entry).focus();}
  async function openLink(download){
    var data=result||{},url=safeReleaseUrl(download?data.downloadUrl:data.releaseUrl,config&&config.repository,download);
    if(options.isDemo()||busy||!url||download&&(data.status!=='available'||data.compatible!==true))return;
    byId('hostUpdatesActionError').hidden=true;
    try{await options.openUrl(url);}catch(error){text('hostUpdatesActionError','打开浏览器失败：'+error.message);byId('hostUpdatesActionError').hidden=false;}
  }
  entry.addEventListener('click',open);byId('hostUpdateNoticeOpen').addEventListener('click',open);
  byId('hostUpdatesClose').addEventListener('click',close);byId('hostUpdatesCheck').addEventListener('click',check);
  byId('hostUpdatesRelease').addEventListener('click',function(){openLink(false);});
  byId('hostUpdatesDownload').addEventListener('click',function(){openLink(true);});
  shade.addEventListener('click',function(event){if(event.target===shade)close();});
  document.addEventListener('focusin',function(event){if(!shade.hidden&&!shade.contains(event.target))byId('hostUpdatesClose').focus();});
  document.addEventListener('keydown',function(event){
    if(shade.hidden||event.isComposing||event.keyCode===229)return;
    if(event.key==='Escape'){event.preventDefault();close();return;}
    if(event.key==='Tab'){
      var items=Array.from(shade.querySelectorAll('button:not(:disabled)')).filter(function(el){return el.offsetParent!==null;});
      var first=items[0],last=items[items.length-1];
      if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus();}
      else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus();}
    }
  });
  return {autoCheck:autoCheck,isOpen:function(){return !shade.hidden;},close:close};
}
global.SUHubHostUpdates={create:create};
})(window);
