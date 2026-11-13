function result = awg_download(ip, waveforms, options)
% AWG_DOWNLOAD  经 40GbE 光口把波形下载到 AWG 指定通道，逐通道 CRC 校验，可选下载后自动播放
%
%   result = awg_download(ip, waveforms, Name=Value ...)
%
%   本函数自带完整的 UDP 协议实现（Java DatagramSocket，不需要任何工具箱），不调用其他自定义函数。
%
%   输入：
%     ip          板卡 IP，例如 '192.168.42.2'
%     waveforms   int16 波形：行向量（单通道）或矩阵（通道数 × 点数，第 i 行写到 Channels(i)）。
%                 长度必须是 32..131072 且为 32 的倍数，所有通道等长。用 awg_scale_waveform 生成即可。
%   可选参数（Name=Value）：
%     Channels        通道号（0..7，注意从 0 开始，对应面板上的 CH0..CH7），默认 0:行数-1
%     Run             true：下载并校验后立即播放（默认）；false：保持停止
%     Verify          true：每通道下载后由 FPGA 计算 CRC 并与本机比较，不一致自动重下（最多 3 次），默认 true
%     Port            UDP 端口，默认 9100
%     WordsPerPacket  每包字数（每字 = 2 个样点），1..2048，默认 2048（需要巨型帧）；没开巨型帧用 256
%     Timeout         每个请求等待回复的超时（秒），默认 0.2
%     Retries         超时重发次数，默认 5（FPGA 对写请求按序号去重，重发不会重复写入）
%
%   输出（结构体）：
%     channels 已下载通道、samples 每通道点数、mask 输出通道掩码、seconds 总耗时、
%     crc 各通道 CRC（十六进制字符串元胞）、crc_retries 重下次数、running 是否在播放
%
%   说明：下载前会先 Stop、清除故障、把输出掩码清 0；未下载的通道不会输出。
%
%   示例：
%     w = awg_generate_waveform('sine', FreqHz=100e6);
%     codes = awg_scale_waveform(w, AmpDbfs=-6);
%     r = awg_download('192.168.42.2', codes, Channels=0);

arguments
    ip {mustBeTextScalar}
    waveforms {mustBeNumeric}
    options.Channels double = []
    options.Run (1,1) logical = true
    options.Verify (1,1) logical = true
    options.Port (1,1) double = 9100
    options.WordsPerPacket (1,1) double = 2048
    options.Timeout (1,1) double = 0.2
    options.Retries (1,1) double = 5
end

t0 = tic;

% ---------------- 1. 输入检查 ----------------
if ~isa(waveforms, 'int16')
    error('awg_download:type', 'waveforms 必须是 int16 DAC 码；请先用 awg_scale_waveform 量化');
end
if isvector(waveforms)
    waveforms = reshape(waveforms, 1, []);            % 单通道统一成 1×N
end
[nch, n] = size(waveforms);
chans = options.Channels;
if isempty(chans)
    chans = 0:nch-1;
end
chans = reshape(chans, 1, []);
if numel(chans) ~= nch
    error('awg_download:channels', 'Channels 个数 (%d) 与波形行数 (%d) 不一致', numel(chans), nch);
end
if any(chans < 0 | chans > 7 | chans ~= round(chans)) || numel(unique(chans)) ~= nch
    error('awg_download:channels', 'Channels 必须是不重复的 0..7 整数');
end
if n < 32 || n > 131072 || mod(n, 32) ~= 0
    error('awg_download:length', '波形长度必须是 32..131072 且为 32 的倍数，收到 %d', n);
end
wpp = round(options.WordsPerPacket);
if wpp < 1 || wpp > 2048
    error('awg_download:wpp', 'WordsPerPacket 必须是 1..2048');
end

% ---------------- 2. 打包成 32 bit 字（低 16 位 = 较早的样点）并算期望 CRC ----------------
words = cell(1, nch);
crcExpect = zeros(1, nch);
for i = 1:nch
    w = typecast(waveforms(i, :), 'uint32');            % 每 2 个 int16 → 1 个 uint32（little-endian）
    words{i} = w;
    % FPGA 只保存每个样点的高 14 bit：CRC 前把每个 16 bit 的低 2 位清零（掩码 0xFFFCFFFC）
    masked = bitand(w, uint32(0xFFFCFFFC));
    crcObj = java.util.zip.CRC32();
    crcObj.update(typecast(typecast(masked, 'uint8'), 'int8'));
    crcExpect(i) = crcObj.getValue();
