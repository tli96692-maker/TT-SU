/* Shared command outcomes for both HtmlDialogs. Never record tool activation. */
(function(global){
  'use strict';
  function create(options){
    var memory=[],storage=options.storage,key=options.key||'suhub.command-completions';
    function read(){
      try{var value=JSON.parse(storage.getItem(key)||'[]');return Array.isArray(value)?value:memory;}catch(_){return memory;}
    }
    function mark(id){
      if(!id)return true;
      var ids=read();if(ids.indexOf(id)>=0)return false;
      ids.push(id);memory=ids.slice(-200);
      try{storage.setItem(key,JSON.stringify(memory));}catch(_){}
      return true;
    }
    function handle(raw,flags){
      flags=flags||{};
      if(!raw||typeof raw!=='object')throw new Error('宿主返回无效命令结果');
      var status=raw.status||(raw.ok===true?'completed':'failed');
      if(['completed','started','cancelled','failed','unavailable'].indexOf(status)<0)throw new Error('宿主返回未知命令状态');
      var result=Object.assign({},raw,{status:status,commandId:raw.commandId||flags.commandId});
      if(status==='completed'&&result.commandId&&mark(result.invocationId)){
        options.recordRecent(result.commandId,result.recordedAt);
      }
      if(flags.notify&&result.message)options.notify(result.message);
      return result;
    }
    function reconcile(results){
      (Array.isArray(results)?results:[]).forEach(function(result){
        // Untyped legacy responses have no stable invocation ID for replay.
        if(!result||!result.invocationId)return;
        try{handle(result);}catch(_){}
      });
    }
    return {handle:handle,reconcile:reconcile};
  }
  global.SUHubCommandOutcomes={create:create};
})(typeof window==='undefined'?globalThis:window);
