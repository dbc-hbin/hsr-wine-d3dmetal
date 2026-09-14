/*
 * Minimal executable fixture for the official Yaagl HSR launch structure.
 * The HSR launch environment follows src/clients/mhy/hkrpg/program-launch-game.ts;
 * Wine construction, installation, catalog, and updater shapes are retained from
 * the upstream 0.3.18 resource bundle used by the registration lifecycle tests.
 */

async function Ht(e,t){return await $e(["mv","-f",`${Y(e)}`,`${Y(t)}`])}

async function oc(e){const t=await E4();async function n(h,f){return await r("cmd",[h,...f])}async function r(h,f,C,_=void 0){return await $e(h=="copy"?[t,"cmd","/c",h,...f]:[t,h,...f],{...a(),...C!=null?C:{}},!1,_)}async function o(h,f,C,_=void 0){return await Fr(h=="copy"?[t,"cmd","/c",h,...f]:[t,h,...f],{...a(),...C!=null?C:{}},!1,_)}async function u(){return await Fr([H.join(H.dirname(t),"wineserver"),"-w"],{...a()})}function i(h){return"Z:"+`${h}`.replaceAll("/","\\")}function a(){return{WINEDEBUG:"fixme-all,err-unwind,+timestamp",WINEPREFIX:e.prefix}}async function s({gameDir:h}){return await Fr(["osascript","-e",["tell","app",'"Terminal"',"to","do","script",`"${hr([t,"cmd"],{...a(),WINEPATH:i(h)}).replaceAll("\\","\\\\").replaceAll('"','\\"')}"`].join(" "),"-e",["tell","app",'"Terminal"',"to","activate"].join(" ")],{},!1,"/dev/null")}let c;try{c=await Le("wine_netbiosname")}catch{c=`DESKTOP-${Vl(7)}`,await ge("wine_netbiosname",c)}async function l(h){const f=`@echo off
cd "%~dp0"
reg add "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver" /v RetinaMode /t REG_SZ /d ${h.retina?"y":"n"} /f
reg add "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver" /v LeftCommandIsCtrl /t REG_SZ /d ${h.leftCmd?"y":"n"} /f
`;await Ut(Y("winedrv_config.bat"),f),await r("cmd",["/c",`${i(Y("./winedrv_config.bat"))}`],{},"/dev/null"),await u()}async function d(){const h=`@echo off
cd "%~dp0"
reg add "HKEY_LOCAL_MACHINE\\SOFTWARE\\NVIDIA Corporation\\Global" /v "{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}" /t REG_BINARY /d 1 /f
reg add "HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet001\\Services\\nvlddmkm" /v "{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}" /t REG_BINARY /d 1 /f
reg add "HKEY_LOCAL_MACHINE\\SOFTWARE\\NVIDIA Corporation\\Global\\NGXCore" /v FullPath /t REG_SZ /d "C:\\Windows\\System32" /f
`;await Ut(Y("winedrv_config.bat"),h),await r("cmd",["/c",`${i(Y("./winedrv_config.bat"))}`],{},"/dev/null"),await u()}return{exec:r,exec2:o,waitUntilServerOff:u,cmd:n,toWinePath:i,prefix:e.prefix,openCmdWindow:s,setProps:l,setNVExtension:d,attributes:{...e.distro.attributes}}}

const Nd=["d3d11.dll","dxgi.dll"];
async function*x_(e,t,n,r){if(await En("patched","NOTFOUND")!=="NOTFOUND")return;const o=H.join(t.prefix,"drive_c","windows","system32"),u=H.join(t.prefix,"drive_c","windows","syswow64");for(const i of Nd){await Xt(H.join(o,i),H.join(o,i+".bak"));await fl("dxmt/"+i,H.join(o,i));await Xt(H.join(u,i),H.join(u,i+".bak"));await fl("dxmt/"+i,H.join(u,i))}await fl("./dxmt/winemetal.dll",H.join(o,"winemetal.dll")),await fl("./dxmt/winemetal.so",H.join(t.prefix,"winemetal.so")),n.id.startsWith("hkrpg")&&(await fl("./dxmt/nvngx.dll",H.join(o,"nvngx.dll")));me("patched","1")}
async function*Id(e,t,n,r){const o=H.join(t.prefix,"drive_c","windows","system32"),u=H.join(t.prefix,"drive_c","windows","syswow64");for(const i of Nd){await Xt(H.join(o,i+".bak"),H.join(o,i));await Xt(H.join(u,i+".bak"),H.join(u,i))}await ke("patched")}

