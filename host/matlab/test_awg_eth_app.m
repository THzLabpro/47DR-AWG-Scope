function test_awg_eth_app(outputDir,pythonExe)
% Native MATLAB GUI -> persistent Python IPC -> UDP loopback emulator.
% This test never invokes XSCT/Vivado, JTAG, UART, or a physical IP address.
root=fileparts(fileparts(mfilename('fullpath'))); addpath(fullfile(root,'matlab'));
if nargin<1, outputDir=fullfile(fileparts(root),'过程文件','MATLAB接入40GbE'); end
if nargin<2, pythonExe=AWGScopeApp.findTool('python'); end
if ~isfolder(outputDir), mkdir(outputDir); end
testData=tempname(outputDir); mkdir(testData);
box=containers.Map('KeyType','char','ValueType','any');
cleanup=onCleanup(@() restoreState(box)); %#ok<NASGU>
assert(isfile(pythonExe),'Python is required.');
emuDir=tempname(outputDir); mkdir(emuDir);
ready=fullfile(emuDir,'ready.json'); stopFile=fullfile(emuDir,'stop');
fixture=fullfile(root,'sim','gui_test_emulator.py');
emu=AWGBridge.launch(pythonExe,{'-X','utf8',fixture,ready,stopFile},fullfile(emuDir,'emulator.log'),root);
box('emu')=emu;
started=tic;
while ~isfile(ready) && toc(started)<10, pause(.05); end
assert(isfile(ready),'Emulator startup failed.');
endpoint=jsondecode(fileread(ready));
app=AWGScopeApp('off',testData); app.ShowAlerts=false; box('app')=app;
app.UI.cfg_python.Value=pythonExe;
app.UI.cfg_xsct.Value=fullfile(emuDir,'MUST_NOT_LAUNCH_XSCT.bat');
app.UI.cfg_fpga_ip.Value='127.0.0.1'; app.UI.cfg_port.Value=endpoint.port;
app.UI.cfg_words_per_packet.Value=256;
assert(isempty(app.InitProcess) && isempty(app.Bridge.Process) && ~app.Connected);
assert(app.UI.fs.Value==9800 && app.UI.readLength.Value==65520 && app.UI.verify.Value);
fprintf('PASS construction: 9.8 GS/s, no hardware process or network connection\n');

% Export the exact 14-bit DAC representation, including both saturation edges.
samples=repmat([-1;1;0;.5],8,1);
exported=awg_export_real(samples,fullfile(emuDir,'quantization'),1);
assert(isequal(exported.samples(1:4,1),int16([-32768;32764;0;16384])));
assert(all(mod(double(exported.samples(:)),4)==0));
assert(contains(fileread(fullfile(emuDir,'quantization','waveform.meta')),'fs_hz 9800000000'));
fprintf('PASS export: 14-bit left alignment and 9.8 GS/s metadata\n');

% Input checks and maximum TX record; columns map to the selected physical lanes.
app.UI.normalize.Value=false;
expectError(@() app.setWave(zeros(33,1),9.8e9,'normalized','bad length',1));
expectError(@() app.setWave(zeros(32,1),9e9,'normalized','old rate',1));
expectError(@() app.setWave(zeros(131104,1),9.8e9,'normalized','oversize',1));
wave=[.25*cos((0:131071)'*2*pi/32),.125*sin((0:131071)'*2*pi/32)];
app.setWave(wave,9.8e9,'normalized','CH2 + CH7 maximum record',132);
assert(isequal(size(app.Tx.iq),[131072 8]) && app.Tx.channelMask==132);
assert(isequal(app.Tx.iq(:,3),wave(:,1)) && isequal(app.Tx.iq(:,8),wave(:,2)));
assert(all(app.Tx.iq(:,[1 2 4 5 6 7])==0,'all'));
fprintf('PASS input checks and 131072-point noncontiguous channel mapping\n');

