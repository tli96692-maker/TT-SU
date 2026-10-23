// Real panel UI; explicit host fixtures, no GitHub network or actual downloads.
const assert=require('assert/strict');
const {chromium,fileURL}=require('./ui-test-helpers.cjs');
function host(initial){
  window.__calls=[];window.__xss=0;window.__delay=initial.delay||0;window.__settingsDelay=0;
  window.__config={ok:true,status:initial.configStatus||'ready',currentVersion:'0.2.3-beta.1',repository:'test-owner/tt-hub',channel:'preview'};
  window.__update={ok:true,status:initial.status||'available',version:'0.2.3-beta.2',compatible:true,
    releaseUrl:'https://github.com/test-owner/tt-hub/releases/tag/v0.2.3-beta.2',
    downloadUrl:'https://github.com/test-owner/tt-hub/releases/download/v0.2.3-beta.2/su_zhongshu_core.rbz',
    sha256:'a'.repeat(64),publishedAt:'2026-10-23T06:00:00Z',notes:'修复问题\n保留用户设置。'};
  const state={version:'0.2.3-beta.1',plugins:[],commands:[],categories:{},errors:[],commandResults:[],settings:{sources:[],shortcuts:[],favorites:[]},settingsStorage:{readOnly:false}};
  const reply=(callback,value,id,delay=5)=>setTimeout(()=>window[callback](JSON.parse(JSON.stringify(value)),id),delay);
  window.sketchup={
    get_state:id=>reply('__onState',state,id),
    get_market:id=>reply('__onMarket',{plugins:[],sources:[],errors:[]},id),
    get_settings:id=>reply('__onSettings',{ok:true,settings:state.settings,storage:state.settingsStorage},id,window.__settingsDelay||5),
    get_host_update_config:id=>{window.__calls.push(['config']);reply('__onHostUpdateConfig',window.__config,id);},
    check_host_update:id=>{window.__calls.push(['check']);if(window.__checkThrow)throw new Error('测试网络错误');reply('__onHostUpdate',window.__update,id,window.__delay||5);},
    open_url:(url,id)=>{window.__calls.push(['url',url]);reply('__onOpenUrl',{ok:true},id);},
    js_log:()=>{}
  };
  if(initial.legacy)delete window.sketchup.check_host_update;
}
(async()=>{
  const browser=await chromium.launch();const errors=[];
  try{
    async function pageFor(initial={},query=''){
      const page=await browser.newPage({viewport:{width:420,height:780}});
      page.on('pageerror',e=>errors.push(e.message));await page.addInitScript(host,initial);
      await page.goto(fileURL('panel')+query);
      await page.waitForFunction(()=>/已连接|演示模式/.test(document.querySelector('#pConn').textContent));
      return page;
    }
    async function idle(page){await page.waitForFunction(()=>document.querySelector('#hostUpdatesStatus').dataset.state!=='checking');}
    async function check(page){await page.locator('#hostUpdatesCheck').click();await idle(page);}
    const page=await pageFor();
    await page.locator('#hostUpdateNotice').waitFor({state:'visible'});
    assert.equal(await page.locator('#hostUpdatesShade').isVisible(),false,'automatic check forced a popup');
    assert.deepEqual(await page.evaluate(()=>window.__calls),[['config'],['check']]);
    await page.locator('#hostUpdateNoticeOpen').click();
    assert.match(await page.locator('#hostUpdatesCurrent').textContent(),/0\.2\.3-beta\.1/);
    assert.match(await page.locator('#hostUpdatesRepository').textContent(),/TT中枢.*test-owner\/tt-hub/);
    assert.equal(await page.locator('#hostUpdatesChannel').textContent(),'预览版');
    assert.equal(await page.locator('#hostUpdatesStatus').getAttribute('data-state'),'available');
    assert.equal(await page.locator('#hostUpdatesDownload').isVisible(),true);
    assert.equal(await page.locator('#hostUpdatesChecksum').textContent(),'a'.repeat(64));
    assert.match(await page.locator('#hostUpdatesChecksumSection').textContent(),/发行方.*尚未验证.*不代表数字签名/s);
    for(const width of [420,760]){
      await page.setViewportSize({width,height:780});
      assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
      assert.equal(await page.locator('#hostUpdatesShade .settings-body').evaluate(el=>el.scrollWidth>el.clientWidth),false);
    }
    await page.keyboard.press('Shift+Tab');
    assert.equal(await page.locator('#hostUpdatesCheck').evaluate(el=>el===document.activeElement),true);
    await page.keyboard.press('Tab');
    assert.equal(await page.locator('#hostUpdatesClose').evaluate(el=>el===document.activeElement),true);
    await page.keyboard.press('Control+f');
    assert.equal(await page.locator('#pSearch').evaluate(el=>el===document.activeElement),false);
    await page.locator('#hostUpdatesRelease').click();await page.locator('#hostUpdatesDownload').click();
    await page.waitForFunction(()=>window.__calls.filter(c=>c[0]==='url').length===2);
    assert.deepEqual(await page.evaluate(()=>window.__calls.filter(c=>c[0]==='url').map(c=>c[1])),[
      'https://github.com/test-owner/tt-hub/releases/tag/v0.2.3-beta.2',
      'https://github.com/test-owner/tt-hub/releases/download/v0.2.3-beta.2/su_zhongshu_core.rbz']);
    await page.keyboard.press('Escape');
    assert.equal(await page.locator('#hostUpdatesShade').isVisible(),false);
    assert.equal(await page.locator('#pHostUpdates').evaluate(el=>el===document.activeElement),true);
    await page.locator('#pHostUpdates').click();
    assert.equal(await page.evaluate(()=>window.__calls.filter(c=>c[0]==='check').length),1,'reopen unnecessarily checked again');
    // Mutual exclusion also handles programmatic entry activation while a modal is open.
    await page.evaluate(()=>document.querySelector('#pDiagnostics').click());
    assert.equal(await page.locator('#hostUpdatesShade').isVisible(),false);
    assert.equal(await page.locator('#diagnosticsShade').isVisible(),true);
    await page.evaluate(()=>document.querySelector('#pHostUpdates').click());
    assert.equal(await page.locator('#diagnosticsShade').isVisible(),false);
    await page.evaluate(()=>document.querySelector('#pSet').click());
    await page.locator('#settingsShade').waitFor({state:'visible'});
    assert.equal(await page.locator('#hostUpdatesShade').isVisible(),false);
    await page.evaluate(()=>document.querySelector('#pHostUpdates').click());
    assert.equal(await page.locator('#settingsShade').isVisible(),false);
    for(const status of ['up_to_date','no_release','incompatible','compatibility_unknown','offline','rate_limited','source_unavailable','invalid_response']){
      await page.evaluate(status=>{window.__update={ok:!['offline','rate_limited','source_unavailable','invalid_response'].includes(status),status,message:'服务器状态：'+status,compatible:status==='up_to_date'};},status);
      await check(page);
      assert.equal(await page.locator('#hostUpdatesStatus').getAttribute('data-state'),status);
      assert.match(await page.locator('#hostUpdatesMessage').textContent(),new RegExp(status));
      assert.equal(await page.locator('#hostUpdatesDownload').isVisible(),false);
      assert.equal(await page.locator('#hostUpdateNotice').isVisible(),false);
      if(status!=='up_to_date')assert.doesNotMatch(await page.locator('#hostUpdatesStateLabel').textContent(),/无需更新|最新/);
    }
    await page.evaluate(()=>{window.__checkThrow=true;});await check(page);
    assert.equal(await page.locator('#hostUpdatesStatus').getAttribute('data-state'),'offline');
    assert.match(await page.locator('#hostUpdatesMessage').textContent(),/无法确认.*测试网络错误/);
    await page.evaluate(()=>{window.__checkThrow=false;window.__update={ok:false,status:'available',compatible:true};});await check(page);
    assert.equal(await page.locator('#hostUpdatesStatus').getAttribute('data-state'),'invalid_response');
    // Malicious metadata is literal text and never becomes executable markup.
    await page.evaluate(()=>{window.__update={ok:true,status:'available',version:'0.2.3-beta.2',compatible:true,releaseUrl:'https://github.com/test-owner/tt-hub/releases/tag/v0.2.3-beta.2',downloadUrl:'https://github.com/test-owner/tt-hub/releases/download/v0.2.3-beta.2/core.rbz',notes:'<img src=x onerror="window.__xss++">'+'很长的说明'.repeat(150)};});
    await check(page);
    assert.match(await page.locator('#hostUpdatesNotes').textContent(),/<img src=x/);
    assert.equal(await page.locator('#hostUpdatesShade img').count(),0);assert.equal(await page.evaluate(()=>window.__xss),0);
    await page.setViewportSize({width:420,height:780});
    assert.equal(await page.locator('#hostUpdatesShade .settings-body').evaluate(el=>el.scrollWidth>el.clientWidth),false);
    for(const url of ['javascript:alert(1)','https://github.com.evil.test/test-owner/tt-hub/releases/tag/x','https://github.com/other/repo/releases/tag/x','https://user:pass@github.com/test-owner/tt-hub/releases/tag/x','https://github.com/test-owner/tt-hub/issues/1']){
      await page.evaluate(url=>{window.__update.releaseUrl=url;},url);await check(page);
      assert.equal(await page.locator('#hostUpdatesStatus').getAttribute('data-state'),'invalid_response');
      assert.equal(await page.locator('#hostUpdatesRelease').isVisible(),false);
      assert.equal(await page.locator('#hostUpdatesDownload').isVisible(),false);
    }
    await page.evaluate(()=>{window.__update.releaseUrl='https://github.com/test-owner/tt-hub/releases/tag/x';window.__update.downloadUrl='https://github.com/other/repo/releases/download/x/core.rbz';});await check(page);
    assert.equal(await page.locator('#hostUpdatesStatus').getAttribute('data-state'),'invalid_response');
    await page.evaluate(()=>{window.__config.repository='<img src=x onerror="window.__xss++">';});await check(page);
    assert.equal(await page.locator('#hostUpdatesStatus').getAttribute('data-state'),'invalid_configuration');
    assert.equal(await page.evaluate(()=>window.__xss),0);
    // A pending settings request cannot open on top of the new drawer.
    await page.keyboard.press('Escape');
    await page.evaluate(()=>{window.__settingsDelay=200;document.querySelector('#pSet').click();document.querySelector('#pHostUpdates').click();});
    await page.waitForFunction(()=>!document.querySelector('#pSet').disabled);
    assert.equal(await page.locator('#settingsShade').isVisible(),false);
    assert.equal(await page.locator('#hostUpdatesShade').isVisible(),true);
    const unconfigured=await pageFor({configStatus:'unconfigured'});await idle(unconfigured);
    assert.deepEqual(await unconfigured.evaluate(()=>window.__calls),[['config']]);
    await unconfigured.locator('#pHostUpdates').click();
    assert.match(await unconfigured.locator('#hostUpdatesStateLabel').textContent(),/未配置/);
    const invalid=await pageFor({configStatus:'invalid_configuration'});await idle(invalid);
    assert.equal(await invalid.evaluate(()=>window.__calls.some(c=>c[0]==='check')),false);
    const legacy=await pageFor({legacy:true});await legacy.locator('#pHostUpdates').click();
    assert.deepEqual(await legacy.evaluate(()=>window.__calls),[]);
    assert.equal(await legacy.locator('#hostUpdatesCheck').isDisabled(),true);
    const demo=await pageFor({},'?demo=1');await demo.locator('#pHostUpdates').click();
    assert.deepEqual(await demo.evaluate(()=>window.__calls),[]);
    assert.match(await demo.locator('#hostUpdatesStateLabel').textContent(),/演示/);
    assert.equal(await demo.locator('#hostUpdatesDownload').isVisible(),false);
    const delayed=await pageFor({delay:1500});
    await delayed.locator('#pHostUpdates').click();
    assert.equal(await delayed.locator('#hostUpdatesStatus').getAttribute('data-state'),'checking');
    await delayed.keyboard.press('Escape');
    await delayed.locator('#hostUpdateNotice').waitFor({state:'visible'});
    assert.equal(await delayed.locator('#hostUpdatesShade').isVisible(),false,'completion reopened closed drawer');
    await delayed.locator('#pHostUpdates').click();
    assert.equal(await delayed.locator('#hostUpdatesStatus').getAttribute('data-state'),'available');
    assert.equal(await delayed.evaluate(()=>window.__calls.filter(c=>c[0]==='check').length),1);
    assert.deepEqual(errors,[]);
    console.log('PASS: host release/config states, automatic passive notice, legacy/demo no calls, same-repo links, no executable metadata, checksum wording, pending close/reopen, modal exclusion, keyboard/focus and 420/760 width; 0 page errors.');
  }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exit(1);});
