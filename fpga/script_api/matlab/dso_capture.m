function [data, info] = dso_capture(ip, options)
% DSO_CAPTURE  触发一次 ADC 采集并读回数据（示波器单次采集）
%
%   [data, info] = dso_capture(ip, Name=Value ...)
%
%   本函数自带 UDP 协议实现（Java DatagramSocket），不调用其他自定义函数。
%
%   输入：
%     ip          板卡 IP，例如 '192.168.42.2'
%   可选参数（Name=Value）：
%     Channels        要读回的 ADC 通道（0..7，从 0 开始），默认 0；8 个通道总是同时采集、时间对齐
%     Samples         每通道采集点数，24..65520 且为 24 的倍数，默认 65520
%     Trigger         "manual"：立即采集（默认）；
%                     "start"：AWG 起播同步（先 Stop，再在 Start 的同一时刻开始采集，采完 AWG 保持播放）
%     Port            UDP 端口，默认 9100
%     WordsPerPacket  每包字数，1..2048，默认 2048（需要巨型帧）；没开巨型帧用 256
%     Timeout         每个请求的超时（秒），默认 0.2
%     Retries         超时重试次数，默认 5
%     CaptureTimeout  等待采集完成的最长时间（秒），默认 10
%
%   输出：
%     data        int16 矩阵（通道数 × 点数），第 i 行是 Channels(i) 的波形；
%                 数值 = 14 bit ADC 码左移 2 位（满量程 32768）
%     info        结构体：fs_hz 采样率 5e9、channels、samples 实际点数、
%                 cap_tx_word 采集开始时 AWG 播放位置（32 点为单位）、seconds 总耗时、read_seconds 纯读回耗时
%
%   示例：
%     [d, info] = dso_capture('192.168.42.2', Channels=[0 1], Trigger="start");
%     t = (0:info.samples-1) / info.fs_hz;  plot(t, double(d(1,:)) / 32768);

arguments
    ip {mustBeTextScalar}
    options.Channels double = 0
    options.Samples (1,1) double = 65520
    options.Trigger {mustBeMember(options.Trigger, ["manual", "start"])} = "manual"
    options.Port (1,1) double = 9100
    options.WordsPerPacket (1,1) double = 2048
    options.Timeout (1,1) double = 0.2
    options.Retries (1,1) double = 5
    options.CaptureTimeout (1,1) double = 10
end

t0 = tic;
chans = reshape(options.Channels, 1, []);
if isempty(chans) || any(chans < 0 | chans > 7 | chans ~= round(chans))
    error('dso_capture:channels', 'Channels 必须是 0..7 的通道号');
end
samples = options.Samples;
if samples < 24 || samples > 65520 || mod(samples, 24) ~= 0
    error('dso_capture:samples', 'Samples 必须是 24..65520 且为 24 的倍数，收到 %d', samples);
end
wpp = round(options.WordsPerPacket);
if wpp < 1 || wpp > 2048
    error('dso_capture:wpp', 'WordsPerPacket 必须是 1..2048');
end
isStart = options.Trigger == "start";

BASE = 0x90200000;
REG_STATUS = BASE + uint32(0x04);       % bit0 running、bit1 busy、bit5:4 命令结果
REG_COMMAND = BASE + uint32(0x08);      % 1 stop、2 start、8 arm、32 取消采集
REG_CAP_STATUS = BASE + uint32(0x28);   % bit0 busy、bit1 done、bit2 armed（等待触发）
REG_CAP_SAMPLES = BASE + uint32(0x2C);  % 实际采集点数
REG_CAP_RD_CH = BASE + uint32(0x40);    % 选择读回通道（写入即把读指针归零）
REG_CAP_RD_PTR = BASE + uint32(0x44);   % 读指针（样点对索引）
REG_CAP_RD_DATA = BASE + uint32(0x48);  % 读数据端口（NOINC，每读一个字指针 +1）
REG_CAP_CTRL = BASE + uint32(0x4C);     % bit0 触发方式、[27:16] 采集长度（24 点为单位）
REG_CAP_TX_WORD = BASE + uint32(0x50);  % 采集开始时 AWG 的播放位置

% ---------------- 操作队列 ----------------
% op='cmd'   复合：写 COMMAND + 轮询 STATUS 直到完成
% op='chunk' 复合：写读指针 + 读一段数据。读数据端口每读一次指针会前进，所以不能简单重发；
%            超时时整个 chunk（先设指针再读）重新执行，保证数据位置正确
% tag：'pre' 检查残留的 armed；'run' 检查是否在播放；'poll' 命令完成；'cap' 等采集完成；
%      'samples' 读到点数后生成读回操作；'txword' 播放位置；'data' 存数据
ops = {struct('op', 'read', 'addr', REG_CAP_STATUS, 'count', 1, 'tag', 'pre')};
if isStart
    ops{end+1} = struct('op', 'read', 'addr', REG_STATUS, 'count', 1, 'tag', 'run');