end
mask = sum(2 .^ chans);

% ---------------- 3. 寄存器地址（AXI4-Lite，基址 0x9020_0000）----------------
BASE = 0x90200000;
REG_STATUS = BASE + uint32(0x04);      % bit0 running、bit1 busy、bit2 ps_ready、bit3 fault、bit5:4 命令结果、bit8 crc_busy
REG_COMMAND = BASE + uint32(0x08);     % 1 stop、2 start、4 清故障、16 计算 CRC
REG_TX_LENGTH = BASE + uint32(0x0C);   % 播放长度（32 点为单位）
REG_TX_MASK = BASE + uint32(0x10);     % 输出通道掩码
REG_TX_WR_CH = BASE + uint32(0x30);    % 选择写入通道（写入即把写指针归零）
REG_TX_WR_DATA = BASE + uint32(0x38);  % 写数据端口（NOINC：同一地址连续写）
REG_TX_CRC = BASE + uint32(0x3C);      % 最近一次 CRC 结果

% ---------------- 4. 操作队列 ----------------
% 元胞里每一项是一个结构体：
%   op='write'/'read'  一个 UDP 请求
%   op='cmd'           复合：写 COMMAND + 轮询 STATUS 直到命令完成
%   op='channel'       复合：选通道 → 分包写数据 →（CRC 命令 → 读 CRC → 比较）
%   tag='poll' 轮询命令完成，tag='crc' 比较 CRC
ops = {};
ops{end+1} = struct('op', 'cmd', 'value', 1);                                  % Stop
ops{end+1} = struct('op', 'cmd', 'value', 4);                                  % 清除故障
ops{end+1} = struct('op', 'write', 'addr', REG_TX_MASK, 'data', uint32(0));    % 先关闭所有输出
ops{end+1} = struct('op', 'write', 'addr', REG_TX_LENGTH, 'data', uint32(n / 32));
for i = 1:nch
    ops{end+1} = struct('op', 'channel', 'idx', i, 'attempt', 0); %#ok<AGROW>
end
ops{end+1} = struct('op', 'write', 'addr', REG_TX_MASK, 'data', uint32(mask)); % 打开已下载的通道
if options.Run
    ops{end+1} = struct('op', 'cmd', 'value', 2);                              % Start
end

crcResult = cell(1, nch);
crcRetries = 0;
statusText = {'AXI 错误（寄存器拒绝，常见原因：播放中修改参数）', '请求格式错误', 'AXI 超时', 'FPGA 忙'};

