// Browser evidence only: real panel UI with an explicit host-state fixture.
const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const { chromium, root, fileURL } = require('./ui-test-helpers.cjs');
const out = path.join(root, 'test-results');
function host() {
  window.__xss = 0;
  window.__reads = 0;
  window.__failState = false;
  window.__hostState = {
    version:'0.2.1', categories:{model:'建模'},
    plugins:[
      {id:'scale',name:'中枢缩放',version:'0.2.1',category:'model',enabled:true,loaded:true},
      {id:'disabled',name:'已停用工具',version:'1.0.0',category:'model',enabled:false},
      {id:'dependency',name:'待补充依赖',version:'1.0.0',category:'model',dependencyErrors:['缺少 TT_Lib² 依赖，请在官方渠道安装。']},
      {id:'restart',name:'更新待重启',version:'1.1.0',category:'model',restartRequired:true}
    ],
    commands:[{id:'scale',title:'中枢缩放',fromPlugin:'scale',category:'model'}],
    settingsStorage:{readOnly:true,schemaVersion:1,revision:2},
    errors:['设置文件无法解析，已保留原文件。'],
    settings:{favorites:[],sources:[],shortcuts:[]},
    commandResults:['completed','started','cancelled','failed','unavailable'].map((status,index)=>({
      commandId:'scale',invocationId:'fixture-'+index,status,recordedAt:Date.now()+index,
      code:status==='failed'?'invalid_geometry':'fixture_'+status,
      message:{completed:'缩放完成。',started:'工具已启动，等待后续结果。',cancelled:'已取消，模型未修改。',failed:'所选几何不支持当前操作。',unavailable:'当前未选择可用对象。'}[status]
    }))
  };
  const reply=(callback,value,id)=>setTimeout(()=>window[callback](JSON.parse(JSON.stringify(value)),id),5);
  window.sketchup={
    get_state:id=>{window.__reads++;reply('__onState',window.__failState?{ok:false,message:'测试连接中断'}:window.__hostState,id);},
    get_settings:id=>reply('__onSettings',{ok:true,settings:window.__hostState.settings,storage:window.__hostState.settingsStorage,diagnostics:window.__hostState.settingsStorage.readOnly?[{message:'设置文件无法解析，已保留原文件。'}]:[]},id),
    get_market:id=>reply('__onMarket',{plugins:[],sources:[],errors:[]},id),
    js_log:()=>{}
  };
}
(async()=>{
  fs.mkdirSync(out,{recursive:true});
  const browser=await chromium.launch();
  const errors=[];
  try {
    const page=await browser.newPage({viewport:{width:420,height:780}});
    page.on('pageerror',error=>errors.push(error.message));
    await page.addInitScript(host);
    await page.goto(fileURL('panel'));
    await page.waitForFunction(()=>document.querySelector('#pConn').textContent==='已连接');
    await page.locator('#pSearch').fill('缩放');
    await page.locator('#pDiagnostics').click();
    await page.waitForFunction(()=>document.querySelector('#diagnosticsRefresh').textContent==='刷新状态'&&window.__reads>=2);
    assert.deepEqual(await page.locator('.diagnostics-metric b').allTextContents(),['4','1','1','1']);
    for(const status of ['已完成','已启动 · 未确认完成','已取消','失败','当前不可用'])assert.match(await page.locator('#diagnosticsResults').textContent(),new RegExp(status));
    assert.match(await page.locator('#diagnosticsStorage').textContent(),/只读保护/);
    assert.match(await page.locator('#diagnosticsStorageReasons').textContent(),/无法解析/);
    assert.match(await page.locator('#diagnosticsResults').textContent(),/invalid_geometry/);
    assert.match(await page.locator('#diagnosticsPlugins').textContent(),/TT_Lib²/);
    assert.equal(await page.locator('#diagnosticsClose').evaluate(el=>el===document.activeElement),true);
    await page.keyboard.press('Shift+Tab');
    assert.equal(await page.locator('#diagnosticsRefresh').evaluate(el=>el===document.activeElement),true);
    await page.keyboard.press('Tab');
    assert.equal(await page.locator('#diagnosticsClose').evaluate(el=>el===document.activeElement),true);
    await page.keyboard.press('Control+f');
    assert.equal(await page.locator('#pSearch').evaluate(el=>el===document.activeElement),false);
    for(const width of [420,760]){
      await page.setViewportSize({width,height:780});
      assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,'page overflow '+width);
      assert.equal(await page.locator('.diagnostics-body').evaluate(el=>el.scrollWidth>el.clientWidth),false,'drawer overflow '+width);
      await page.screenshot({path:path.join(out,'diagnostics-fixture-'+width+'.png')});
    }
    await page.keyboard.press('Escape');
    assert.equal(await page.locator('#diagnosticsShade').isVisible(),false);
    assert.equal(await page.locator('#pDiagnostics').evaluate(el=>el===document.activeElement),true);
    assert.equal(await page.locator('#pSearch').inputValue(),'缩放','Escape leaked into background search');
    await page.locator('#pDiagnostics').click();
    await page.waitForFunction(()=>!document.querySelector('#diagnosticsSettings').disabled);
    await page.locator('#diagnosticsSettings').click();
    await page.locator('#settingsShade').waitFor({state:'visible'});
    assert.equal(await page.locator('#settingsSave').isDisabled(),true);
    assert.equal(await page.locator('#diagnosticsShade').isVisible(),false);
    await page.keyboard.press('Escape');
    assert.equal(await page.locator('#pDiagnostics').evaluate(el=>el===document.activeElement),true);
    await page.locator('#pDiagnostics').click();
    await page.waitForFunction(()=>!document.querySelector('#diagnosticsRefresh').disabled);
    await page.evaluate(()=>{
      const result={...window.__hostState.commandResults[1],status:'completed',message:'喷漆会话结束。',recordedAt:Date.now()+100};
      window.__onCommandResult(result);window.__onCommandResult(result);
    });
    assert.equal(await page.locator('#diagnosticsResults > li').count(),5,'terminal event duplicates invocation');
    assert.equal(await page.locator('#diagnosticsResults .started').count(),0,'terminal event left stale started result');
    await page.evaluate(()=>{window.__failState=true;});
    await page.locator('#diagnosticsRefresh').click();
    await page.waitForFunction(()=>!document.querySelector('#diagnosticsRefresh').disabled);
    assert.match(await page.locator('#diagnosticsRefreshError').textContent(),/刷新失败.*测试连接中断.*上次读取/);
    assert.deepEqual(await page.locator('.diagnostics-metric b').allTextContents(),['4','1','1','1']);
    await page.evaluate(()=>{
      window.__failState=false;
      const bad='<img src=x onerror="window.__xss++">'+('很长的诊断内容'.repeat(50));
      window.__hostState.plugins[0].name=bad;
      window.__hostState.plugins[0].dependencyErrors=[bad];
      window.__hostState.errors=[bad];
      window.__hostState.commandResults=[{commandId:bad,invocationId:'xss',status:'failed',message:bad,code:bad}];
      window.__hostState.settingsStorage.readOnly=false;
    });
    await page.locator('#diagnosticsRefresh').click();
    await page.waitForFunction(()=>!document.querySelector('#diagnosticsRefresh').disabled);
    assert.equal(await page.locator('#diagnosticsShade img').count(),0);
    assert.equal(await page.evaluate(()=>window.__xss),0);
    assert.match(await page.locator('#diagnosticsErrors').textContent(),/<img src=x/);
    for(const width of [420,760]){
      await page.setViewportSize({width,height:780});
      assert.equal(await page.locator('.diagnostics-body').evaluate(el=>el.scrollWidth>el.clientWidth),false,'long content overflow '+width);
    }
    await page.evaluate(()=>{
      window.__hostState.plugins=[];window.__hostState.commands=[];
      window.__hostState.errors=[];window.__hostState.commandResults=[];
    });
    await page.locator('#diagnosticsRefresh').click();
    await page.waitForFunction(()=>!document.querySelector('#diagnosticsRefresh').disabled);
    assert.deepEqual(await page.locator('.diagnostics-metric b').allTextContents(),['0','0','0','0']);
    assert.match(await page.locator('#diagnosticsResults').textContent(),/尚无命令结果/);
    assert.match(await page.locator('#diagnosticsPlugins').textContent(),/未列出已安装插件/);
    assert.match(await page.locator('#diagnosticsErrors').textContent(),/未报告/);
    assert.match(await page.locator('#diagnosticsStorage').textContent(),/可读写/);
    assert.equal(await page.locator('#diagnosticsStorageReasons li').count(),0);
    // A disconnected host must show unknown counts instead of fake healthy zeros.
    const disconnected=await browser.newPage({viewport:{width:420,height:780}});
    disconnected.on('pageerror',error=>errors.push(error.message));
    await disconnected.goto(fileURL('panel'));
    await disconnected.locator('#retryConnection').waitFor();
    await disconnected.locator('#pDiagnostics').click();
    assert.deepEqual(await disconnected.locator('.diagnostics-metric b').allTextContents(),['—','—','—','—']);
    assert.match(await disconnected.locator('#diagnosticsSnapshot').textContent(),/尚未读取/);
    assert.deepEqual(errors,[]);
    console.log('PASS: diagnostics counts/status/codes, readonly reasons/settings navigation, live terminal dedup, refresh failure, truthful empty/disconnected state, keyboard/focus, XSS and 420/760 overflow; 0 page errors.');
  }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exit(1);});
