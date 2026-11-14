function test_awg_remote_app(outputDir,pythonExe)
% MATLAB -> remote service -> loopback FPGA emulator; no physical hardware.
root=fileparts(fileparts(mfilename('fullpath'))); addpath(fullfile(root,'matlab'));
if nargin<1, outputDir=fullfile(fileparts(root),'过程文件','远程服务联调'); end
if nargin<2, pythonExe=AWGScopeApp.findTool('python'); end
if ~isfolder(outputDir), mkdir(outputDir); end
temp=tempname(outputDir); mkdir(temp);
ready=fullfile(temp,'ready.json'); stop=fullfile(temp,'stop');
process=AWGBridge.launch(pythonExe,{'-X','utf8',fullfile(root,'sim','remote_gui_test_emulator.py'),ready,stop},fullfile(temp,'emulator.log'),root);
cleanup=onCleanup(@() finish(process,stop)); %#ok<NASGU>
t=tic; while ~isfile(ready) && toc(t)<15, pause(.05); end
assert(isfile(ready),'Remote emulator did not start.'); cfg=jsondecode(fileread(ready));
app=AWGScopeApp('off',fullfile(temp,'data')); closer=onCleanup(@() delete(app)); %#ok<NASGU>
app.ShowAlerts=false; app.UI.cfg_python.Value=pythonExe; app.UI.cfg_transport.Value='remote';
app.UI.cfg_remote_host.Value='127.0.0.1'; app.UI.cfg_remote_port.Value=cfg.port;
app.setWave(.25*cos((0:95)'*2*pi/32),9.8e9,'normalized','remote test',1);
app.UI.readLength.Value=24; app.UI.trigger.Value='start';
app.connect; waitIdle(app,30); assert(app.Connected);
app.send('run'); waitIdle(app,60);
assert(~app.Connected && app.Captured && isfile(app.LastCapture));
assert(isfile(strrep(app.LastCapture,'.csv','.mat')) && size(app.Rx.iq,1)==24);
app.connect; waitIdle(app,30); assert(app.Connected && strcmp(app.Status.running,'1'));
try
    app.send('load'); error('expected:missing','Expected playback guard.');
catch e
    assert(contains(e.message,'手动停止'));
end
app.send('stop'); waitIdle(app,20); app.send('load'); waitIdle(app,30);
app.send('start'); waitIdle(app,20); assert(~app.Connected);
app.connect; waitIdle(app,30); assert(strcmp(app.Status.running,'1'));
app.send('disconnect'); waitIdle(app,20); assert(~app.Connected);
fprintf('PASS remote GUI loopback: run, local capture, lock release, playback and manual stop guard\n');
end

function waitIdle(app,limit)
t=tic; while app.Busy && toc(t)<limit, drawnow; pause(.05); end
assert(~app.Busy && isempty(app.LastError),'Task failed: %s',app.LastError);
end

function finish(process,stop)
f=fopen(stop,'w'); if f>=0, fclose(f); end
pause(.6); AWGBridge.killProcess(process);
end