app.connect; waitIdle(app,20);
assert(startsWith(app.Bridge.Session,[testData filesep]) && strcmp(app.DataRoot,testData));
assert(app.Connected && strcmp(app.Status.ps_ready,'1') && isempty(app.InitProcess));
assert(contains(app.UI.state.Text,'RF 就绪') && contains(app.UI.target.Text,'127.0.0.1'));
app.send('status'); waitIdle(app,10);
app.send('load'); waitIdle(app,60);
assert(app.Uploaded && strcmp(app.Status.length_beats,'4096') && strcmp(app.Status.channel_mask,'132'));
p=AWGBridge.readFields(fullfile(app.Bridge.Session,'progress.txt'));
assert(strcmp(p.phase,'verify') && strcmp(p.channel,'7') && strcmp(p.done,'131072'));
assert(strcmp(p.request,sprintf('%08d',app.Bridge.Counter)));
fprintf('PASS connect/status/maximum TX load/CRC and request-tagged CH7 progress\n');

app.send('start'); waitIdle(app,10); assert(strcmp(app.Status.running,'1'));
app.UI.trigger.Value='manual'; app.UI.readLength.Value=24;
app.send('capture'); waitIdle(app,30);
assert(app.Captured && app.Uploaded && isequal(size(app.Rx.iq),[24 8]));
expected=double(int16(max(-8192,min(8191,round(wave(1:24,:)*8192)))*4));
assert(isequal(app.Rx.iq(:,[3 8]),expected));
assert(all(isnan(app.Rx.iq(:,[1 2 4 5 6 7])),'all'));
assert(app.Rx.Fs==5e9 && app.Rx.channelMask==132 && strcmp(app.Rx.metadata.format,'47dr-raw-adc-v2'));
savedMat=strrep(app.LastCapture,'.csv','.mat'); assert(isfile(savedMat));
app.loadCapture(savedMat); assert(isequal(app.Rx.iq(:,[3 8]),expected));
bad=load(savedMat); bad.metadata.samples=48;
badMat=fullfile(emuDir,'invalid_count.mat'); save(badMat,'-struct','bad');
expectError(@() app.loadCapture(badMat));
fprintf('PASS 24-point manual capture, CSV/MAT reload and metadata rejection\n');

% Actual complete 8-channel maximum capture request, rather than truncated readback.
for k=1:8
    app.UI.adcButtons{k}.Value=true;
    feval(app.UI.adcButtons{k}.ValueChangedFcn,[],[]);
end
app.UI.trigger.Value='start'; app.UI.readLength.Value=65520;
app.send('capture'); waitIdle(app,60);
assert(isequal(size(app.Rx.iq),[65520 8]) && app.Rx.metadata.samples==65520 && app.Rx.channelMask==255);
assert(strcmp(app.Status.running,'1') && app.Captured);
% Label the known loopback fixture before rendering; never alter hardware data.
csvPath=app.LastCapture; metaPath=strrep(csvPath,'.csv','.json');
meta=jsondecode(fileread(metaPath)); meta.synthetic=true; meta.source='loopback-emulator';
AWGScopeApp.writeText(metaPath,jsonencode(meta),2,.1);
app.loadCapture(csvPath);
app.UI.channel.Value='7'; app.render; drawnow;
assert(contains(app.UI.facts.Text,'模拟数据'));
assert(app.UI.facts.Layout.Row==6 && app.UI.time.Layout.Row==2 && app.UI.spectrum.Layout.Row==3);
app.Figure.Visible='on'; drawnow;
exportapp(app.Figure,fullfile(outputDir,'matlab_40gbe_capture.png'));
app.Figure.Visible='off';
fprintf('PASS 8 x 65520-point start-trigger capture and native GUI rendering\n');