% ---------------- 5. UDP 套接字 ----------------
sock = java.net.DatagramSocket();
sock.setReceiveBufferSize(4 * 1024 * 1024);
inet = java.net.InetAddress.getByName(char(ip));
rxPkt = java.net.DatagramPacket(zeros(1, 9000, 'int8'), 9000);
seq = randi([0, 2^31]);                                 % 请求序号，起始值随机
try
    while ~isempty(ops)
        op = ops{1};
        ops(1) = [];

        % ---- 5a. 复合操作：展开后放回队列最前面 ----
        if strcmp(op.op, 'cmd')
            ops = [{struct('op', 'write', 'addr', REG_COMMAND, 'data', uint32(op.value)), ...
                    struct('op', 'read', 'addr', REG_STATUS, 'count', 1, 'tag', 'poll', ...
                           'value', op.value, 'deadline', toc(t0) + 5)}, ops]; %#ok<AGROW>
            continue
        end
        if strcmp(op.op, 'channel')
            i = op.idx;
            w = words{i};
            ex = {struct('op', 'write', 'addr', REG_TX_WR_CH, 'data', uint32(chans(i)))};
            for off = 0:wpp:numel(w)-1
                ex{end+1} = struct('op', 'write', 'addr', REG_TX_WR_DATA, ...
                                   'data', w(off+1:min(off+wpp, numel(w))), 'noinc', true); %#ok<AGROW>
            end
            if options.Verify
                ex{end+1} = struct('op', 'cmd', 'value', 16); %#ok<AGROW>
                ex{end+1} = struct('op', 'read', 'addr', REG_TX_CRC, 'count', 1, 'tag', 'crc', ...
                                   'idx', i, 'attempt', op.attempt); %#ok<AGROW>
            end
            ops = [ex, ops]; %#ok<AGROW>
            continue
        end

        % ---- 5b. 组包（24 字节头 + 数据）、发送、等待对应回复；超时则重发同一序号 ----
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
        % 头：magic u16、version u8、opcode u8、seq u32、addr u32、count u16、flags u16、
        %     status u16、err_index u16、reserved u32（全部 little-endian）
        req = [typecast(uint16(0xA7E1), 'uint8'), uint8(1), uint8(opcode), typecast(uint32(seq), 'uint8'), ...
               typecast(uint32(op.addr), 'uint8'), typecast(uint16(count), 'uint8'), ...
               typecast(uint16(flags), 'uint8'), zeros(1, 8, 'uint8'), payload];
        txPkt = java.net.DatagramPacket(typecast(req, 'int8'), numel(req), inet, options.Port);
        reply = [];
        for attempt = 0:options.Retries
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
                    break                                    % 超时
                end
                raw = typecast(int8(rxPkt.getData()), 'uint8');
                raw = reshape(raw(1:rxPkt.getLength()), 1, []);
                if numel(raw) < 24
                    continue
                end
                if typecast(raw(1:2), 'uint16') ~= 0xA7E1 || raw(4) ~= bitor(opcode, 128) || ...
                        typecast(raw(5:8), 'uint32') ~= uint32(seq)
                    continue                                 % 不是本请求的回复（例如重发后迟到的回复）
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
            error('awg_download:timeout', '板卡 %s:%d 无回复（地址 0x%08X）；请检查光口连线、IP 和板卡是否已初始化', ...
                  char(ip), options.Port, op.addr);
        end
        if reply.status ~= 0
            error('awg_download:fpga', 'FPGA 返回错误 status=%d（%s），地址 0x%08X，出错字索引 %d', ...
                  reply.status, statusText{min(reply.status, 4)}, op.addr, reply.err);
        end

        % ---- 5c. 读回结果的处理 ----
        value = 0;
        if strcmp(op.op, 'read') && numel(reply.data) >= 4
            value = double(typecast(reply.data(1:4), 'uint32'));
        end
        if isfield(op, 'tag') && strcmp(op.tag, 'poll')
            busy = bitand(bitshift(value, -1), 1);
            crcBusy = bitand(bitshift(value, -8), 1);
            if busy || (op.value == 16 && crcBusy)
                if toc(t0) > op.deadline
                    error('awg_download:cmd', '命令 %d 超时未完成（STATUS=0x%X）', op.value, value);
                end
                ops = [{op}, ops]; %#ok<AGROW>               % 还没完成：继续轮询
                continue
            end
            if bitand(bitshift(value, -4), 3) ~= 0
                error('awg_download:cmd', '命令 %d 被 FPGA 拒绝（STATUS=0x%X）；Start 被拒通常是 PS 未就绪', ...
                      op.value, value);
            end
        elseif isfield(op, 'tag') && strcmp(op.tag, 'crc')
            i = op.idx;
            if value ~= crcExpect(i)
                if op.attempt >= 2
                    error('awg_download:crc', '通道 %d CRC 不一致：期望 0x%08X，实际 0x%08X（已重下 3 次）', ...
                          chans(i), crcExpect(i), value);
                end
                crcRetries = crcRetries + 1;
                ops = [{struct('op', 'channel', 'idx', i, 'attempt', op.attempt + 1)}, ops]; %#ok<AGROW>
            else
                crcResult{i} = sprintf('0x%08X', value);
            end
        end
    end
catch err
    sock.close();
    rethrow(err);
end
sock.close();

if ~options.Verify
    crcResult = {};
end
result = struct('channels', chans, 'samples', n, 'mask', mask, 'seconds', toc(t0), ...
                'crc', {crcResult}, 'crc_retries', crcRetries, 'running', options.Run);
end