async function*V_({gameDir:e,gameExecutable:t,wine:n,config:r,server:o}){yield["setUndeterminedProgress"],yield["setStateText","PATCHING"],await z_(n,o),await n.setProps(r);const u=[];r.resolutionCustom&&(u.push("-screen-width",r.resolutionWidth),u.push("-screen-height",r.resolutionHeight),u.push("-screen-fullscreen","0"));yield["setStateText","GAME_RUNNING"];await n.exec2("cmd",["/c",n.toWinePath(Y("./config.bat"))],{WINEDLLOVERRIDES:"",...n.attributes.renderBackend=="dxmt"?{WINEMSYNC:"1",DXMT_LOG_PATH:Y("./"),DXMT_CONFIG_FILE:H.join(Y("./"),"dxmt.conf"),GST_PLUGIN_FEATURE_RANK:"atdec:MAX,avdec_h264:MAX"}:{WINEESYNC:"1"}});await n.waitUntilServerOff()}

async function CS({aria2:e,wineAbsPrefix:t,wineDistro:n,locale:r}){async function*o(){const u=Y("./wine");await Gr(t),yield["setStateText","DOWNLOADING_ENVIRONMENT"];const i=n.remoteUrl.endsWith(".xz"),a=Y("./wine.tar."+(i?"xz":"gz"));for await(const l of e.doStreamingDownload({uri:n.remoteUrl,absDst:a}))yield["setProgress",Number(l.completedLength*BigInt(100)/l.totalLength)],yield["setStateText","DOWNLOADING_ENVIRONMENT_SPEED",`${ot(Number(l.downloadSpeed))}`];yield["setStateText","EXTRACT_ENVIRONMENT"],yield["setUndeterminedProgress"],await Gr(u),await $e(["mkdir","-p",u]),n.attributes.winePath?await kl(Y("./wine.tar."+(i?"xz":"gz")),u,n.attributes.winePath,i):await Tf(Y("./wine.tar."+(i?"xz":"gz")),u),await ct(a),yield["setStateText","CONFIGURING_ENVIRONMENT"],await mS(u),await Gf("com.apple.quarantine",u),yield["setStateText","CONFIGURING_ENVIRONMENT"],yield["setUndeterminedProgress"],await dS(P_);const s=await oc({prefix:t,distro:n});await s.exec("wineboot",["-u"],{},"/dev/null"),await s.exec("winecfg",["-v","win10"],{},"/dev/null"),(String("napos").startsWith("bh3")||String("napos").startsWith("cbjq"))&&(yield*pS(e,s)),await ge("wine_state","ready"),await ge("wine_tag",n.id),await ge("wine_update_url",null),await ge("wine_update_tag",null);const c=`DESKTOP-${Vl(7)}`;await ge("wine_netbiosname",c),yield["setStateText","INSTALL_DONE"]}return Fd(r,o)}

const _S=[{"id":"9.0-crossover-hsr","displayName":"CrossOver 24 HSR","remoteUrl":"file:///safe/wine-9.0-crossover-hsr.tar.xz","attributes":{"renderBackend":"dxmt","winePath":"wine"}},{"id":"11.17-p3-safe-msync","displayName":"Wine 11.17 P3 safe msync","remoteUrl":"file:///safe/wine-11.17-p3-safe-msync.tar.xz","attributes":{"renderBackend":"d3dmetal","winePath":"wine"}},{"id":"11.17-zzz-dx12-tuned-stage-parallel-gptk4b2-arm64server","displayName":"Wine 11.17 ZZZ DX12 tuned stage parallel (GPTK 4.0b2)","remoteUrl":"file:///safe/wine-11.17-zzz-dx12-tuned-stage-parallel-gptk4b2-arm64server.tar.xz","attributes":{"renderBackend":"d3dmetal","winePath":"wine"}}];

async function fixtureUpdater(){await Ht("./resources.neu.update","./resources.neu")}