% CRC disabled reaches the actual production bridge, then one-click run is exercised.
wave=wave(1:96,:); app.setWave(wave,9.8e9,'normalized','short record',132);
app.UI.verify.Value=false; feval(app.UI.verify.ValueChangedFcn,[],[]);
app.send('load'); waitIdle(app,20);
p=AWGBridge.readFields(fullfile(app.Bridge.Session,'progress.txt'));
assert(app.Uploaded && strcmp(p.phase,'write') && strcmp(p.channel,'7'));
app.UI.readLength.Value=48; app.UI.trigger.Value='manual';
app.send('run'); waitIdle(app,30);
assert(app.Uploaded && app.Captured && size(app.Rx.iq,1)==48 && app.Rx.channelMask==132);
app.send('stop'); waitIdle(app,10); assert(strcmp(app.Status.running,'0'));
app.send('clear'); waitIdle(app,10);
requests=app.Bridge.Counter;
app.captureOnly; waitIdle(app,30);
assert(app.Bridge.Counter==requests+2 && strcmp(app.Status.running,'1'));
fprintf('PASS optional CRC, run, stop, clear and capture-only playback chain\n');

% Error propagation must release busy and invalidate Uploaded, then allow recovery.
app.Bridge.send('invalid_test_action');
started=tic;
while isempty(app.LastError) && toc(started)<15, drawnow; pause(.05); end
assert(contains(app.LastError,'Unsupported application action') && ~app.Uploaded && ~app.Busy && app.Connected);
app.send('status'); waitIdle(app,10); assert(isempty(app.LastError));
app.send('disconnect'); waitIdle(app,10);
assert(~app.Connected && isempty(app.Bridge.Process) && isempty(app.InitProcess));
fprintf('PASS backend error propagation, busy release, recovery and disconnect\n');

% Wrong firmware and PS-not-ready paths use separate loopback-only fixtures.
for scenario={'wrong_build','not_ready'}
    extraDir=tempname(outputDir); mkdir(extraDir);
    extraReady=fullfile(extraDir,'ready.json'); extraStop=fullfile(extraDir,'stop');
    extraArgs={};
    if strcmp(scenario{1},'wrong_build'), extraArgs={'--build-id','1'};
    else, extraArgs={'--not-ready'}; end
    extra=AWGBridge.launch(pythonExe,[{'-X','utf8',fixture,extraReady,extraStop} extraArgs],fullfile(extraDir,'emulator.log'),root);
    box(scenario{1})=extra;
    started=tic; while ~isfile(extraReady) && toc(started)<10, pause(.05); end
    assert(isfile(extraReady)); cfg=jsondecode(fileread(extraReady));
    app.UI.cfg_port.Value=cfg.port; app.connect;
    if strcmp(scenario{1},'wrong_build')
        started=tic; while app.Busy && toc(started)<15, drawnow; pause(.05); end
        assert(~app.Connected && ~app.Busy && contains(app.LastError,'firmware mismatch'));
    else
        waitIdle(app,15); assert(app.Connected && strcmp(app.Status.ps_ready,'0'));
        assert(strcmp(app.UI.download.Enable,'off') && strcmp(app.UI.capture.Enable,'off'));
        app.send('disconnect'); waitIdle(app,10);
    end
    AWGBridge.killProcess(extra); remove(box,scenario{1});
end
assert(isempty(app.InitProcess));
fprintf('PASS incompatible firmware rejection and RF-not-ready controls\n');
fprintf('PASS ALL: native MATLAB GUI and real Python UDP bridge; LOOPBACK EMULATOR ONLY, NO HARDWARE VALIDATION\n');
end

function waitIdle(app,seconds)
started=tic;
while app.Busy && toc(started)<seconds, drawnow; pause(.05); end
assert(~app.Busy,'Application operation timed out.');
assert(isempty(app.LastError),'%s',app.LastError);
end
function expectError(callback)
failed=false; try, callback(); catch, failed=true; end
assert(failed,'Invalid parameter was accepted.');
end
function restoreState(box)
if isKey(box,'app'), delete(box('app')); remove(box,'app'); end
keys=box.keys;
for k=1:numel(keys), AWGBridge.killProcess(box(keys{k})); end
end
