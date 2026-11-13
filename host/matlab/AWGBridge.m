classdef AWGBridge < handle
    % One persistent Python UDP process; atomic file IPC keeps the MATLAB UI live.
    properties (SetAccess=private)
        Root
        DataRoot
        Session = ''
        Process = []
        Pending = ''
        PendingAction = ''
        Started
        Counter = 0
        Timeout = 120
    end
    methods
        function obj=AWGBridge(root,dataRoot)
            obj.Root=root;
            if nargin<2, dataRoot=fullfile(root,'app_data'); end
            obj.DataRoot=dataRoot;
        end
        function start(obj,cfg,entryScript)
            assert(isempty(obj.Process),'A bridge process is already running.');
            assert(isfile(cfg.python),'Python executable not found: %s',cfg.python);
            obj.Session=tempname(fullfile(obj.DataRoot,'sessions')); mkdir(obj.Session);
            AWGBridge.writeFields(fullfile(obj.Session,'config.txt'),struct( ...
                'fpga_ip',cfg.fpga_ip,'port',cfg.port,'words_per_packet',cfg.words_per_packet, ...
                'remote_host',cfg.remote_host,'remote_port',cfg.remote_port));
            obj.heartbeat;
            if nargin<3, entryScript=fullfile(obj.Root,'tools','awg_eth','gui_bridge.py'); end
            if strcmp(cfg.transport,'remote'), obj.Timeout=900; else, obj.Timeout=120; end
            obj.Process=AWGBridge.launch(cfg.python,{'-X','utf8',entryScript,obj.Session}, ...
                fullfile(obj.Session,'backend.log'),obj.Session);
            obj.Pending=fullfile(obj.Session,'hello.res'); obj.PendingAction='connect'; obj.Started=tic;
        end
        function send(obj,action,fields)
            if nargin<3, fields=struct; end
            assert(~isempty(obj.Process) && isempty(obj.Pending),'Bridge is disconnected or busy.');
            assert(obj.Process.isAlive,'40GbE backend has exited.');
            obj.Counter=obj.Counter+1;
            stem=fullfile(obj.Session,sprintf('%08d',obj.Counter));
            fields.action=action;
            AWGBridge.writeFields([stem '.req'],fields);
            obj.Pending=[stem '.res']; obj.PendingAction=action; obj.Started=tic;
        end
        function [ready,response,action]=poll(obj)
            ready=false; response=struct; action=obj.PendingAction;
            if isempty(obj.Process), return; end
            obj.heartbeat;
            if ~isempty(obj.Pending) && isfile(obj.Pending)
                response=AWGBridge.readFields(obj.Pending);
                obj.Pending=''; obj.PendingAction=''; ready=true;
            elseif ~obj.Process.isAlive
                ready=true; response=struct('ok','0','message',['40GbE backend exited. Log: ' fullfile(obj.Session,'backend.log')]);
                obj.Pending=''; obj.PendingAction='';
            elseif ~isempty(obj.Pending)
                limit=obj.Timeout; if strcmp(action,'connect'), limit=30; end
                if toc(obj.Started)>limit
                    ready=true; response=struct('ok','0','message','Backend timed out; connection released. Hardware state must be checked.');
                    obj.terminate;
                end
            end
        end
        function touch(obj)
            % A long transfer that still reports progress is not a stalled
            % backend: restart the response timeout from the last progress.
            if ~isempty(obj.Pending), obj.Started=tic; end
        end
        function heartbeat(obj)
            if isempty(obj.Session), return; end
            f=fopen(fullfile(obj.Session,'heartbeat'),'w'); if f>=0, fclose(f); end
        end
        function terminate(obj)
            AWGBridge.killProcess(obj.Process); obj.Process=[]; obj.Pending=''; obj.PendingAction='';
        end
        function delete(obj), obj.terminate; end
    end
    methods (Static)
        function writeFields(path,fields)
            f=fopen([path '.tmp'],'wt'); assert(f>=0,'Cannot create IPC file.');
            cleanup=onCleanup(@() fclose(f));
            names=fieldnames(fields);
            for k=1:numel(names)
                value=fields.(names{k}); if isnumeric(value), value=num2str(value,17); end
                hex=reshape(dec2hex(unicode2native(char(value),'UTF-8'),2).',1,[]);
                fprintf(f,'%s %s\n',names{k},hex);
            end
            clear cleanup
            [ok,msg]=movefile([path '.tmp'],path,'f'); assert(ok,'%s',msg);
        end
        function fields=readFields(path)
            lines=splitlines(string(fileread(path))); fields=struct;
            for k=1:numel(lines)
                line=char(lines(k)); if isempty(strtrim(line)), continue; end
                token=regexp(line,'^([a-z_]+) ([0-9a-fA-F]*)\r?$','tokens','once');
                assert(~isempty(token) && mod(numel(token{2}),2)==0,'Malformed IPC reply.');
                bytes=uint8(hex2dec(reshape(token{2},2,[]).'));
                fields.(token{1})=native2unicode(bytes.','UTF-8');
            end
        end
        function process=launch(executable,args,logPath,workDir)
            % Only trusted tool/script/session paths enter a shell command.
            % Imported filenames are transported as hex data through IPC.
            assert(ispc,'This hardware launcher currently supports Windows.');
            for p=[{executable},args]
                assert(isempty(regexp(char(p{1}),'["%%!&|<>^\r\n]','once')), ...
                    'Tool/workspace path contains unsupported shell characters.');
            end
            quoted=cellfun(@(s) ['"' char(s) '"'],[{executable},args],'UniformOutput',false);
            command=['"' strjoin(quoted,' ') '"'];
            list=java.util.ArrayList;
            for item={'cmd.exe','/d','/s','/c',command}, list.add(java.lang.String(item{1})); end
            builder=java.lang.ProcessBuilder(list);
            builder.directory(java.io.File(workDir));
            builder.redirectErrorStream(true); builder.redirectOutput(java.io.File(logPath));
            process=builder.start;
        end
        function killProcess(process)
            if isempty(process), return; end
            try
                descendants=process.descendants.iterator;
                children={}; while descendants.hasNext, children{end+1}=descendants.next; end %#ok<AGROW>
                for k=numel(children):-1:1, children{k}.destroyForcibly; end
                process.destroyForcibly;
            catch
                try, process.destroy; catch, end
            end
        end
    end
end
