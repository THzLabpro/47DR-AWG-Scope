classdef AWGScopeApp < handle
    % MATLAB desktop AWG/scope. 40GbE operations run in a private Python process.
    properties (SetAccess=private)
        Root
        DataRoot
        Figure
        UI=struct
        Bridge
        Timer
        Raw=[]
        Tx=[]
        Rx=[]
        Connected=false
        Busy=false
        Uploaded=false
        Captured=false
        Status=struct
        LastError=''
        LastHint=''
        LastCapture=''
        InitProcess=[]
        InitLog=''
        UartSocket=[]
        UartInput=[]
        Job=[]
        Timing=struct('server','','ms_per_word',NaN,'connect_s',NaN,'initialize_s',NaN)
    end
    properties
        ShowAlerts=true
        % Backend entry script; empty selects tools/awg_eth/gui_bridge.py.
        % The offline regression points it at the mock entry.
        EntryScript=''
    end
    properties (Access=private)
        Messages={}
        AfterDisconnect=''
        WaitReady=[]
        LastReadyPoll=[]
        Closing=false
        UartBuffer=uint8([])
        Chain=''
        Deferred=''
        HintStep=0
        HintLocal=false
        StatusTime=''
        Marquee=0
        InitFlow=false
        InitStarted=[]
        StageRead=[]
        DisplayWarned=false
    end
    properties (Constant, Access=private)
        Ink=[.12 .20 .28]
        Accent=[.03 .42 .51]
        Muted=[.35 .40 .45]
        Good=[.02 .46 .35]
        Warn=[.67 .37 .06]
        Bad=[.75 .17 .13]
        Track=[.88 .91 .93]
        LampOff=[.80 .83 .86]
        LampGood=[.10 .70 .45]
        LampWarn=[.95 .65 .10]
        LampBad=[.85 .20 .15]
    end
    methods
        function obj=AWGScopeApp(varargin)
            obj.Root=fileparts(fileparts(mfilename('fullpath')));
            obj.DataRoot=fullfile(obj.Root,'app_data');
            if numel(varargin)>=2, obj.DataRoot=varargin{2}; end
            addpath(fullfile(obj.Root,'matlab'));
            if ~isfolder(fullfile(obj.DataRoot,'sessions')), mkdir(fullfile(obj.DataRoot,'sessions')); end
            if ~isfolder(fullfile(obj.DataRoot,'captures')), mkdir(fullfile(obj.DataRoot,'captures')); end
            obj.Bridge=AWGBridge(obj.Root,obj.DataRoot);
            obj.buildUI;
            cfgPath=fullfile(obj.DataRoot,'settings.json');
            if isfile(cfgPath)
                try
                    cfg=jsondecode(fileread(cfgPath)); names=fieldnames(cfg);
                    for k=1:numel(names)
                        if isfield(obj.UI,['cfg_' names{k}]), obj.UI.(['cfg_' names{k}]).Value=cfg.(names{k}); end
                    end
                    if ~isfield(cfg,'uart_host')
                        if strcmp(obj.UI.cfg_mode.Value,'remote')
                            address=obj.UI.cfg_server.Value; colon=find(address==':',1,'last');
                            if ~isempty(colon), address=address(1:colon-1); end
                            obj.UI.cfg_uart_host.Value=address;
                        else
                            obj.UI.cfg_uart_host.Value='localhost';
                        end
                    end
                catch, obj.log('连接设置未能读取，已使用默认值。'); end
            end
            obj.loadTiming;
            obj.Timer=timer('ExecutionMode','fixedSpacing','Period',0.4,'BusyMode','drop', ...
                'TimerFcn',@(~,~) obj.tick,'ErrorFcn',@(~,e) obj.timerError(e));
            start(obj.Timer);
            obj.log('已启动。按上方 ① 到 ⑤ 的顺序操作；板卡已经初始化时从 ② 开始。');
            obj.log('没有板卡时可点“离线接收演示”查看模拟数据，不会连接板卡。');
            obj.updateControls;
            if ~isempty(varargin), obj.Figure.Visible=varargin{1}; else, obj.Figure.Visible='on'; end
        end
        function importWave(obj,path,variable)
            if nargin<3, variable=''; end
            [wave,fs,units,label]=AWGScopeApp.readWave(path,variable);
            obj.setWave(wave,fs,units,label);
        end
        function setWave(obj,wave,fs,units,label,mask)
            if nargin<5, label='MATLAB waveform'; end
            validateattributes(wave,{'numeric'},{'2d','finite','nonempty'});
            if isvector(wave), wave=wave(:); end
            assert(size(wave,2)<=8,'数据列数最多8列，每列一个物理通道。');
            assert(size(wave,1)>=4,'波形至少需要4点。');
            obj.Raw=double(wave); obj.Uploaded=false; obj.Tx=[];
            obj.UI.source.Text=AWGScopeApp.shortLabel(label); obj.UI.source.Tooltip=label;
            obj.UI.fs.Value=fs/1e6; obj.UI.units.Value=units;
            % Preserve the full imported record. Invalid lengths must be
            % reported, rather than silently selecting a shorter prefix.
            obj.UI.count.Limits=[1 max(131072,size(wave,1))];
            obj.UI.first.Value=1; obj.UI.count.Value=size(wave,1);
            if nargin<6
                currentMask=obj.readChannelMask(obj.UI.dacButtons);
                currentCount=sum(bitget(uint8(currentMask),1:8));
                if size(wave,2)>1 && currentCount~=size(wave,2)
                    mask=2^size(wave,2)-1;
                else
                    mask=currentMask;
                end
            end
            obj.syncChannelButtons(mask);
            obj.prepareTx;
            obj.UI.view.Value='tx'; obj.render;
            obj.log(sprintf('已导入 %d 点 × %d 通道；选择 %d 点用于循环播放。', ...
                size(wave,1),size(wave,2),obj.UI.count.Value));
        end
        function demoTx(obj)
            Fs=9.8e9; n=(0:9215)';
            mask=obj.readChannelMask(obj.UI.dacButtons);
            assert(mask~=0,'请至少选择一个DAC通道。');
            wave=0.25*cos(2*pi*100e6/Fs*n);
            obj.setWave(wave,Fs,'normalized', ...
                sprintf('演示发射：%s 实数单音 / 9.8 GS/s',obj.channelNames(mask,'DAC')),mask);
        end
        function demoRx(obj)
            obj.loadCapture(fullfile(obj.Root,'sim','demo','capture.csv'));
        end
        function prepareTx(obj)
            obj.Uploaded=false; obj.Captured=false; obj.Tx=[];
            assert(~isempty(obj.Raw),'请先导入波形。');
            inputFs=obj.UI.fs.Value*1e6;
            assert(isfinite(inputFs) && abs(inputFs-9.8e9)<=1, ...
                '上位机不进行重采样；请先在MATLAB中将波形重采样到9.8 GS/s后再导入。');
            first=obj.UI.first.Value; n=obj.UI.count.Value; mask=obj.readChannelMask(obj.UI.dacButtons);
            validateattributes(first,{'numeric'},{'scalar','integer','positive'});
            validateattributes(n,{'numeric'},{'scalar','integer','>=',4,'<=',131072});
            assert(mask~=0,'请至少选择一个DAC通道。');
            assert(mod(n,32)==0 && first+n-1<=size(obj.Raw,1), ...
                '播放区间点数必须是32的倍数，且不能超出导入数据。');
            assert(isreal(obj.Raw),'当前9.8 GS/s直连DAC模式要求实数波形；复数IQ请先在MATLAB中转换为实数波形。');
            selected=find(bitget(uint8(mask),1:8));
            source=obj.Raw(first:first+n-1,:);
            assert(size(source,2)==1 || size(source,2)==numel(selected), ...
                '波形列数应为1（复制到所有已选DAC）或与已选DAC通道数相同（按按钮顺序对应）。');
            wave=zeros(n,8);
            if size(source,2)==1
                wave(:,selected)=repmat(source,1,numel(selected));
            else
                wave(:,selected)=source;
            end
            if strcmp(obj.UI.units.Value,'codes')
                assert(all(wave(:)>=-32768 & wave(:)<=32767), ...
                    '16 bit码值必须在[-32768,32767]内。');
                wave=wave/32768;
            end
            enabled=logical(bitget(uint8(mask),1:8)); wave(:,~enabled)=0;
            if obj.UI.normalize.Value
                peak=max(abs(wave(:))); if peak>0, wave=wave*(obj.UI.amplitude.Value/peak); end
            end
            assert(all(abs(wave(:))<=1),'实数波形超过[-1,1]，请开启归一化或修正源数据。');
            obj.Tx=struct('iq',wave,'Fs',9.8e9,'ncoHz',0, ...
                'channelMask',mask,'metadata',struct('synthetic',false,'ducEnabled',false, ...
                'sampleFormat','real-int16','inputFs',inputFs,'inputSamples',n, ...
                'outputSamples',n,'centerHz',0));
            obj.UI.selection.Text=sprintf('DAC 9.8 GS/s直接发送 · %d点/通道 · %s', ...
                n,obj.channelNames(mask,'DAC'));
            % A valid waveform replaces the message left by a rejected parameter.
            if obj.HintLocal, obj.clearHint; end
            obj.updateControls;
        end
        function loadCapture(obj,path)
            [~,~,ext]=fileparts(path);
            if strcmpi(ext,'.mat')
                data=load(path);
                if isfield(data,'metadata') && isfield(data.metadata,'format') && ...
                        any(strcmp(data.metadata.format,{'47dr-raw-adc-v1','47dr-raw-adc-v2'}))
                    assert(isfield(data,'iq') && isfield(data,'Fs') && isfield(data,'channelMask'), ...
                        '原始ADC MAT缺少数据、采样率或通道掩码。');
                    validateattributes(data.iq,{'numeric'},{'2d'});
                    validateattributes(data.Fs,{'numeric'},{'scalar','finite','positive'});
                    validateattributes(data.channelMask,{'numeric'},{'scalar','integer','>=',1,'<=',255});
                    assert(size(data.iq,2)==8 && data.Fs==5e9,'原始ADC MAT格式或采样率不匹配。');
                    assert(isfield(data.metadata,'samples') && data.metadata.samples==size(data.iq,1), ...
                        '原始ADC MAT点数与元数据不符。');
                    selected=bitget(uint8(data.channelMask),1:8)>0;
                    assert(all(isfinite(data.iq(:,selected)),'all') && ...
                        all(isnan(data.iq(:,~selected)),'all'),'原始ADC MAT通道内容与掩码不匹配。');
                    obj.Rx=data;
                    obj.LastCapture=path; obj.UI.view.Value='rx'; obj.UI.offset.Value=1;
                    obj.render; obj.updateControls; obj.log(['原始ADC数据已载入：' path]);
                    return
                end
                assert(isfield(data,'iq') && isfield(data,'Fs') && isfield(data,'status') && isfield(data,'beatCounter'), ...
                    '请选择awg_import_ila/上位机保存的接收MAT。');
                % Recheck continuity and status when loading an existing MAT.
                assert(isfield(data,'channelMask') && isfield(data,'ncoHz'),'接收MAT缺少通道/频率信息。');
                validateattributes(data.channelMask,{'numeric'},{'scalar','integer','>=',1,'<=',255});
                assert(size(data.iq,2)==8 && size(data.iq,1)==4*numel(data.status),'接收MAT长度错误。');
                assert(numel(data.status)>=2 && numel(data.beatCounter)==numel(data.status),'接收MAT状态长度错误。');
                assert(all(mod(diff(double(data.beatCounter)),2^32)==1),'接收MAT拍计数不连续。');
                assert(isa(data.status,'uint64'),'接收状态须为uint64。');
                valid=uint64(0);
                for ch=1:8, if bitget(uint8(data.channelMask),ch), valid=bitor(valid,bitshift(uint64(3),2*(ch-1))); end, end
                assert(all(bitand(data.status,valid)==valid) && all(bitget(data.status,43)) && ...
                    all(bitand(bitshift(data.status,-32),uint64(255))==0),'接收MAT包含无效采集状态。');
                validateattributes(data.iq,{'double'},{'finite','2d'});
                validateattributes(data.Fs,{'numeric'},{'scalar','finite','positive'});
                validateattributes(data.ncoHz,{'numeric'},{'scalar','finite'});
                if isfield(data,'metadata') && isfield(data.metadata,'capture_beats')
                    assert(numel(data.status)==data.metadata.capture_beats,'接收MAT为不完整捕获。');
                end
                if ~isfield(data,'metadata'), data.metadata=struct; end
                obj.Rx=data;
            else
                sidecar=[path(1:end-4) '.json'];
                if isfile(sidecar)
                    meta=jsondecode(fileread(sidecar));
                else
                    meta=struct;
                end
                if isfield(meta,'format') && any(strcmp(meta.format,{'47dr-raw-adc-v1','47dr-raw-adc-v2'}))
                    raw=readmatrix(path); mask=double(meta.channel_mask);
                    validateattributes(raw,{'numeric'},{'2d','finite'});
                    validateattributes(meta.samples,{'numeric'},{'scalar','integer','positive'});
                    validateattributes(mask,{'numeric'},{'scalar','integer','>=',1,'<=',255});
                    ch=find(bitget(uint8(mask),1:8));
                    assert(size(raw,1)==meta.samples && size(raw,2)==numel(ch) && meta.fs_hz==5e9, ...
                        '原始ADC CSV行数、列数或采样率与元数据不符。');
                    iq=nan(size(raw,1),8); iq(:,ch)=raw;
                    obj.Rx=struct('iq',iq,'Fs',double(meta.fs_hz),'ncoHz',0, ...
                        'channelMask',mask,'metadata',meta);
                else
                    obj.Rx=awg_import_ila(path);
                end
            end
            obj.LastCapture=path; obj.UI.view.Value='rx'; obj.UI.offset.Value=1;
            obj.render; obj.updateControls;
            obj.log(['接收数据已载入：' path]);
        end
        function saveCapture(obj,path)
            assert(~isempty(obj.Rx),'尚无接收数据。');
            rx=obj.Rx; save(path,'-struct','rx','-v7');
            obj.log(['已保存接收MAT：' path]);
        end
        function connect(obj,entryScript)
            assert(~obj.Busy && ~obj.Connected,'当前正在执行任务或已经连接。');
            obj.LastError=''; obj.clearHint;
            cfg=obj.settings;
            if nargin<2, entryScript=obj.EntryScript; end
            obj.Busy=true; obj.beginJob('connect'); obj.updateControls;
            if strcmp(cfg.transport,'remote') && isempty(entryScript)
                entryScript=fullfile(obj.Root,'tools','awg_eth','remote_gui_bridge.py');
                obj.log(sprintf('连接实验室远程服务：%s:%d…',cfg.remote_host,cfg.remote_port));
            else
                obj.log(sprintf('连接 40GbE：%s:%d，核对 D3C / ABI 与采样率…',cfg.fpga_ip,cfg.port));
            end
            if isempty(entryScript), obj.Bridge.start(cfg); else, obj.Bridge.start(cfg,entryScript); end
        end
        function connectUART(obj)
            assert(isempty(obj.UartSocket),'UART日志已经连接。');
            host=strtrim(obj.UI.cfg_uart_host.Value);
            port=obj.UI.cfg_uart_port.Value;
            validateattributes(port,{'numeric'},{'scalar','integer','>=',1,'<=',65535});
            socket=java.net.Socket;
            socket.connect(java.net.InetSocketAddress(host,int32(port)),int32(3000));
            socket.setTcpNoDelay(true);
            obj.UartSocket=socket; obj.UartInput=socket.getInputStream(); obj.UartBuffer=uint8([]);
            obj.log(sprintf('UART日志TCP已连接：%s:%d（只读）',host,port));
            obj.updateControls;
        end
        function disconnectUART(obj)
            obj.closeUART;
            obj.log('UART日志TCP已断开。'); obj.updateControls;
        end
        function consumeUARTBytes(obj,bytes)
            bytes=uint8(bytes(:).');
            if isempty(bytes), return; end
            obj.UartBuffer=[obj.UartBuffer bytes];
            newlinePositions=find(obj.UartBuffer==10);
            if isempty(newlinePositions)
                if numel(obj.UartBuffer)>16384
                    obj.UartBuffer=obj.UartBuffer(end-4095:end);
                    obj.log('UART单行超过16 KiB，已截断前部内容。');
                end
                return
            end
            last=0;
            for k=1:numel(newlinePositions)
                stopAt=newlinePositions(k)-1;
                line=obj.UartBuffer(last+1:stopAt);
                if ~isempty(line) && line(end)==13, line(end)=[]; end
                if ~isempty(line), obj.log(['PS UART  ' native2unicode(line,'UTF-8')]); end
                last=newlinePositions(k);
            end
            obj.UartBuffer=obj.UartBuffer(last+1:end);
        end
        function initialize(obj)
            if obj.backgroundPoll, obj.Deferred='initialize'; return; end
            assert(~obj.Busy,'请等待当前任务结束。');
            obj.LastError=''; obj.clearHint;
            if obj.Connected
                obj.AfterDisconnect='initialize'; obj.send('disconnect'); return;
            end
            cfg=obj.settings;
            assert(isfile(cfg.xsct),'XSCT路径无效，请在连接设置中修改。');
            package=fullfile(obj.Root,'hardware','eth40g_v1_2');
            for name={'rf_awg_scope_v1.bit','rf_awg_init.elf','psu_init.tcl','init_protocol.txt','program.tcl'}
                assert(isfile(fullfile(package,name{1})),'40GbE D3C/F1 硬件包缺少 %s。',name{1});
            end
            obj.InitLog=fullfile(obj.DataRoot,['initialize_' datestr(now,'yyyymmdd_HHMMSS') '.log']);
            initArgs={fullfile(package,'program.tcl'),'-server',cfg.server,'-package',package};
            obj.InitProcess=AWGBridge.launch(cfg.xsct,initArgs,obj.InitLog,obj.Root);
            obj.InitFlow=true; obj.InitStarted=tic;
            obj.Busy=true; obj.beginJob('initialize'); obj.updateControls;
            obj.log(['正在通过 JTAG 烧写匹配的 D3C/F1 并初始化，完成后自动连接 40GbE。HW server=' cfg.server]);
        end
        function send(obj,action)
            if obj.backgroundPoll
                % A ready poll is in flight after initialization: run the
                % request as soon as that poll returns.
                if ~strcmp(action,'status'), obj.Deferred=action; end
                return
            end
            assert(obj.Connected && ~obj.Busy,'请先连接板卡并等待当前任务结束。');
            % The ready poll that follows initialization is not a user task.
            background=strcmp(action,'status') && ~isempty(obj.WaitReady);
            obj.LastError=''; if ~background, obj.clearHint; end
            fields=struct; plan=struct;
            if any(strcmp(action,{'load','run'}))
                if strcmp(obj.UI.cfg_transport.Value,'remote') && isfield(obj.Status,'running') && strcmp(obj.Status.running,'1')
                    error('板卡正在播放，请先手动停止播放，再下载新波形。');
                end
                obj.prepareTx;
                folder=fullfile(obj.DataRoot,'waveforms',char(java.util.UUID.randomUUID));
                awg_export_real(obj.Tx.iq,folder,obj.Tx.channelMask);
                fields.directory=folder; fields.verify=double(obj.UI.verify.Value);
                plan.loadChannels=find(bitget(uint8(obj.Tx.channelMask),1:8))-1;
                plan.loadWords=size(obj.Tx.iq,1)/2; plan.verify=logical(obj.UI.verify.Value);
                mode='每路 CRC 校验'; if ~plan.verify, mode='不校验（仅调试使用）'; end
                obj.log(['下载文件：' folder '（' mode '）']);
            end
            if any(strcmp(action,{'capture','run'}))
                rxMask=obj.readChannelMask(obj.UI.adcButtons);
                assert(rxMask~=0,'请至少选择一个ADC通道。');
                samples=AWGScopeApp.roundReadLength(obj.UI.readLength.Value);
                obj.UI.readLength.Value=samples;
                fields.capture=fullfile(obj.DataRoot,'captures',[char(java.util.UUID.randomUUID) '.csv']);
                fields.mask=rxMask; fields.trigger=obj.UI.trigger.Value; fields.samples=samples;
                plan.captureMask=rxMask; plan.captureChannels=sum(bitget(uint8(rxMask),1:8)); plan.captureSamples=samples;
            end
            if strcmp(action,'start')
                assert(obj.Uploaded,'请先下载当前波形。');
                if ~isempty(obj.Chain), fields.hold='1'; end
            end
            obj.Bridge.send(action,fields); obj.Busy=true;
            if ~background
                obj.beginJob(action,plan);
                if strcmp(obj.UI.cfg_transport.Value,'remote'), obj.Job.totalWords=0; end
                obj.log(['执行：' obj.Job.label]);
            end
            obj.updateControls;
        end
        function requestInitialize(obj)
            % Button entry: initialization resets the board, so ask first.
            if obj.ShowAlerts
                message='初始化会复位板卡并重新下载 bit，正在播放的波形会停止。';
                if isfinite(obj.Timing.initialize_s) && strcmp(obj.Timing.server,obj.endpoint)
                    message=[message '上次用时 ' AWGScopeApp.timeText(obj.Timing.initialize_s) '。'];
                end
                answer=uiconfirm(obj.Figure,message,'初始化板卡','Options',{'初始化','取消'}, ...
                    'DefaultOption',2,'CancelOption',2,'Icon','warning');
                if ~strcmp(answer,'初始化'), return; end
            end
            obj.initialize;
        end
        function requestTransfer(obj,action)
            % Button entry for download / one-click run. When the board already
            % holds the current waveform, offer to skip the repeated download.
            if obj.Uploaded && obj.ShowAlerts
                estimate=obj.transferEstimate('load');
                if ~isempty(estimate), estimate=['重新下载预计' estimate '。']; end
                if strcmp(action,'run')
                    answer=uiconfirm(obj.Figure,['当前波形已经在板上，可以只采集。' estimate],'一键下载并采集', ...
                        'Options',{'只采集','重新下载并采集','取消'},'DefaultOption',1,'CancelOption',3);
                    if strcmp(answer,'只采集'), obj.captureOnly; return; end
                    if ~strcmp(answer,'重新下载并采集'), return; end
                else
                    answer=uiconfirm(obj.Figure,['当前波形已经在板上，不需要重新下载。' estimate],'下载', ...
                        'Options',{'重新下载','取消'},'DefaultOption',2,'CancelOption',2);
                    if ~strcmp(answer,'重新下载'), return; end
                end
            end
            obj.send(action);
        end
        function captureOnly(obj)
            % Capture the waveform that is already on the board. With the
            % manual trigger, start playback first when it is stopped.
            % Reject an empty ADC selection here, before playback is started.
            assert(obj.readChannelMask(obj.UI.adcButtons)~=0,'请至少选择一个ADC通道。');
            running=isfield(obj.Status,'running') && strcmp(obj.Status.running,'1');
            if ~running && strcmp(obj.UI.trigger.Value,'manual')
                obj.Chain='capture'; obj.send('start');
            else
                obj.send('capture');
            end
        end
        function render(obj)
            if strcmp(obj.UI.view.Value,'tx'), data=obj.Tx; label='发射预览'; else, data=obj.Rx; label='ADC接收'; end
            if isempty(data)
                cla(obj.UI.time); cla(obj.UI.spectrum); obj.UI.facts.Text='请导入发射波形或接收记录。'; return;
            end
            channels=find(bitget(uint8(data.channelMask),1:8))-1;
            obj.UI.channel.Items=arrayfun(@(v) sprintf('CH%d',v),channels,'UniformOutput',false);
            values=arrayfun(@num2str,channels,'UniformOutput',false);
            previous=obj.UI.channel.Value;
            obj.UI.channel.ItemsData=values;
            if ~ismember(previous,values), obj.UI.channel.Value=values{1}; else, obj.UI.channel.Value=previous; end
            ch=str2double(obj.UI.channel.Value); n=size(data.iq,1);
            obj.UI.offset.Limits=[1 max(2,n-3)];
            first=min(max(1,round(obj.UI.offset.Value)),n-3); obj.UI.offset.Value=first;
            count=min(str2double(obj.UI.span.Value),n-first+1); idx=first:first+count-1;
            z=data.iq(:,ch+1); w=0.5-0.5*cos(2*pi*(0:n-1)'/(n-1));
            f=(-floor(n/2):ceil(n/2)-1)'*data.Fs/n;
            isTx=strcmp(obj.UI.view.Value,'tx');
            scale=32768; if isTx, scale=1; end
            spectrum=20*log10(max(abs(fftshift(fft(z.*w)))/sum(w)/scale,1e-15));
            t=(idx-1)/data.Fs*1e6;
            % Reused axes can retain manual zoom limits from a prior ADC view.
            % Restore autoscaling so normalized TX samples remain visible.
            obj.UI.time.XLimMode='auto'; obj.UI.time.YLimMode='auto';
            obj.UI.spectrum.XLimMode='auto'; obj.UI.spectrum.YLimMode='auto';
            plot(obj.UI.time,t,real(z(idx)),'Color',[0.05 .52 .62],'LineWidth',1);
            if isTx
                legend(obj.UI.time,{'实数 DAC 样点'},'Location','northeast');
                ylabel(obj.UI.time,'归一化 DAC 振幅');
            elseif isfield(data,'metadata') && isfield(data.metadata,'format') && ...
                    any(strcmp(data.metadata.format,{'47dr-raw-adc-v1','47dr-raw-adc-v2'}))
                legend(obj.UI.time,{'ADC原始实数样点'},'Location','northeast');
                ylabel(obj.UI.time,'ADC 原始码值（14 bit 左对齐）');
            else
                hold(obj.UI.time,'on');
                plot(obj.UI.time,t,imag(z(idx)),'Color',[.88 .38 .12],'LineWidth',1);
                plot(obj.UI.time,t,abs(z(idx)),'Color',[.53 .37 .76],'LineWidth',1); hold(obj.UI.time,'off');
                legend(obj.UI.time,{'ADC I','ADC Q','IQ包络'},'Location','northeast','Orientation','horizontal');
                ylabel(obj.UI.time,'16 bit ADC 数字码值');
            end
            xlabel(obj.UI.time,'时间 / μs'); grid(obj.UI.time,'on');
            synthetic=isfield(data,'metadata') && isfield(data.metadata,'synthetic') && data.metadata.synthetic;
            if synthetic, label=[label ' · 模拟数据']; end
            title(obj.UI.time,sprintf('%s · CH%d',label,ch));
            shift=0; axisLabel='复基带频率 / MHz';
            if isTx
                axisLabel='实数 DAC 频率 / MHz';
            elseif ~(isfield(data,'metadata') && isfield(data.metadata,'format') && ...
                    any(strcmp(data.metadata.format,{'47dr-raw-adc-v1','47dr-raw-adc-v2'}))) && obj.UI.rf.Value
                shift=data.ncoHz; axisLabel='估计射频频率 / MHz（方向需实测确认）';
            elseif isfield(data,'metadata') && isfield(data.metadata,'format') && ...
                    any(strcmp(data.metadata.format,{'47dr-raw-adc-v1','47dr-raw-adc-v2'}))
                axisLabel='ADC输入频率 / MHz';
            end
            plot(obj.UI.spectrum,(f+shift)/1e6,spectrum,'Color',[.05 .52 .62],'LineWidth',1);
            grid(obj.UI.spectrum,'on'); xlabel(obj.UI.spectrum,axisLabel);
            if isTx, ylabel(obj.UI.spectrum,'dB / DAC 满量程');
            else, ylabel(obj.UI.spectrum,'dB / ADC 数字满量程'); end
            ylim(obj.UI.spectrum,[-140 5]);
            title(obj.UI.spectrum,'完整记录频谱 · Hann窗 · 双边FFT');
            [~,peak]=max(spectrum);
            fsText=sprintf('%.2f MS/s',data.Fs/1e6);
            if data.Fs>=1e9, fsText=sprintf('%.3f GS/s',data.Fs/1e9); end
            obj.UI.facts.Text=sprintf('%s  |  Fs %s  |  %d点/通道  |  %.3f μs  |  FFT间隔 %.3f kHz  |  峰值 %.6f MHz', ...
                label,fsText,n,n/data.Fs*1e6,data.Fs/n/1e3,f(peak)/1e6);
        end
        function tick(obj)
            if obj.Closing || ~isvalid(obj.Figure), return; end
            try
                obj.pollUART;
                if ~isempty(obj.InitProcess)
                    if ~obj.InitProcess.isAlive
                        code=obj.InitProcess.exitValue; obj.InitProcess=[]; obj.Busy=false;
                        assert(code==0,'初始化进程失败，请检查日志：%s',obj.InitLog);
                        obj.log(['初始化脚本完成：' obj.InitLog]);
                        obj.WaitReady=[]; obj.LastReadyPoll=[]; obj.connect;
                    else
                        obj.refreshProgress;
                    end
                    return
                end
                [ready,response,action]=obj.Bridge.poll;
                if ready
                    obj.Busy=false;
                    obj.applyResponse(response,action);
                end
                if obj.Connected && ~obj.Busy && ~isempty(obj.Deferred)
                    % A request made while the ready poll was in flight.
                    action=obj.Deferred; obj.Deferred='';
                    obj.WaitReady=[]; obj.InitFlow=false; obj.Job=[];
                    if strcmp(action,'initialize'), obj.initialize; else, obj.send(action); end
                elseif obj.Connected && ~obj.Busy && ~isempty(obj.WaitReady)
                    if isfield(obj.Status,'ps_ready') && strcmp(obj.Status.ps_ready,'1')
                        obj.WaitReady=[]; obj.Job=[];
                        obj.log('RF初始化完成，PS ready=1，可以下载和播放。');
                        if obj.InitFlow
                            obj.InitFlow=false; elapsed=toc(obj.InitStarted);
                            obj.recordTiming('initialize_s',elapsed);
                            obj.log(['完成：初始化板卡，用时 ' AWGScopeApp.timeText(elapsed) '。']);
                        end
                        obj.updateControls;
                    elseif toc(obj.WaitReady)>120
                        session=obj.Bridge.Session;
                        ready=obj.fieldOr(obj.Status,'ps_ready','?');
                        fault=obj.fieldOr(obj.Status,'fault','?');
                        channels=obj.fieldOr(obj.Status,'fault_channels','?');
                        stage=obj.fieldOr(obj.Status,'init_stage','?');
                        obj.WaitReady=[]; obj.InitFlow=false; obj.Job=[];
                        obj.log(sprintf('等待RF ready超时（ps_ready=%s, fault=%s, fault_channels=%s, init_stage=%s）；请查看PS串口、%s及%s。', ...
                            ready,fault,channels,stage,obj.InitLog,fullfile(session,'backend.log')));
                        obj.LastHint='等了 2 分钟，RF 仍未就绪：先看 PS 串口日志；可点“刷新状态”再读一次，或重新点 ① 初始化板卡。';
                        obj.HintStep=1; obj.HintLocal=false;
                        obj.updateControls;
                    elseif toc(obj.LastReadyPoll)>2
                        obj.LastReadyPoll=tic; obj.send('status');
                    end
                end
                obj.refreshProgress;
            catch err, obj.fail(err); end
        end
        function applyResponse(obj,response,action)
            stateFields={'running','busy','ps_ready','fault','command_result','init_stage','fault_channels','length_beats','channel_mask'};
            for k=1:numel(stateFields)
                if isfield(response,stateFields{k})
                    obj.Status.(stateFields{k})=response.(stateFields{k}); obj.StatusTime=datestr(now,'HH:MM:SS');
                end
            end
            if ~isfield(response,'ok') || ~strcmp(response.ok,'1')
                obj.Uploaded=false;
                message='后台响应格式错误。';
                if isfield(response,'message'), message=obj.backendDetail(response.message,action); end
                if strcmp(action,'connect') || isempty(action) || isempty(obj.Bridge.Process) || ~obj.Bridge.Process.isAlive
                    obj.Connected=false; obj.Bridge.terminate;
                end
                error('%s',message);
            end
            background=strcmp(action,'status') && ~isempty(obj.WaitReady);
            switch action
                case 'connect'
                    obj.Connected=true; obj.Uploaded=false; obj.Captured=false;
                    if obj.InitFlow
                        % After an initialization the task continues until RF
                        % is ready. Any other connection reports the state as read.
                        obj.WaitReady=tic; obj.LastReadyPoll=tic; obj.beginJob('wait_ready');
                    else
                        obj.finishJob;
                    end
                    obj.log('40GbE 已连接，D3C / ABI、容量与采样率核对通过。');
                case {'load','run'}
                    obj.Uploaded=true;
                case 'disconnect'
                    obj.Connected=false; obj.Uploaded=false; obj.Captured=false;
                    obj.WaitReady=[]; obj.InitFlow=false;
                    obj.Bridge.terminate;
                    obj.log('40GbE 连接已释放；断开连接不改变现有 DAC 播放。');
            end
            if isfield(response,'capture')
                obj.loadCapture(response.capture);
                obj.saveCapture([response.capture(1:end-4) '.mat']);
                obj.Captured=true;
                % The board decides the record length; use the real count for timing.
                if ~isempty(obj.Job) && isfield(obj.Rx,'metadata') && isfield(obj.Rx.metadata,'samples')
                    obj.Job.captureSamples=double(obj.Rx.metadata.samples);
                end
            end
            if isfield(response,'released') && strcmp(response.released,'1')
                obj.Connected=false; obj.Uploaded=false; obj.WaitReady=[]; obj.InitFlow=false;
                obj.Bridge.terminate;
                obj.log('远程控制权已释放；DAC 保持当前播放状态。');
            end
            if ~background && ~strcmp(action,'connect')
                obj.finishJob;
                % An action issued during the ready wait does not end the wait.
                if ~isempty(obj.WaitReady), obj.beginJob('wait_ready'); end
            end
            obj.updateControls;
            if strcmp(action,'disconnect') && strcmp(obj.AfterDisconnect,'initialize')
                obj.AfterDisconnect=''; obj.initialize;
            elseif strcmp(action,'start') && ~isempty(obj.Chain)
                next=obj.Chain; obj.Chain=''; obj.send(next);
            end
        end
        function fail(obj,err,backend)
            % backend=true: the failure came from the board task, so the current
            % download no longer counts. backend=false: a local input error; a
            % board task that is still running keeps its busy state and progress.
            if nargin<3, backend=true; end
            obj.LastError=err.message; obj.Chain=''; obj.Deferred='';
            afterInit=backend && obj.InitFlow && isempty(obj.InitProcess);
            if backend
                obj.Busy=false; obj.Uploaded=false; obj.WaitReady=[]; obj.InitFlow=false; obj.Job=[];
            else
                obj.Busy=~isempty(obj.InitProcess) || ~isempty(obj.Bridge.Pending);
                if ~obj.Busy && isempty(obj.WaitReady), obj.Job=[]; end
            end
            info=AWGScopeApp.explain(err.message,~backend);
            if afterInit && info.step==1 && ~contains(err.message,'初始化进程失败')
                % The script ran to its end, so "initialize the board" alone
                % would send the user round in a circle: point to the logs.
                info.text=['初始化脚本已经跑完，但随后仍然出错，说明这次初始化没有生效。查看初始化日志 ' obj.InitLog ...
                    ' 和 PS 串口输出，排除后再点 ① 初始化板卡。'];
                info.hint='这次初始化没有生效：查看初始化日志和 PS 串口输出，排除后再点 ① 初始化板卡。';
            end
            % While a board task keeps running, its progress stays on display.
            if isempty(obj.Job)
                obj.LastHint=info.hint; obj.HintStep=info.step; obj.HintLocal=~backend;
            end
            obj.log(['错误：' err.message]);
            if ~isempty(info.text), obj.log(['处理：' info.text]); end
            if info.settings, obj.UI.tabs.SelectedTab=obj.UI.configTab; end
            obj.updateControls;
            if obj.ShowAlerts && isvalid(obj.Figure)
                text=err.message;
                if ~isempty(info.text)
                    raw=err.message; if numel(raw)>600, raw=[raw(1:600) '…']; end
                    text=sprintf('%s\n\n后台原始信息：%s',info.text,raw);
                end
                uialert(obj.Figure,text,'操作未完成');
            end
        end
        function delete(obj)
            obj.Closing=true;
            try, stop(obj.Timer); delete(obj.Timer); catch, end
            obj.closeUART;
            try, delete(obj.Bridge); catch, end
            AWGBridge.killProcess(obj.InitProcess);
            try, delete(obj.Figure); catch, end
        end
    end
    methods (Access=private)
        function mask=readChannelMask(~,buttons)
            mask=0;
            for ch=0:7
                if buttons{ch+1}.Value, mask=mask+2^ch; end
            end
        end
        function syncChannelButtons(obj,mask)
            validateattributes(mask,{'numeric'},{'scalar','integer','>=',1,'<=',255});
            for ch=0:7
                selected=bitget(uint8(mask),ch+1)~=0;
                obj.UI.dacButtons{ch+1}.Value=selected;
                obj.UI.adcButtons{ch+1}.Value=selected;
            end
            obj.paintChannelButtons(obj.UI.dacButtons);
            obj.paintChannelButtons(obj.UI.adcButtons);
        end
        function paintChannelButtons(~,buttons)
            selectedColor=[46 130 149]/255;
            idleColor=[233 242 244]/255;
            for k=1:numel(buttons)
                if buttons{k}.Value
                    buttons{k}.BackgroundColor=selectedColor;
                    buttons{k}.FontColor=[1 1 1];
                else
                    buttons{k}.BackgroundColor=idleColor;
                    buttons{k}.FontColor=[.18 .28 .32];
                end
            end
        end
        function names=channelNames(~,mask,prefix)
            channels=find(bitget(uint8(mask),1:8))-1;
            labels=arrayfun(@(ch) sprintf('%s%d',prefix,ch),channels,'UniformOutput',false);
            names=strjoin(labels,'、');
        end
        function dacChannelChanged(obj,ch)
            obj.UI.adcButtons{ch+1}.Value=obj.UI.dacButtons{ch+1}.Value;
            mask=obj.readChannelMask(obj.UI.dacButtons);
            if mask==0
                obj.UI.dacButtons{ch+1}.Value=true;
                obj.UI.adcButtons{ch+1}.Value=true;
                mask=2^ch;
            end
            obj.paintChannelButtons(obj.UI.dacButtons);
            obj.paintChannelButtons(obj.UI.adcButtons);
            if isempty(obj.Raw)
                obj.UI.selection.Text=sprintf('已选 %s；请选择波形或生成测试信号。',obj.channelNames(mask,'DAC'));
                obj.updateControls;
                return
            end
            obj.prepareTx;
            obj.UI.view.Value='tx'; obj.render;
        end
        function adcChannelChanged(obj,ch)
            if obj.readChannelMask(obj.UI.adcButtons)==0
                obj.UI.adcButtons{ch+1}.Value=true;
                obj.log('至少保留一个ADC采集通道。');
            end
            obj.paintChannelButtons(obj.UI.adcButtons);
            obj.updateControls;
        end
        function buildUI(obj)
            bg=[.95 .97 .98]; ink=obj.Ink; accent=obj.Accent; muted=obj.Muted;
            % Keep the whole window, including the step bar at its top, on the screen.
            screen=get(groot,'ScreenSize');
            width=min(1440,screen(3)-80); height=min(920,screen(4)-140);
            obj.Figure=uifigure('Name','47DR AWG / I/Q 示波器','Position',[70 60 width height], ...
                'Visible','off','Color',bg,'CloseRequestFcn',@(~,~) obj.closeRequest);
            main=uigridlayout(obj.Figure,[6 1],'RowHeight',{38,40,30,'1x',108,20},'Padding',[16 10 16 8],'RowSpacing',8);
            % Row 1: title, connection target and the board status last read.
            header=uigridlayout(main,[1 13],'ColumnWidth',{250,'1x',200,16,52,16,52,16,30,16,30,84,84}, ...
                'Padding',[4 0 4 0],'ColumnSpacing',6);
            uilabel(header,'Text','47DR  /  AWG + SCOPE','FontSize',21,'FontWeight','bold','FontColor',ink);
            obj.UI.target=uilabel(header,'Text','','HorizontalAlignment','right','FontColor',muted);
            obj.UI.state=uilabel(header,'Text','未连接','HorizontalAlignment','right','FontWeight','bold','FontSize',14);
            lamps={'jtag','40GbE';'ready','RF 就绪';'play','播放';'fault','故障'};
            for k=1:size(lamps,1)
                obj.UI.(['lamp_' lamps{k,1}])=uilamp(header,'Color',obj.LampOff);
                uilabel(header,'Text',lamps{k,2},'FontColor',ink);
            end
            obj.UI.refresh=uibutton(header,'Text','刷新状态','Tooltip','重新读取板卡的就绪、播放和故障状态', ...
                'ButtonPushedFcn',@(~,~) obj.guard(@() obj.send('status')));
            obj.UI.clear=uibutton(header,'Text','清除故障','Tooltip','停止播放后，清除锁存的DAC故障', ...
                'ButtonPushedFcn',@(~,~) obj.guard(@() obj.send('clear')));
            % Row 2: operating order. Steps 1 and 2 are the entry points to the board.
            flow=uigridlayout(main,[1 12],'ColumnWidth',{160,14,140,14,110,14,140,14,90,'1x',96,96}, ...
                'Padding',[6 4 6 4],'ColumnSpacing',4,'BackgroundColor',[1 1 1]);
            obj.UI.initialize=uibutton(flow,'Text','① 初始化板卡', ...
                'Tooltip','复位板卡、下载bit并运行RF初始化程序。板卡刚上电或换过bit时需要；完成后自动连接', ...
                'ButtonPushedFcn',@(~,~) obj.guard(@() obj.requestInitialize));
            uilabel(flow,'Text','›','HorizontalAlignment','center','FontSize',16,'FontColor',muted);
            obj.UI.connect=uibutton(flow,'Text','② 连接板卡', ...
                'Tooltip','连接已经初始化的板卡并读取状态，不改变播放', ...
                'ButtonPushedFcn',@(~,~) obj.guard(@() obj.connect));
            uilabel(flow,'Text','›','HorizontalAlignment','center','FontSize',16,'FontColor',muted);
            obj.UI.stepWave=uilabel(flow,'Text','③ 选波形','HorizontalAlignment','center');
            uilabel(flow,'Text','›','HorizontalAlignment','center','FontSize',16,'FontColor',muted);
            obj.UI.stepPlay=uilabel(flow,'Text','④ 下载并播放','HorizontalAlignment','center');
            uilabel(flow,'Text','›','HorizontalAlignment','center','FontSize',16,'FontColor',muted);
            obj.UI.stepCapture=uilabel(flow,'Text','⑤ 采集','HorizontalAlignment','center');
            uilabel(flow,'Text','');
            obj.UI.disconnect=uibutton(flow,'Text','断开连接','Tooltip','释放40GbE连接；不会停止DAC播放', ...
                'ButtonPushedFcn',@(~,~) obj.guard(@() obj.send('disconnect')));
            obj.UI.openSettings=uibutton(flow,'Text','连接设置','Tooltip','40GbE地址、Python、初始化XSCT与UART日志', ...
                'ButtonPushedFcn',@(~,~) obj.showSettings);
            % Row 3: the next step while idle, or the progress of the running task.
            obj.UI.guideRow=uigridlayout(main,[1 5],'ColumnWidth',{0,'1x',0,0,0},'Padding',[10 4 10 4], ...
                'ColumnSpacing',12,'BackgroundColor',[1 1 1]);
            obj.UI.bar=uigridlayout(obj.UI.guideRow,[1 3],'ColumnWidth',{0,0,'1x'},'Padding',[0 5 0 5], ...
                'ColumnSpacing',0,'BackgroundColor',[1 1 1]);
            obj.UI.barPre=uilabel(obj.UI.bar,'Text','','BackgroundColor',obj.Track);
            obj.UI.barFill=uilabel(obj.UI.bar,'Text','','BackgroundColor',accent);
            obj.UI.barPost=uilabel(obj.UI.bar,'Text','','BackgroundColor',obj.Track);
            obj.UI.guide=uilabel(obj.UI.guideRow,'Text','','FontSize',13,'FontColor',ink);
            obj.UI.percent=uilabel(obj.UI.guideRow,'Text','','HorizontalAlignment','right','FontWeight','bold','FontColor',accent);
            obj.UI.elapsed=uilabel(obj.UI.guideRow,'Text','','FontColor',ink);
            obj.UI.remaining=uilabel(obj.UI.guideRow,'Text','','FontColor',ink);
            body=uigridlayout(main,[1 2],'ColumnWidth',{380,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',14);
            tabs=uitabgroup(body); obj.UI.tabs=tabs;
            waveTab=uitab(tabs,'Title','收发操作'); parameterTab=uitab(tabs,'Title','发射参数'); configTab=uitab(tabs,'Title','连接设置');
            obj.UI.configTab=configTab;
            left=uigridlayout(waveTab,[16 2],'ColumnWidth',{'1x','1x'}, ...
                'RowHeight',{22,32,30,52,32,24,32,32,22,52,26,26,18,32,32,'1x'}, ...
                'Padding',[12 8 12 8],'RowSpacing',6,'Scrollable','on');
            % Step 3: waveform and DAC channels.
            l=uilabel(left,'Text','③ 选波形（DAC 9.8 GS/s 实数样点）','FontWeight','bold','FontColor',accent); obj.span(l,1);
            obj.UI.import=uibutton(left,'Text','导入发射 MAT / CSV','ButtonPushedFcn',@(~,~) obj.guard(@() obj.chooseWave));
            obj.place(obj.UI.import,2,1);
            obj.UI.demoTx=uibutton(left,'Text','生成单路测试波形','ButtonPushedFcn',@(~,~) obj.guard(@() obj.demoTx));
            obj.place(obj.UI.demoTx,2,2);
            obj.UI.source=uilabel(left,'Text','尚未导入发射数据','WordWrap','on','FontColor',ink); obj.span(obj.UI.source,3);
            txChannels=uigridlayout(left,[2 4],'ColumnWidth',{'1x','1x','1x','1x'}, ...
                'RowHeight',{24,24},'Padding',[0 0 0 0],'ColumnSpacing',4,'RowSpacing',4);
            txChannels.Layout.Row=4; txChannels.Layout.Column=[1 2];
            obj.UI.dacButtons=cell(1,8);
            for ch=0:7
                channel=ch;
                button=uibutton(txChannels,'state','Text',sprintf('DAC%d',channel),'Value',channel==0, ...
                    'FontWeight','bold','Tooltip',sprintf('选择DAC%d输出；选中时自动选择ADC%d',channel,channel), ...
                    'ValueChangedFcn',@(~,~) obj.guard(@() obj.dacChannelChanged(channel)));
                button.Layout.Row=floor(channel/4)+1; button.Layout.Column=mod(channel,4)+1;
                obj.UI.dacButtons{channel+1}=button;
            end
            obj.paintChannelButtons(obj.UI.dacButtons);
            obj.UI.selection=uilabel(left,'Text','选择DAC通道后导入波形或生成测试信号','WordWrap','on'); obj.span(obj.UI.selection,5);
            params=uigridlayout(parameterTab,[10 2],'ColumnWidth',{'1x','1x'}, ...
                'RowHeight',{34,34,34,34,34,34,60,64,54,'1x'},'Padding',[12 16 12 10],'RowSpacing',12);
            uilabel(params,'Text','源采样率 / MS/s（必须9800）'); obj.UI.fs=uieditfield(params,'numeric','Value',9800,'Limits',[eps 9800],'ValueDisplayFormat','%.3f');
            uilabel(params,'Text','源数据单位'); obj.UI.units=uidropdown(params,'Items',{'归一化实数','16 bit 码值'},'ItemsData',{'normalized','codes'});
            uilabel(params,'Text','源起始样点（从1计）'); obj.UI.first=uieditfield(params,'numeric','Value',1,'Limits',[1 Inf],'RoundFractionalValues','on');
            uilabel(params,'Text','源播放点数（32的倍数）'); obj.UI.count=uieditfield(params,'numeric','Value',1024,'Limits',[1 131072],'RoundFractionalValues','on');
            obj.UI.normalize=uicheckbox(params,'Text','归一化到实数峰值','Value',true);
            obj.UI.amplitude=uieditfield(params,'numeric','Value',0.25,'Limits',[0.001 1]);
            l=uilabel(params,'Text','上位机不重采样：请先在MATLAB中重采样到9.8 GS/s，再导入实数波形；不做上变频。','WordWrap','on'); obj.span(l,7);
            l=uilabel(params,'Text','MAT：N×C实数矩阵，每列一个DAC通道；CSV/TXT：每列一个实数通道。文件含Fs时自动读取，否则按界面采样率。','WordWrap','on'); obj.span(l,8);
            l=uilabel(params,'Text','每路DAC RAM上限131072个9.8 GS/s实数样点（256 KiB）；播放区间点数必须为32的倍数，不截尾、不补零。','WordWrap','on'); obj.span(l,9);
            % Step 4: download and playback.
            l=uilabel(left,'Text','④ 下载并播放','FontWeight','bold','FontColor',accent); obj.place(l,6,1);
            obj.UI.verify=uicheckbox(left,'Text','下载 CRC 校验','Value',true, ...
                'Tooltip','每路下载后由 FPGA 计算 CRC 并与发送数据比对；不逐字回读', ...
                'ValueChangedFcn',@(~,~) obj.guard(@() obj.verifyChanged));
            obj.place(obj.UI.verify,6,2);
            obj.UI.download=uibutton(left,'Text','下载（停播并校验）','ButtonPushedFcn',@(~,~) obj.guard(@() obj.requestTransfer('load')));
            obj.place(obj.UI.download,7,1);
            obj.UI.run=uibutton(left,'Text','一键下载并采集','ButtonPushedFcn',@(~,~) obj.guard(@() obj.requestTransfer('run')));
            obj.place(obj.UI.run,7,2);
            obj.UI.start=uibutton(left,'Text','▶ 开始循环播放','ButtonPushedFcn',@(~,~) obj.guard(@() obj.send('start')));
            obj.place(obj.UI.start,8,1);
            obj.UI.stop=uibutton(left,'Text','■ 停止播放','ButtonPushedFcn',@(~,~) obj.guard(@() obj.send('stop')));
            obj.place(obj.UI.stop,8,2);
            % Step 5: ADC capture and 40GbE readback.
            l=uilabel(left,'Text','⑤ 采集（ADC 5 GS/s 原始样点）','FontWeight','bold','FontColor',accent); obj.span(l,9);
            rxChannels=uigridlayout(left,[2 4],'ColumnWidth',{'1x','1x','1x','1x'}, ...
                'RowHeight',{24,24},'Padding',[0 0 0 0],'ColumnSpacing',4,'RowSpacing',4);
            rxChannels.Layout.Row=10; rxChannels.Layout.Column=[1 2];
            obj.UI.adcButtons=cell(1,8);
            for ch=0:7
                channel=ch;
                button=uibutton(rxChannels,'state','Text',sprintf('ADC%d',channel),'Value',channel==0, ...
                    'FontWeight','bold','Tooltip',sprintf('选择ADC%d采集；对应DAC%d选中时会自动勾选',channel,channel), ...
                    'ValueChangedFcn',@(~,~) obj.guard(@() obj.adcChannelChanged(channel)));
                button.Layout.Row=floor(channel/4)+1; button.Layout.Column=mod(channel,4)+1;
                obj.UI.adcButtons{channel+1}=button;
            end
            obj.paintChannelButtons(obj.UI.adcButtons);
            l=uilabel(left,'Text','采集触发方式'); obj.place(l,11,1);
            obj.UI.trigger=uidropdown(left,'Items',{'播放中手动触发','重新启动播放时触发'},'ItemsData',{'manual','start'});
            obj.place(obj.UI.trigger,11,2);
            l=uilabel(left,'Text','回读点数（每路）'); obj.place(l,12,1);
            obj.UI.readLength=uieditfield(left,'numeric','Value',65520,'Limits',[24 65520],'RoundFractionalValues','on', ...
                'ValueDisplayFormat','%d','Tooltip','设置每路实际采集并通过40GbE回读的点数，24到65520点，向上按24点一组取整', ...
                'ValueChangedFcn',@(~,~) obj.guard(@() obj.readLengthChanged));
            obj.place(obj.UI.readLength,12,2);
            obj.UI.estimate=uilabel(left,'Text','','FontColor',muted,'FontSize',11, ...
                'Tooltip','按上一次传输实测的平均速度估算；网络快慢变化时会有偏差');
            obj.span(obj.UI.estimate,13);
            obj.UI.capture=uibutton(left,'Text','采集并显示','ButtonPushedFcn',@(~,~) obj.guard(@() obj.send('capture')));
            obj.place(obj.UI.capture,14,1);
            obj.UI.save=uibutton(left,'Text','保存接收 MAT','ButtonPushedFcn',@(~,~) obj.guard(@() obj.chooseSave));
            obj.place(obj.UI.save,14,2);
            obj.UI.workspace=uibutton(left,'Text','接收数据送入工作区','ButtonPushedFcn',@(~,~) obj.guard(@() obj.toWorkspace)); obj.span(obj.UI.workspace,15);
            settings=uigridlayout(configTab,[21 2],'ColumnWidth',{125,'1x'}, ...
                'RowHeight',{28,28,28,32,28,32,28,28,28,28,28,32,32,50,50,40,32,28,28,28,'1x'}, ...
                'RowSpacing',6,'Scrollable','on','Padding',[12 8 12 8]);
            uilabel(settings,'Text','板卡 IPv4'); obj.UI.cfg_fpga_ip=uieditfield(settings,'Value','192.168.42.2');
            uilabel(settings,'Text','UDP 端口'); obj.UI.cfg_port=uieditfield(settings,'numeric','Value',9100,'Limits',[1 65535],'RoundFractionalValues','on');
            uilabel(settings,'Text','每包字数'); obj.UI.cfg_words_per_packet=uidropdown(settings,'Items',{'256（普通 MTU）','2048（MTU 9000）'},'ItemsData',[256 2048],'Value',256);
            uilabel(settings,'Text','Python 3.10+'); obj.UI.browsePython=uibutton(settings,'Text','选择 python.exe','ButtonPushedFcn',@(~,~) obj.browseTool('python'));
            obj.UI.cfg_python=uieditfield(settings,'Value',AWGScopeApp.findTool('python')); obj.span(obj.UI.cfg_python,5);
            uilabel(settings,'Text','初始化 XSCT'); obj.UI.browseXsct=uibutton(settings,'Text','选择 xsct.bat','ButtonPushedFcn',@(~,~) obj.browseTool('xsct'));
            obj.UI.cfg_xsct=uieditfield(settings,'Value',AWGScopeApp.findTool('xsct')); obj.span(obj.UI.cfg_xsct,7);
            uilabel(settings,'Text','JTAG HW server'); obj.UI.cfg_server=uieditfield(settings,'Value','localhost:3121');
            uilabel(settings,'Text','初始化位置'); obj.UI.cfg_mode=uidropdown(settings,'Items',{'本机 JTAG','远程 JTAG'},'ItemsData',{'local','remote'},'Value','local');
            uilabel(settings,'Text','UART TCP主机'); obj.UI.cfg_uart_host=uieditfield(settings,'Value','localhost');
            uilabel(settings,'Text','UART TCP端口'); obj.UI.cfg_uart_port=uieditfield(settings,'numeric','Value',5001,'Limits',[1 65535],'RoundFractionalValues','on');
            obj.UI.uartConnect=uibutton(settings,'Text','连接 UART 日志','ButtonPushedFcn',@(~,~) obj.guardUART(@() obj.connectUART));
            obj.UI.uartDisconnect=uibutton(settings,'Text','断开 UART 日志','ButtonPushedFcn',@(~,~) obj.disconnectUART);
            obj.UI.saveSettings=uibutton(settings,'Text','保存连接设置','ButtonPushedFcn',@(~,~) obj.guard(@() obj.settings(true))); obj.span(obj.UI.saveSettings,13);
            l=uilabel(settings,'Text','电脑光口网卡使用 192.168.42.20/24，不能用 .10；每包2048字需 MTU 9000。','WordWrap','on'); obj.span(l,14);
            l=uilabel(settings,'Text','下载和回采走40GbE；远程模式通过实验室电脑转发。JTAG仅用于初始化。','WordWrap','on'); obj.span(l,15);
            l=uilabel(settings,'Text','本机设置与采集结果仅保存在此副本的 app_data，不与现役上位机共用。','WordWrap','on'); obj.span(l,16);
            l=uilabel(settings,'Text','传输方式'); l.Layout.Row=18; l.Layout.Column=1;
            obj.UI.cfg_transport=uidropdown(settings,'Items',{'本机直连光口','实验室远程服务'},'ItemsData',{'direct','remote'},'Value','direct'); obj.UI.cfg_transport.Layout.Row=18; obj.UI.cfg_transport.Layout.Column=2;
            l=uilabel(settings,'Text','远程服务地址'); l.Layout.Row=19; l.Layout.Column=1;
            obj.UI.cfg_remote_host=uieditfield(settings,'Value','127.0.0.1'); obj.UI.cfg_remote_host.Layout.Row=19; obj.UI.cfg_remote_host.Layout.Column=2;
            l=uilabel(settings,'Text','远程服务端口'); l.Layout.Row=20; l.Layout.Column=1;
            obj.UI.cfg_remote_port=uieditfield(settings,'numeric','Value',4748,'Limits',[1 65535],'RoundFractionalValues','on'); obj.UI.cfg_remote_port.Layout.Row=20; obj.UI.cfg_remote_port.Layout.Column=2;
            plots=uigridlayout(body,[3 1],'RowHeight',{38,'1x','1x'},'Padding',[8 4 8 4],'RowSpacing',8,'BackgroundColor',[1 1 1]);
            controls=uigridlayout(plots,[1 8],'ColumnWidth',{118,80,84,56,'1x',128,108,100},'Padding',[0 0 0 0]);
            controls.Layout.Row=1;
            obj.UI.view=uidropdown(controls,'Items',{'发射预览','ADC接收'},'ItemsData',{'tx','rx'},'ValueChangedFcn',@(~,~) obj.guard(@() obj.render));
            obj.UI.channel=uidropdown(controls,'Items',{'CH0'},'ItemsData',{'0'},'ValueChangedFcn',@(~,~) obj.guard(@() obj.render));
            obj.UI.span=uidropdown(controls,'Items',{'256','1024','4096','16384','32768'},'Value','1024','ValueChangedFcn',@(~,~) obj.guard(@() obj.render));
            uilabel(controls,'Text','窗口位置');
            obj.UI.offset=uislider(controls,'Limits',[1 2],'Value',1,'MajorTicks',[],'MinorTicks',[], 'ValueChangedFcn',@(~,~) obj.guard(@() obj.render));
            obj.UI.rf=uicheckbox(controls,'Text','射频频轴（估计）','ValueChangedFcn',@(~,~) obj.guard(@() obj.render));
            % Viewing saved or simulated records never touches the board.
            obj.UI.openRx=uibutton(controls,'Text','导入接收记录','Tooltip','查看已保存的接收 CSV / MAT，不连接板卡', ...
                'ButtonPushedFcn',@(~,~) obj.guard(@() obj.chooseCapture));
            obj.UI.demoRx=uibutton(controls,'Text','离线接收演示','Tooltip','载入一组模拟接收数据，不连接板卡', ...
                'ButtonPushedFcn',@(~,~) obj.guard(@() obj.demoRx));
            obj.UI.time=uiaxes(plots); obj.UI.spectrum=uiaxes(plots);
            obj.UI.time.Layout.Row=2; obj.UI.spectrum.Layout.Row=3;
            for ax=[obj.UI.time,obj.UI.spectrum], ax.Box='on'; ax.FontSize=12; ax.Color=[.99 .995 1]; end
            obj.UI.log=uitextarea(main,'Editable','off','FontName','Consolas','FontSize',11,'BackgroundColor',[.1 .16 .21],'FontColor',[.79 .89 .93]);
            obj.UI.footer=uilabel(main,'Text','DAC 9.8 GS/s · ADC 5 GS/s raw · MATLAB处理 · 40GbE UDP 传输', ...
                'FontColor',[.35 .4 .45]);
            obj.UI.footer.Layout.Row=6;
            obj.UI.facts=obj.UI.footer;
            for key={'fs','units','first','count','normalize','amplitude'}
                obj.UI.(key{1}).ValueChangedFcn=@(~,~) obj.guard(@() obj.changeWave);
            end
        end
        function changeWave(obj)
            obj.prepareTx; obj.UI.view.Value='tx'; obj.render;
        end
        function chooseWave(obj)
            [name,folder]=uigetfile({'*.mat;*.csv;*.txt','MATLAB / I-Q CSV (*.mat,*.csv,*.txt)'},'导入发射波形');
            if isequal(name,0), return; end
            obj.importWave(fullfile(folder,name));
        end
        function chooseCapture(obj)
            [name,folder]=uigetfile({'*.csv;*.mat','接收记录 (*.csv,*.mat)'},'导入接收记录',fullfile(obj.DataRoot,'captures'));
            if ~isequal(name,0), obj.loadCapture(fullfile(folder,name)); end
        end
        function chooseSave(obj)
            [name,folder]=uiputfile('*.mat','保存接收数据',fullfile(obj.DataRoot,'captures','capture.mat'));
            if ~isequal(name,0), obj.saveCapture(fullfile(folder,name)); end
        end
        function toWorkspace(obj)
            assert(~isempty(obj.Rx),'尚无接收数据。'); assignin('base','rx',obj.Rx);
            obj.log('接收数据已写入MATLAB工作区变量 rx；rx.iq(:,1)对应CH0。');
        end
        function cfg=settings(obj,explicit)
            if nargin<2, explicit=false; end
            cfg=struct;
            for name={'mode','python','xsct','server','fpga_ip','uart_host','transport','remote_host'}
                cfg.(name{1})=strtrim(obj.UI.(['cfg_' name{1}]).Value);
            end
            cfg.port=obj.UI.cfg_port.Value; cfg.words_per_packet=obj.UI.cfg_words_per_packet.Value;
            cfg.uart_port=obj.UI.cfg_uart_port.Value;
            cfg.remote_port=obj.UI.cfg_remote_port.Value;
            assert(~isempty(cfg.remote_host),'远程服务地址不能为空。');
            assert(~isempty(cfg.fpga_ip),'板卡 IPv4 不能为空。');
            path=fullfile(obj.DataRoot,'settings.json');
            [saved,changed]=AWGScopeApp.writeText(path,jsonencode(cfg),12,0.25);
            if explicit
                assert(saved,'无法保存连接设置：%s 正被其他程序占用。',path);
                if changed, obj.log('连接设置已保存。'); else, obj.log('连接设置没有变化。'); end
            elseif ~saved
                obj.log('未能保存连接设置，本次使用界面上的值。');
            end
        end
        function browseTool(obj,name)
            filter='*.bat'; if strcmp(name,'python'), filter='*.exe'; end
            [file,folder]=uigetfile(filter,['选择 ' name]);
            if ~isequal(file,0), obj.UI.(['cfg_' name]).Value=fullfile(folder,file); end
        end
        function value=endpoint(obj)
            value=sprintf('%s:%d / %d words',strtrim(obj.UI.cfg_fpga_ip.Value),obj.UI.cfg_port.Value,obj.UI.cfg_words_per_packet.Value);
        end
        function updateControls(obj)
            if isempty(obj.Figure) || ~isvalid(obj.Figure), return; end
            % The ready poll that follows initialization is not a user task:
            % it must not switch the controls off and on every two seconds.
            busy=obj.Busy && ~obj.backgroundPoll;
            obj.UI.connect.Enable=obj.on(~busy && ~obj.Connected);
            obj.UI.initialize.Enable=obj.on(~busy);
            obj.UI.disconnect.Enable=obj.on(~busy && obj.Connected);
            ready=isfield(obj.Status,'ps_ready') && strcmp(obj.Status.ps_ready,'1');
            running=isfield(obj.Status,'running') && strcmp(obj.Status.running,'1');
            fault=isfield(obj.Status,'fault') && strcmp(obj.Status.fault,'1');
            for key={'download','run'}, obj.UI.(key{1}).Enable=obj.on(obj.Connected && ready && ~busy && ~isempty(obj.Tx)); end
            obj.UI.start.Enable=obj.on(obj.Connected && ready && ~busy && obj.Uploaded && ~running && ~fault);
            obj.UI.stop.Enable=obj.on(obj.Connected && ready && ~busy);
            obj.UI.clear.Enable=obj.on(obj.Connected && ready && ~busy && ~running);
            obj.UI.capture.Enable=obj.on(obj.Connected && ready && ~busy);
            obj.UI.refresh.Enable=obj.on(obj.Connected && ~busy);
            obj.UI.save.Enable=obj.on(~isempty(obj.Rx) && ~busy);
            obj.UI.workspace.Enable=obj.UI.save.Enable;
            for key={'import','demoTx','openRx','demoRx','fs','units','first','count','normalize','amplitude', ...
                    'trigger','verify','readLength','browsePython','browseXsct','saveSettings'}
                obj.UI.(key{1}).Enable=obj.on(~busy);
            end
            for k=1:8
                obj.UI.dacButtons{k}.Enable=obj.on(~busy);
                obj.UI.adcButtons{k}.Enable=obj.on(~busy);
            end
            for key={'python','xsct','server','fpga_ip','port','remote_host','remote_port'}, obj.UI.(['cfg_' key{1}]).Editable=obj.on(~busy && ~obj.Connected); end
            obj.UI.cfg_transport.Enable=obj.on(~busy && ~obj.Connected);
            obj.UI.cfg_words_per_packet.Enable=obj.on(~busy && ~obj.Connected);
            obj.UI.cfg_uart_host.Editable=obj.on(isempty(obj.UartSocket)); obj.UI.cfg_uart_port.Editable=obj.on(isempty(obj.UartSocket));
            obj.UI.uartConnect.Enable=obj.on(isempty(obj.UartSocket)); obj.UI.uartDisconnect.Enable=obj.on(~isempty(obj.UartSocket));
            obj.UI.cfg_mode.Enable=obj.on(~busy && ~obj.Connected);
            if obj.UI.verify.Value, obj.UI.download.Text='下载（停播并校验）'; else, obj.UI.download.Text='下载（停播，不校验）'; end
            obj.showState(busy,ready,running,fault);
            obj.showSteps(busy,ready,running,fault);
            obj.showEstimate;
            if isempty(obj.Job), obj.showGuide(busy,ready,running,fault); else, obj.showProgress; end
        end
        function showState(obj,busy,ready,running,fault)
            % Header: one phrase for the connection state, four lamps for the
            % board status last read, and when it was read.
            color=obj.Warn;
            if ~isempty(obj.InitProcess) || obj.InitFlow
                text='正在初始化板卡';
            elseif busy && ~obj.Connected
                text='正在连接板卡';
            elseif busy
                text='已连接，正在执行任务';
                if ~isempty(obj.Job), text=['已连接，正在' obj.Job.label]; end
            elseif ~obj.Connected
                text='未连接'; color=obj.Muted;
            elseif ~ready
                text='已连接，RF 未就绪';
            elseif fault
                text='已连接，DAC 故障'; color=obj.Bad;
            elseif running
                text='已连接，RF 就绪，播放中'; color=obj.Good;
            else
                text='已连接，RF 就绪'; color=obj.Good;
            end
            obj.UI.state.Text=text; obj.UI.state.FontColor=color;
            jtag=obj.LampOff; lampReady=obj.LampOff; lampPlay=obj.LampOff; lampFault=obj.LampOff;
            if obj.Connected
                jtag=obj.LampGood;
                if ready, lampReady=obj.LampGood; else, lampReady=obj.LampWarn; end
                % A task that stops or restarts playback makes the last reading
                % stale; show the lamp again once the task has reported.
                changing=busy && ~isempty(obj.Job) && any(strcmp(obj.Job.action,{'load','run','start','stop'}));
                if running && ~changing, lampPlay=obj.LampGood; end
                if fault, lampFault=obj.LampBad; end
            elseif busy
                jtag=obj.LampWarn;
            end
            obj.UI.lamp_jtag.Color=jtag; obj.UI.lamp_ready.Color=lampReady;
            obj.UI.lamp_play.Color=lampPlay; obj.UI.lamp_fault.Color=lampFault;
            target=['40GbE ' obj.endpoint];
            if obj.Connected && ~isempty(obj.StatusTime), target=[target ' · 状态读取于 ' obj.StatusTime]; end
            obj.UI.target.Text=target;
        end
        function showSteps(obj,busy,ready,running,fault)
            % Step bar: finished steps get a check mark, the next one is
            % emphasized. One action button at a time carries the emphasis.
            done=false(1,5); current=0;
            if ~isempty(obj.InitProcess) || obj.InitFlow
                current=1; done(2)=obj.Connected;
            elseif ~obj.Connected
                current=2; if obj.HintStep==1, current=1; end
            elseif ~ready
                done(2)=true; current=1;
            else
                done(1:2)=true; done(3)=~isempty(obj.Tx);
                done(4)=obj.Uploaded && running; done(5)=done(4) && obj.Captured;
                if ~done(3), current=3; elseif ~done(4), current=4; elseif ~done(5), current=5; end
            end
            names={'initialize','connect','stepWave','stepPlay','stepCapture'};
            titles={'① 初始化板卡','② 连接板卡','③ 选波形','④ 下载并播放','⑤ 采集'};
            for k=1:5
                h=obj.UI.(names{k}); text=titles{k};
                if k==current
                    h.BackgroundColor=obj.Accent; h.FontColor=[1 1 1]; h.FontWeight='bold';
                elseif done(k)
                    text=[text ' ✓']; h.BackgroundColor=[.86 .94 .90]; h.FontColor=obj.Good; h.FontWeight='normal';
                else
                    h.BackgroundColor=[.94 .95 .96]; h.FontColor=obj.Ink; h.FontWeight='normal';
                end
                h.Text=text;
            end
            primary='';
            if obj.Connected && ready && ~busy
                if fault
                    % A latched fault comes first: stop playback, then clear it.
                    if running, primary='stop'; else, primary='clear'; end
                elseif isempty(obj.Tx)
                    if running, primary='capture'; else, primary='import'; end
                elseif ~obj.Uploaded
                    if obj.boardPlaysCurrent, primary='capture'; else, primary='run'; end
                elseif ~running
                    primary='start';
                else
                    primary='capture';
                end
            end
            for key={'import','run','start','capture','stop','clear'}
                h=obj.UI.(key{1});
                if strcmp(key{1},primary)
                    h.BackgroundColor=obj.Accent; h.FontColor=[1 1 1]; h.FontWeight='bold';
                else
                    h.BackgroundColor=[.96 .96 .96]; h.FontColor=[0 0 0]; h.FontWeight='normal';
                end
            end
        end
        function same=boardPlaysCurrent(obj)
            % True when the board is playing a waveform with the same channels
            % and length as the one prepared here (its content is unknown).
            same=false;
            if isempty(obj.Tx) || ~(isfield(obj.Status,'running') && strcmp(obj.Status.running,'1')), return; end
            mask=str2double(obj.fieldOr(obj.Status,'channel_mask',''));
            beats=str2double(obj.fieldOr(obj.Status,'length_beats',''));
            same=isfinite(mask) && isfinite(beats) && mask==obj.Tx.channelMask && 32*beats==size(obj.Tx.iq,1);
        end
        function showEstimate(obj)
            download=obj.transferEstimate('load'); readback=obj.transferEstimate('capture');
            if isempty(readback)
                text='预计用时：完成一次传输后给出';
            elseif isempty(download)
                text=['预计：回读' readback '（按上次速度）'];
            else
                text=['预计：下载' download '，回读' readback '（按上次速度）'];
            end
            obj.UI.estimate.Text=text;
        end
        function text=transferEstimate(obj,kind)
            % Time for the current selection at the speed measured on the last
            % transfer to this HW server; empty without such a measurement.
            text='';
            rate=obj.Timing.ms_per_word;
            if ~isfinite(rate) || ~strcmp(obj.Timing.server,obj.endpoint), return; end
            if strcmp(kind,'load')
                if isempty(obj.Tx), return; end
                words=sum(bitget(uint8(obj.Tx.channelMask),1:8))*size(obj.Tx.iq,1)/2;
            else
                words=sum(bitget(uint8(obj.readChannelMask(obj.UI.adcButtons)),1:8))* ...
                    AWGScopeApp.roundReadLength(obj.UI.readLength.Value)/2;
            end
            text=['约 ' AWGScopeApp.timeText(words*rate/1000)];
        end
        function showGuide(obj,busy,ready,running,fault)
            % Idle: the guide row names the next step, or what went wrong.
            [text,color,weight]=obj.nextStep(busy,ready,running,fault);
            obj.UI.guideRow.ColumnWidth={0,'1x',0,0,0};
            obj.UI.guide.Text=text; obj.UI.guide.FontColor=color; obj.UI.guide.FontWeight=weight;
            obj.UI.percent.Text=''; obj.UI.elapsed.Text=''; obj.UI.remaining.Text='';
        end
        function [text,color,weight]=nextStep(obj,busy,ready,running,fault)
            color=obj.Ink; weight='normal';
            if ~isempty(obj.LastHint)
                text=obj.LastHint; color=obj.Bad; weight='bold';
            elseif busy
                text='正在执行任务…';
            elseif ~obj.Connected
                if strcmp(obj.UI.cfg_transport.Value,'remote')
                    text='下一步：点 ② 连接并查看板卡状态；完成播放或采集后自动释放控制权。';
                else
                    text='下一步：点 ② 连接板卡。板卡刚上电或换过 bit 时，先点 ① 初始化板卡。';
                end
            elseif ~ready
                text='RF 未就绪：点 ① 初始化板卡。刚初始化完的话，稍等后点“刷新状态”。'; color=obj.Warn; weight='bold';
            elseif fault
                text='DAC 报故障：点“清除故障”。'; color=obj.Bad; weight='bold';
                if running, text='DAC 报故障：先点“停止播放”，再点“清除故障”。'; end
            elseif isempty(obj.Tx)
                text='下一步：③ 选波形。导入 MAT / CSV，或生成单路测试波形。';
                mask=str2double(obj.fieldOr(obj.Status,'channel_mask',''));
                beats=str2double(obj.fieldOr(obj.Status,'length_beats',''));
                if running && isfinite(mask) && mask>=1 && mask<=255 && isfinite(beats)
                    text=sprintf('板卡正在播放 %s（%d 点/路）。可以直接 ⑤ 采集；要换波形先 ③ 选波形。', ...
                        obj.channelNames(mask,'DAC'),32*beats);
                end
            elseif ~obj.Uploaded
                text='下一步：④ 下载当前波形，或点“一键下载并采集”。';
                if obj.boardPlaysCurrent
                    text='板卡正在播放的波形与当前波形通道、点数相同。内容没变可直接 ⑤ 采集并显示；变了再 ④ 下载。';
                end
            elseif ~running
                text='当前波形已在板上。下一步：点“开始循环播放”，再 ⑤ 采集并显示。';
            elseif obj.Captured
                text='采集完成。波形没变时可直接再点“采集并显示”，不用重新下载。';
            else
                text='当前波形已在板上并正在播放：直接点“采集并显示”，不用重新下载。';
            end
        end
        function showProgress(obj)
            % Busy: the guide row shows the task, its progress, the time used
            % and, when there is a basis for it, the time remaining.
            job=obj.Job;
            if isempty(job) || isempty(obj.Figure) || ~isvalid(obj.Figure), return; end
            elapsed=toc(job.started);
            text=job.label; if ~isempty(job.detail), text=[text ' · ' job.detail]; end
            obj.UI.guideRow.ColumnWidth={220,'1x',48,110,170};
            obj.UI.guide.Text=text; obj.UI.guide.FontColor=obj.Ink; obj.UI.guide.FontWeight='normal';
            obj.UI.elapsed.Text=['已用 ' AWGScopeApp.timeText(elapsed)];
            if job.totalWords>0
                fraction=min(1,max(0,job.doneWords/job.totalWords));
                obj.UI.bar.ColumnWidth={0,round(220*fraction),'1x'};
                obj.UI.percent.Text=sprintf('%d%%',floor(100*fraction));
                obj.UI.remaining.Text=obj.remainingText(job,elapsed,fraction);
            else
                % No measurable total: show activity, not a made-up percentage.
                obj.Marquee=mod(obj.Marquee+1,11);
                obj.UI.bar.ColumnWidth={17*obj.Marquee,50,'1x'};
                obj.UI.percent.Text='';
                last=NaN;
                if strcmp(obj.Timing.server,obj.endpoint)
                    if strcmp(job.label,'初始化板卡'), last=obj.Timing.initialize_s;
                    elseif strcmp(job.action,'connect'), last=obj.Timing.connect_s; end
                end
                if isfinite(last), obj.UI.remaining.Text=['上次用时 ' AWGScopeApp.timeText(last)];
                else, obj.UI.remaining.Text=''; end
            end
        end
        function text=remainingText(obj,job,elapsed,fraction)
            % From this task's own speed once it has run long enough; before
            % that from the last transfer to the same server. Without either
            % basis, say so instead of showing a guess.
            text='预计剩余 估算中';
            if fraction>=1
                text='即将完成';
            elseif elapsed>=5 && job.doneWords>=64
                text=['预计剩余 ' AWGScopeApp.timeText(elapsed*(1-fraction)/fraction)];
            elseif isfinite(obj.Timing.ms_per_word) && strcmp(obj.Timing.server,obj.endpoint)
                text=['预计剩余 约 ' AWGScopeApp.timeText((job.totalWords-job.doneWords)*obj.Timing.ms_per_word/1000)];
            end
        end
        function refreshProgress(obj)
            % The progress display is advisory: an error in it must not end,
            % or appear to end, the board task.
            if isempty(obj.Job), return; end
            try
                if obj.Busy, obj.readProgress; end
                obj.showProgress;
            catch err
                if ~obj.DisplayWarned
                    obj.DisplayWarned=true; obj.log(['进度显示出错，不影响后台任务：' err.message]);
                end
            end
        end
        function readProgress(obj)
            % Refresh the running task from the files the tools write.
            switch obj.Job.action
                case 'initialize'
                    obj.readStage(obj.InitLog,{'LMK clocks are stable','RF initializer is running'}, ...
                        {'第 1/4 步：复位 PS，准备时钟','第 2/4 步：下载 bit','第 2/4 步：下载 bit'});
                case 'connect'
                    if ~obj.InitFlow
                        obj.readStage(fullfile(obj.Bridge.Session,'backend.log'), ...
                            {'40GbE connected'}, ...
                            {'连接 40GbE 并核对固件','读取板卡状态'});
                    end
                case {'load','run','capture'}
                    obj.readTransfer;
            end
        end
        function readStage(obj,path,markers,stages)
            % The stage of a connection or initialization comes from the
            % tool's own log; read it at most once per second.
            if ~isempty(obj.StageRead) && toc(obj.StageRead)<1, return; end
            obj.StageRead=tic;
            stage=stages{1};
            try
                text=fileread(path);
                for k=1:numel(markers)
                    if contains(text,markers{k}), stage=stages{k+1}; end
                end
            catch
                % The log may not exist yet, or be locked for a moment.
            end
            obj.Job.detail=stage;
        end
        function readTransfer(obj)
            path=fullfile(obj.Bridge.Session,'progress.txt');
            if ~isfile(path), return; end
            try
                p=AWGBridge.readFields(path);
            catch
                % The bridge atomically replaces this advisory status file.
                % Skip a transient Windows sharing violation and retry next tick.
                return
            end
            job=obj.Job;
            if ~all(isfield(p,{'phase','channel','done','total'})), return; end
            % The file may still hold the last report of the previous task.
            if ~isfield(p,'request') || ~strcmp(p.request,job.request), return; end
            done=str2double(p.done); total=str2double(p.total);
            if ~(isfinite(done) && isfinite(total)), return; end
            perChannel=job.loadWords;
            loadTotal=numel(job.loadChannels)*perChannel;
            switch p.phase
                case {'write','verify'}
                    index=find(job.loadChannels==str2double(p.channel),1);
                    if isempty(index), return; end
                    words=(index-1)*perChannel+done/2; name='写入';
                    if strcmp(p.phase,'verify'), name='CRC 校验'; end
                    detail=sprintf('%s DAC%s · %d / %d 点',name,p.channel,done,total);
                    if numel(job.loadChannels)>1
                        detail=sprintf('%s（第 %d/%d 路）',detail,index,numel(job.loadChannels));
                    end
                case 'capture'
                    % The board reports how many samples it really captured.
                    job.captureSamples=total;
                    channels=find(bitget(uint8(job.captureMask),1:8))-1;
                    index=find(channels==str2double(p.channel),1);
                    if isempty(index), return; end
                    words=loadTotal+((index-1)*total+done)/2;
                    detail=sprintf('回读 ADC%s · %d / %d 点',p.channel,done,total);
                    if job.captureChannels>1, detail=sprintf('%s（%d 路）',detail,job.captureChannels); end
                otherwise
                    return
            end
            job.totalWords=loadTotal+job.captureChannels*job.captureSamples/2;
            job.detail=detail;
            if words>job.doneWords
                % Progress proves the backend is alive: restart its timeout.
                job.doneWords=words; obj.Bridge.touch;
            end
            obj.Job=job;
        end
        function beginJob(obj,action,plan)
            % Describe the task that just started, for the state and the
            % progress display. Count payload sample pairs; FPGA CRC does
            % not read the waveform back and adds no payload bytes.
            job=struct('action',action,'label',action,'detail','','started',tic,'request','', ...
                'loadChannels',[],'loadWords',0,'verify',true,'captureChannels',0,'captureMask',0,'captureSamples',0, ...
                'doneWords',0,'totalWords',0);
            if nargin>=3
                names=fieldnames(plan);
                for k=1:numel(names), job.(names{k})=plan.(names{k}); end
            end
            [~,job.request]=fileparts(obj.Bridge.Pending);
            job.totalWords=numel(job.loadChannels)*job.loadWords+ ...
                job.captureChannels*job.captureSamples/2;
            switch action
                case 'initialize'
                    job.label='初始化板卡'; job.detail='第 1/4 步：复位 PS，准备时钟';
                case 'connect'
                    job.label='连接板卡'; job.detail='核对 40GbE 协议和固件版本';
                    if obj.InitFlow, job.label='初始化板卡'; job.detail='第 3/4 步：连接板卡'; end
                case 'wait_ready'
                    % Only the connection that follows an initialization waits.
                    job.label='初始化板卡'; job.detail='第 4/4 步：等待 RF 就绪（最长 2 分钟）';
                case 'load'
                    job.label='下载并校验'; if ~job.verify, job.label='下载（不校验）'; end
                case 'run', job.label='下载并采集';
                case 'capture', job.label='采集并回读';
                case 'start', job.label='开始循环播放';
                case 'stop', job.label='停止播放';
                case 'clear', job.label='清除故障';
                case 'status', job.label='刷新状态';
                case 'disconnect', job.label='断开连接';
            end
            % The four initialization steps share one clock.
            if obj.InitFlow && strcmp(job.label,'初始化板卡'), job.started=obj.InitStarted; end
            obj.Job=job; obj.Marquee=0; obj.StageRead=[];
        end
        function finishJob(obj)
            % Log what finished and how long it took; keep the measured
            % transfer speed for later estimates.
            job=obj.Job; obj.Job=[];
            if isempty(job), return; end
            elapsed=toc(job.started);
            switch job.action
                case 'connect'
                    obj.recordTiming('connect_s',elapsed);
                    obj.log(['完成：' job.label '，用时 ' AWGScopeApp.timeText(elapsed) '。']);
                case {'load','run','capture'}
                    words=numel(job.loadChannels)*job.loadWords+ ...
                        job.captureChannels*job.captureSamples/2;
                    note='';
                    if words>=512
                        obj.recordTiming('ms_per_word',1000*elapsed/words);
                        note=sprintf('，有效样点数据 %.2f MiB，含控制与文件处理 %.2f MiB/s',4*words/2^20,4*words/2^20/max(elapsed,eps));
                    end
                    obj.log(['完成：' job.label '，用时 ' AWGScopeApp.timeText(elapsed) note '。']);
                otherwise
                    obj.log(['完成：' job.label '。']);
            end
        end
        function recordTiming(obj,name,value)
            % Measurements belong to one UDP endpoint and packet size.
            server=obj.endpoint;
            if ~strcmp(obj.Timing.server,server)
                obj.Timing=struct('server',server,'ms_per_word',NaN,'connect_s',NaN,'initialize_s',NaN);
            end
            obj.Timing.(name)=value;
            % Best effort: the history only improves the estimates.
            AWGScopeApp.writeText(fullfile(obj.DataRoot,'timing.json'),jsonencode(obj.Timing),2,0.1);
        end
        function loadTiming(obj)
            path=fullfile(obj.DataRoot,'timing.json');
            if ~isfile(path), return; end
            try
                data=jsondecode(fileread(path));
                if isfield(data,'server') && ischar(data.server), obj.Timing.server=data.server; end
                for name={'ms_per_word','connect_s','initialize_s'}
                    if isfield(data,name{1})
                        value=data.(name{1});
                        if isnumeric(value) && isscalar(value) && isfinite(value) && value>0
                            obj.Timing.(name{1})=double(value);
                        end
                    end
                end
            catch
                % An unreadable history only means no estimate before the first transfer.
            end
        end
        function clearHint(obj)
            obj.LastHint=''; obj.HintStep=0; obj.HintLocal=false;
        end
        function value=backgroundPoll(obj)
            % True while the only pending request is the ready poll that
            % follows initialization (or a status refresh during that wait).
            value=obj.Busy && ~isempty(obj.WaitReady) && isempty(obj.InitProcess) && ...
                strcmp(obj.Bridge.PendingAction,'status');
        end
        function message=backendDetail(obj,message,action)
            % Vivado returns only "... failed due to earlier errors" to Tcl and
            % prints the cause in its log. Quote that line for the user.
            if ~contains(message,'failed due to earlier errors'), return; end
            try
                % A failed connection ends the backend; let it finish its log.
                if strcmp(action,'connect') && ~isempty(obj.Bridge.Process)
                    obj.Bridge.Process.waitFor(3,java.util.concurrent.TimeUnit.SECONDS);
                end
                lines=regexp(fileread(fullfile(obj.Bridge.Session,'backend.log')),'\r?\n','split');
                keep=startsWith(lines,'ERROR: [') & ~contains(lines,'failed due to earlier errors');
                if any(keep), message=[strtrim(lines{find(keep,1,'last')}) ' ' message]; end
            catch
                % Keep the original message when the log cannot be read.
            end
        end
        function showSettings(obj)
            obj.UI.tabs.SelectedTab=obj.UI.configTab;
        end
        function verifyChanged(obj)
            if obj.UI.verify.Value
                obj.log('CRC 校验：开。每路下载后核对 FPGA CRC；默认开启。');
            else
                obj.log('CRC 校验：关。本次下载不校验数据完整性，仅调试使用。');
            end
            obj.updateControls;
        end
        function readLengthChanged(obj)
            requested=obj.UI.readLength.Value; samples=AWGScopeApp.roundReadLength(requested);
            obj.UI.readLength.Value=samples;
            if samples~=requested, obj.log(sprintf('回读点数按24点一组取整：%d → %d。',requested,samples)); end
            obj.updateControls;
        end
        function log(obj,message)
            obj.Messages{end+1}=[datestr(now,'HH:MM:SS') '  ' message];
            if numel(obj.Messages)>160, obj.Messages=obj.Messages(end-159:end); end
            if isfield(obj.UI,'log') && isvalid(obj.UI.log), obj.UI.log.Value=obj.Messages; scroll(obj.UI.log,'bottom'); end
        end
        function guard(obj,callback)
            % Button and field callbacks. An error here is a local one: it does
            % not prove that a board task failed (see fail).
            try
                callback();
                % A successful action answers the message left by a rejected input.
                if obj.HintLocal, obj.clearHint; obj.updateControls; end
            catch err
                obj.fail(err,false);
            end
        end
        function timerError(obj,event)
            try, obj.log(['界面轮询异常：' event.Data.Message]); catch, end
        end
        function closeRequest(obj)
            if obj.Busy
                answer=uiconfirm(obj.Figure,'后台任务尚未结束。关闭会中断后台传输，DAC状态需重新检查。', ...
                    '关闭上位机','Options',{'继续等待','关闭并释放连接'},'DefaultOption',1,'CancelOption',1);
                if ~strcmp(answer,'关闭并释放连接'), return; end
            elseif obj.Connected
                answer=uiconfirm(obj.Figure,'关闭上位机不会停止DAC。建议先点击“停止播放”。', ...
                    '关闭上位机','Options',{'返回界面','关闭并释放连接'},'DefaultOption',1,'CancelOption',1);
                if ~strcmp(answer,'关闭并释放连接'), return; end
            end
            delete(obj);
        end
        function pollUART(obj)
            if isempty(obj.UartSocket), return; end
            try
                if ~obj.UartSocket.isConnected || obj.UartSocket.isClosed
                    obj.closeUART; obj.log('UART TCP连接已关闭。'); obj.updateControls; return
                end
                available=obj.UartInput.available(); count=min(double(available),8192);
                if count<=0, return; end
                bytes=zeros(1,count,'uint8'); actual=0;
                for k=1:count
                    value=obj.UartInput.read(); if value<0, break; end
                    actual=actual+1; bytes(actual)=uint8(value);
                end
                if actual>0, obj.consumeUARTBytes(bytes(1:actual)); end
            catch err
                obj.closeUART;
                obj.log(['UART TCP读取失败，40GbE 任务不受影响：' err.message]);
                obj.updateControls;
            end
        end
        function guardUART(obj,callback)
            try, callback(); catch err
                obj.log(['UART TCP连接失败（不影响40GbE）：' err.message]);
                obj.closeUART; obj.updateControls;
            end
        end
        function closeUART(obj)
            try, if ~isempty(obj.UartInput), obj.UartInput.close(); end, catch, end
            try, if ~isempty(obj.UartSocket), obj.UartSocket.close(); end, catch, end
            obj.UartInput=[]; obj.UartSocket=[]; obj.UartBuffer=uint8([]);
        end
    end
    methods (Static)
        function value=findTool(name)
            value='';
            if strcmp(name,'python')
                candidates={getenv('AWG_PYTHON')};
                [code,output]=system('where python.exe 2>nul');
                if code==0, candidates=[candidates cellstr(splitlines(strtrim(output))).']; end
                patterns={fullfile(getenv('LOCALAPPDATA'),'Programs','Python','Python*','python.exe'),'C:\Python*\python.exe'};
            else
                candidates={fullfile(getenv('AWG_XILINX_ROOT'),'Vitis','bin','xsct.bat')};
                patterns={};
                for drive='CDEFG'
                    patterns{end+1}=[drive ':\AMDDesignTools\*\Vitis\bin\xsct.bat'];
                    patterns{end+1}=[drive ':\Xilinx\*\Vitis\bin\xsct.bat'];
                end
            end
            for k=1:numel(patterns)
                files=dir(patterns{k});
                for j=numel(files):-1:1, candidates{end+1}=fullfile(files(j).folder,files(j).name); end
            end
            for k=1:numel(candidates)
                if isfile(candidates{k}) && ~contains(candidates{k},'WindowsApps')
                    value=candidates{k}; return
                end
            end
        end
        function value=fieldOr(data,name,fallback)
            value=fallback;
            if isfield(data,name), value=data.(name); end
        end
        function [wave,fs,units,label]=readWave(path,variable)
            if nargin<2, variable=''; end
            fs=9.8e9; units='normalized'; label=path;
            [~,~,ext]=fileparts(path);
            if strcmpi(ext,'.mat')
                data=load(path); names=fieldnames(data); candidates={};
                for k=1:numel(names)
                    v=data.(names{k});
                    if isnumeric(v) && ismatrix(v) && numel(v)>=4 && (isvector(v) || size(v,2)<=8)
                        candidates{end+1}=names{k}; %#ok<AGROW>
                    end
                end
                paired=isfield(data,'I') && isfield(data,'Q') && isnumeric(data.I) && isnumeric(data.Q) && isequal(size(data.I),size(data.Q));
                if paired, candidates{end+1}='[I+jQ]'; end
                if isempty(variable)
                    if ismember('waveform',candidates), variable='waveform';
                    elseif ismember('samples',candidates), variable='samples';
                    elseif ismember('x',candidates), variable='x';
                    elseif ismember('iq',candidates), variable='iq';
                    elseif numel(candidates)==1, variable=candidates{1};
                    else
                        assert(~isempty(candidates),'MAT中没有可用的波形矩阵。');
                        [index,ok]=listdlg('ListString',candidates,'SelectionMode','single','PromptString','选择波形变量（列对应通道）');
                        assert(ok,'已取消波形导入。'); variable=candidates{index};
                    end
                end
                assert(ismember(variable,candidates),'指定变量不是可用波形。');
                if strcmp(variable,'[I+jQ]'), wave=complex(double(data.I),double(data.Q));
                else, wave=data.(variable); end
                if isinteger(wave) || (isfield(data,'I') && isa(data.I,'int16') && strcmp(variable,'iq')) || strcmp(variable,'[I+jQ]') && isinteger(data.I)
                    units='codes';
                end
                if isfield(data,'Fs'), fs=double(data.Fs);
                elseif isfield(data,'fs'), fs=double(data.fs); end
                label=[path ' :: ' variable];
            else
                assert(any(strcmpi(ext,{'.csv','.txt'})),'仅支持MAT或数值CSV/TXT。');
                raw=readmatrix(path); assert(~isempty(raw) && all(isfinite(raw(:))),'CSV须为纯数值，不得包含空值。');
                wave=raw; label=[path ' :: 实数DAC通道'];
                sidecar=[path(1:end-4) '.json'];
                if isfile(sidecar)
                    meta=jsondecode(fileread(sidecar));
                    if isfield(meta,'fs_hz'), fs=double(meta.fs_hz);
                    elseif isfield(meta,'Fs'), fs=double(meta.Fs); end
                end
            end
            validateattributes(fs,{'numeric'},{'scalar','finite','positive'});
        end
        function span(component,row)
            component.Layout.Row=row; component.Layout.Column=[1 2];
        end
        function place(component,row,column)
            component.Layout.Row=row; component.Layout.Column=column;
        end
        function value=on(condition)
            if condition, value='on'; else, value='off'; end
        end
        function info=explain(message,local)
            % Say what a failure means and what to do next. local=true for an
            % input rejected by this application, whose message is already an
            % instruction; otherwise the message comes from the board task.
            %   text      explanation for the alert and the log; empty when the
            %             message already reads as an instruction
            %   hint      one line for the guide row
            %   step      step to emphasize: 1 initialize, 2 connect, 0 none
            %   settings  true when the fix is on the connection settings tab
            info=struct('text','','hint','','step',0,'settings',false);
            first=regexp(message,'^[^\r\n]*','match','once');
            if numel(first)>90, first=[first(1:90) '…']; end
            info.hint=['上一步没有完成：' first];
            if nargin>1 && local, info.hint=first; end
            if contains(message,'无法保存连接设置')
                info.hint='连接设置没有保存：文件正被其他程序占用，稍后再点一次“保存连接设置”。';
                return
            end
            if contains(message,'timed out') || contains(message,'timeout')
                info.text='40GbE 通信或采集超时。检查光口链路、IPv4、MTU、板卡初始化及后台日志；不要在未确认状态时直接重复下载。';
                info.hint='通信超时：检查光口链路、IP 和初始化状态。'; info.step=2;
            elseif contains(message,'firmware mismatch')
                info.text='板卡与本上位机不匹配，需要完整的 D3C/F1 V1.2 硬件包。';
                info.hint='固件不匹配：核对 D3C/F1 硬件包。'; info.step=1;
            elseif contains(message,'PS not ready')
                info.hint='RF 未就绪：先初始化板卡。'; info.step=1;
            elseif contains(message,'CRC mismatch')
                info.hint='下载 CRC 校验失败，本次波形未确认可用；检查链路后重试。';
            elseif contains(message,'Python') || contains(message,'backend exited')
                info.hint='后台未启动：检查 Python 路径和会话日志。'; info.settings=true; info.step=2;
            end
        end
        function text=shortLabel(label)
            % Show the file name of an imported waveform; the caller keeps the
            % full path for the tooltip.
            text=label;
            if ~isempty(regexp(label,'^([A-Za-z]:[\\/]|\\\\)','once'))
                name=regexp(label,'[^\\/]+$','match','once');
                if ~isempty(name), text=name; end
            end
        end
        function samples=roundReadLength(value)
            % The ADC RAM captures groups of 24 samples.
            samples=min(65520,max(24,24*ceil(value/24)));
        end
        function text=timeText(seconds)
            seconds=max(0,round(seconds));
            if seconds<60
                text=sprintf('%d 秒',seconds);
            elseif seconds<3600
                text=sprintf('%d 分 %02d 秒',floor(seconds/60),mod(seconds,60));
            else
                text=sprintf('%d 小时 %02d 分',floor(seconds/3600),floor(mod(seconds,3600)/60));
            end
        end
        function [saved,changed]=writeText(path,text,attempts,waitSeconds)
            % Write a small UTF-8 text file in a folder that may be synchronized
            % or scanned by another program: skip the write when the content is
            % unchanged, and retry a file that is briefly locked.
            saved=true; changed=false;
            if isfile(path)
                try
                    if strcmp(fileread(path,'Encoding','UTF-8'),text), return; end
                catch
                    % Unreadable for now; the write below decides.
                end
            end
            for attempt=1:attempts
                f=fopen(path,'wt','n','UTF-8');
                if f>=0
                    cleanup=onCleanup(@() fclose(f));
                    fprintf(f,'%s',text); clear cleanup
                    changed=true; return
                end
                % Do not yield to callbacks while the caller is mid-action.
                if attempt<attempts, java.lang.Thread.sleep(round(1000*waitSeconds)); end
            end
            saved=false;
        end
    end
end
