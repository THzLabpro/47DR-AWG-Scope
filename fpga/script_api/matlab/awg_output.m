function out = awg_output(ip, options)
% AWG_OUTPUT  AWG 输出 Run（开始循环播放）或 Stop（停止）
%
%   out = awg_output(ip, Name=Value ...)
%
%   本函数自带 UDP 协议实现，不调用其他自定义函数。
%
%   输入：
%     ip          板卡 IP，例如 '192.168.42.2'
%   可选参数（Name=Value）：
%     Run         true = Run（默认），false = Stop。已经在播放时再 Run 不会报错
%     Port        UDP 端口，默认 9100
%     Timeout     每个请求的超时（秒），默认 0.2
%     Retries     超时重发次数，默认 5
%
%   输出（结构体）：
%     running 是否在播放、channel_mask 输出通道掩码、status_raw STATUS 原始值
%
%   示例：
%     awg_output('192.168.42.2', Run=false);   % 停止

arguments
    ip {mustBeTextScalar}
    options.Run (1,1) logical = true
    options.Port (1,1) double = 9100
    options.Timeout (1,1) double = 0.2
    options.Retries (1,1) double = 5
end

t0 = tic;
BASE = 0x90200000;
REG_STATUS = BASE + uint32(0x04);       % bit0 running、bit1 busy、bit5:4 命令结果
REG_COMMAND = BASE + uint32(0x08);      % 1 stop、2 start
REG_TX_MASK = BASE + uint32(0x10);      % 输出通道掩码
if options.Run
    value = 2;
else
    value = 1;
end

% 操作队列：先读 STATUS 判断是否在播放（tag 'check'）；需要时写命令并轮询完成（tag 'poll'）；
% 最后读 STATUS 和 TX_MASK 作为返回值（tag 'final'、'mask'）
ops = {struct('op', 'read', 'addr', REG_STATUS, 'tag', 'check'), ...
       struct('op', 'read', 'addr', REG_STATUS, 'tag', 'final'), ...
       struct('op', 'read', 'addr', REG_TX_MASK, 'tag', 'mask')};
out = struct('running', false, 'channel_mask', 0, 'status_raw', 0);

sock = java.net.DatagramSocket();
inet = java.net.InetAddress.getByName(char(ip));
rxPkt = java.net.DatagramPacket(zeros(1, 2048, 'int8'), 2048);
seq = randi([0, 2^31]);
try
    while ~isempty(ops)
        op = ops{1};
        ops(1) = [];
        % ---- 组包、发送、等回复（超时重发同一序号）----
        seq = mod(seq + 1, 2^32);
        if strcmp(op.op, 'write')
            opcode = 2;
            payload = typecast(uint32(op.data), 'uint8');
        else
            opcode = 1;
            payload = zeros(1, 0, 'uint8');
        end
        req = [typecast(uint16(0xA7E1), 'uint8'), uint8(1), uint8(opcode), typecast(uint32(seq), 'uint8'), ...
               typecast(uint32(op.addr), 'uint8'), typecast(uint16(1), 'uint8'), zeros(1, 10, 'uint8'), payload];
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
                rxPkt.setLength(2048);
                try
                    sock.receive(rxPkt);
                catch
                    break
                end
                raw = typecast(int8(rxPkt.getData()), 'uint8');
                raw = reshape(raw(1:rxPkt.getLength()), 1, []);
                if numel(raw) >= 24 && typecast(raw(1:2), 'uint16') == 0xA7E1 && raw(4) == bitor(opcode, 128) && ...
                        typecast(raw(5:8), 'uint32') == uint32(seq)
                    rCount = double(typecast(raw(13:14), 'uint16'));
                    reply = struct('status', double(typecast(raw(17:18), 'uint16')), ...
                                   'data', raw(25:min(numel(raw), 24 + 4 * rCount)));
                end
            end
            if ~isempty(reply)
                break
            end
        end
        if isempty(reply)
            error('awg_output:timeout', '板卡 %s:%d 无回复；请检查光口连线、IP 和板卡是否已初始化', char(ip), options.Port);
        end
        if reply.status ~= 0
            error('awg_output:fpga', 'FPGA 返回错误 status=%d，地址 0x%08X', reply.status, op.addr);
        end
        % ---- 结果处理 ----
        v = 0;
        if strcmp(op.op, 'read') && numel(reply.data) >= 4
            v = double(typecast(reply.data(1:4), 'uint32'));
        end
        switch op.tag
            case 'check'
                if ~(options.Run && bitand(v, 1))               % 已在播放且要 Run：什么都不用做
                    ops = [{struct('op', 'write', 'addr', REG_COMMAND, 'data', value, 'tag', ''), ...
                            struct('op', 'read', 'addr', REG_STATUS, 'tag', 'poll', 'deadline', toc(t0) + 5)}, ops]; %#ok<AGROW>
                end
            case 'poll'
                if bitand(bitshift(v, -1), 1)                   % busy：命令还在执行
                    if toc(t0) > op.deadline
                        error('awg_output:cmd', '命令 %d 超时未完成（STATUS=0x%X）', value, v);
                    end
                    ops = [{op}, ops]; %#ok<AGROW>
                elseif bitand(bitshift(v, -4), 3)
                    error('awg_output:cmd', '命令 %d 被拒绝（STATUS=0x%X）；Run 被拒通常是还没下载波形或 PS 未就绪', value, v);
                end
            case 'final'
                out.running = logical(bitand(v, 1));
                out.status_raw = v;
            case 'mask'
                out.channel_mask = bitand(v, 255);
        end
    end
catch err
    sock.close();
    rethrow(err);
end
sock.close();
end