end
ops{end+1} = struct('op', 'write', 'addr', REG_CAP_CTRL, 'tag', '', ...
                    'data', uint32(bitor(bitshift(samples / 24, 16), double(isStart))));
ops{end+1} = struct('op', 'cmd', 'value', 8);                     % arm
if isStart
    ops{end+1} = struct('op', 'cmd', 'value', 2);                 % Start：起播即触发
end
ops{end+1} = struct('op', 'read', 'addr', REG_CAP_STATUS, 'count', 1, 'tag', 'cap', ...
                    'deadline', toc(t0) + options.CaptureTimeout);
ops{end+1} = struct('op', 'read', 'addr', REG_CAP_SAMPLES, 'count', 1, 'tag', 'samples');

data = zeros(numel(chans), 0, 'int16');
captured = 0;
capTxWord = 0;
tRead0 = [];
statusText = {'AXI 错误（寄存器拒绝）', '请求格式错误', 'AXI 超时', 'FPGA 忙'};

sock = java.net.DatagramSocket();
sock.setReceiveBufferSize(4 * 1024 * 1024);
inet = java.net.InetAddress.getByName(char(ip));
rxPkt = java.net.DatagramPacket(zeros(1, 9000, 'int8'), 9000);
seq = randi([0, 2^31]);
try
    while ~isempty(ops)
        op = ops{1};
        ops(1) = [];

        % ---- 复合操作展开 ----
        if strcmp(op.op, 'cmd')
            ops = [{struct('op', 'write', 'addr', REG_COMMAND, 'tag', '', 'data', uint32(op.value)), ...
                    struct('op', 'read', 'addr', REG_STATUS, 'count', 1, 'tag', 'poll', 'value', op.value, ...
                           'deadline', toc(t0) + 5)}, ops]; %#ok<AGROW>
            continue
        end
        if strcmp(op.op, 'chunk')
            ops = [{struct('op', 'write', 'addr', REG_CAP_RD_PTR, 'tag', '', 'data', uint32(op.offset)), ...
                    struct('op', 'read', 'addr', REG_CAP_RD_DATA, 'count', op.count, 'noinc', true, ...
                           'tag', 'data', 'row', op.row, 'offset', op.offset, 'chunk', op)}, ops]; %#ok<AGROW>
            continue
        end

        % ---- 组包、发送、等回复 ----
        seq = mod(seq + 1, 2^32);
        if strcmp(op.op, 'write')
            opcode = 2;
            count = numel(op.data);
            payload = typecast(uint32(reshape(op.data, 1, [])), 'uint8');
        else
            opcode = 1;
            count = op.count;
            payload = zeros(1, 0, 'uint8');
        end
        flags = 0;
        if isfield(op, 'noinc') && op.noinc
            flags = 1;
        end
        req = [typecast(uint16(0xA7E1), 'uint8'), uint8(1), uint8(opcode), typecast(uint32(seq), 'uint8'), ...
               typecast(uint32(op.addr), 'uint8'), typecast(uint16(count), 'uint8'), ...
               typecast(uint16(flags), 'uint8'), zeros(1, 8, 'uint8'), payload];
        txPkt = java.net.DatagramPacket(typecast(req, 'int8'), numel(req), inet, options.Port);
        if strcmp(op.tag, 'data')
            tries = 1;                                   % 读数据端口只发一次，超时后整个 chunk 重做
        else
            tries = options.Retries + 1;
        end
        reply = [];
        for attempt = 1:tries
            sock.send(txPkt);
            tEnd = toc(t0) + options.Timeout;
            while isempty(reply)
                remain = tEnd - toc(t0);
                if remain <= 0
                    break
                end
                sock.setSoTimeout(max(1, ceil(remain * 1000)));
                rxPkt.setLength(9000);
                try
                    sock.receive(rxPkt);
                catch
                    break
                end
                raw = typecast(int8(rxPkt.getData()), 'uint8');
                raw = reshape(raw(1:rxPkt.getLength()), 1, []);
                if numel(raw) < 24 || typecast(raw(1:2), 'uint16') ~= 0xA7E1 || raw(4) ~= bitor(opcode, 128) || ...
                        typecast(raw(5:8), 'uint32') ~= uint32(seq)
                    continue
                end
                rCount = double(typecast(raw(13:14), 'uint16'));
                reply = struct('status', double(typecast(raw(17:18), 'uint16')), ...
                               'err', double(typecast(raw(19:20), 'uint16')), 'count', rCount, ...
                               'data', raw(25:min(numel(raw), 24 + 4 * rCount)));
            end
            if ~isempty(reply)
                break
            end
        end
        if isempty(reply)
            if strcmp(op.tag, 'data')
                redo = op.chunk;
                redo.redo = redo.redo + 1;
                if redo.redo > options.Retries
                    error('dso_capture:timeout', '读回通道 %d 数据多次超时', chans(op.row));
                end
                ops = [{redo}, ops]; %#ok<AGROW>          % 重新"设指针 + 读"
                continue
            end
            error('dso_capture:timeout', '板卡 %s:%d 无回复（地址 0x%08X）；请检查光口连线、IP 和板卡是否已初始化', ...
                  char(ip), options.Port, op.addr);
        end
        if reply.status ~= 0
            error('dso_capture:fpga', 'FPGA 返回错误 status=%d（%s），地址 0x%08X，字索引 %d', ...
                  reply.status, statusText{min(reply.status, 4)}, op.addr, reply.err);
        end

        % ---- 结果处理 ----
        value = 0;
        if strcmp(op.op, 'read') && ~strcmp(op.tag, 'data') && numel(reply.data) >= 4
            value = double(typecast(reply.data(1:4), 'uint32'));
        end
        switch op.tag
            case 'pre'
                if bitand(value, 5)                       % 上次采集残留在 busy/armed：先取消
                    ops = [{struct('op', 'write', 'addr', REG_COMMAND, 'tag', '', 'data', uint32(32))}, ops]; %#ok<AGROW>
                end
            case 'run'
                if bitand(value, 1)                       % 起播同步需要先停止播放
                    ops = [{struct('op', 'cmd', 'value', 1)}, ops]; %#ok<AGROW>
                end
            case 'poll'
                if bitand(bitshift(value, -1), 1)
                    if toc(t0) > op.deadline
                        error('dso_capture:cmd', '命令 %d 超时未完成（STATUS=0x%X）', op.value, value);
                    end
                    ops = [{op}, ops]; %#ok<AGROW>
                elseif bitand(bitshift(value, -4), 3)
                    error('dso_capture:cmd', '命令 %d 被拒绝（STATUS=0x%X）', op.value, value);
                end
            case 'cap'
                if ~(bitand(value, 2) && ~bitand(value, 1))   % 还没 done
                    if toc(t0) > op.deadline
                        % 残留的 armed 状态会在下一次 dso_capture 开头（tag 'pre'）自动取消
                        error('dso_capture:capture', '采集超时（CAP_STATUS=0x%X）；起播同步时请确认已下载波形', value);
                    end
                    ops = [{op}, ops]; %#ok<AGROW>
                end
            case 'samples'
                captured = value;
                if captured < 24 || captured > 65520 || mod(captured, 24) ~= 0
                    error('dso_capture:samples', '采集点数异常：%d', captured);
                end
                data = zeros(numel(chans), captured, 'int16');
                pairs = captured / 2;
                ops{end+1} = struct('op', 'read', 'addr', REG_CAP_TX_WORD, 'count', 1, 'tag', 'txword'); %#ok<AGROW>
                for row = 1:numel(chans)
                    ops{end+1} = struct('op', 'write', 'addr', REG_CAP_RD_CH, 'tag', '', 'data', uint32(chans(row))); %#ok<AGROW>
                    for off = 0:wpp:pairs-1
                        ops{end+1} = struct('op', 'chunk', 'row', row, 'offset', off, ...
                                            'count', min(wpp, pairs - off), 'redo', 0); %#ok<AGROW>
                    end
                end
                tRead0 = toc(t0);
            case 'txword'
                capTxWord = value;
            case 'data'
                if reply.count ~= op.count
                    error('dso_capture:data', '读回字数不符：期望 %d，实际 %d', op.count, reply.count);
                end
                % 每个 32 bit 字 = 2 个 int16 样点，低 16 位是较早的样点
                block = typecast(reply.data, 'int16');
                first = 2 * op.offset + 1;
                data(op.row, first:first + numel(block) - 1) = block;
        end
    end
catch err
    sock.close();
    rethrow(err);
end
sock.close();

tTotal = toc(t0);
if isempty(tRead0)
    readSeconds = 0;
else
    readSeconds = tTotal - tRead0;
end
info = struct('fs_hz', 5e9, 'channels', chans, 'samples', captured, 'cap_tx_word', capTxWord, ...
              'seconds', tTotal, 'read_seconds', readSeconds);
end
