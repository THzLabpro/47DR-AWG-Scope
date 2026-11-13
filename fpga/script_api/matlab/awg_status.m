function st = awg_status(ip, options)
% AWG_STATUS  读取板卡状态（只读，不改变任何设置）
%
%   st = awg_status(ip, Name=Value ...)
%
%   本函数自带 UDP 协议实现，不调用其他自定义函数。
%
%   输入：
%     ip          板卡 IP，例如 '192.168.42.2'
%   可选参数（Name=Value）：
%     Port        UDP 端口，默认 9100
%     Timeout     每个请求的超时（秒），默认 0.2
%     Retries     超时重发次数，默认 5
%
%   输出（结构体）：
%     id              '0x41574732'（"AWG2"）表示固件正确
%     build_id        位元流版本（V1 = '0xD3C02026'）
%     abi             寄存器接口版本（V1 = '0x00030001'）
%     running         是否在播放
%     busy            是否正在执行命令
%     ps_ready        PS 是否已完成 RFDC 初始化（false 表示需要「下载 bit 并初始化」）
%     fault           是否有故障；fault_channels 各通道故障位
%     last_result     最近一次命令结果（0 OK、1 拒绝、2 故障）
%     cap_busy / cap_done   采集状态
%     length_samples  当前播放长度（点）
%     channel_mask    输出通道掩码
%     dac_fs_hz / adc_fs_hz 采样率
%     cap_samples     最近一次采集的点数
%     status_raw      STATUS 原始值（十六进制字符串）
%
%   示例：
%     st = awg_status('192.168.42.2'); disp(st)

arguments
    ip {mustBeTextScalar}
    options.Port (1,1) double = 9100
    options.Timeout (1,1) double = 0.2
    options.Retries (1,1) double = 5
end

t0 = tic;
BASE = 0x90200000;
% 逐个读取（避免读到有副作用的寄存器，例如 CAP_RD_DATA）
names = {'id', 'status', 'tx_length', 'tx_mask', 'dac_fs_ksps', 'adc_fs_ksps', 'faults', 'abi', ...
         'cap_status', 'cap_samples', 'build_id'};
offsets = [0x00, 0x04, 0x0C, 0x10, 0x14, 0x18, 0x1C, 0x20, 0x28, 0x2C, 0x54];
raw = struct();

sock = java.net.DatagramSocket();
inet = java.net.InetAddress.getByName(char(ip));
rxPkt = java.net.DatagramPacket(zeros(1, 2048, 'int8'), 2048);
seq = randi([0, 2^31]);
try
    for r = 1:numel(names)
        addr = BASE + uint32(offsets(r));
        seq = mod(seq + 1, 2^32);
        % READ 请求：opcode 1、count 1，无数据
        req = [typecast(uint16(0xA7E1), 'uint8'), uint8(1), uint8(1), typecast(uint32(seq), 'uint8'), ...
               typecast(uint32(addr), 'uint8'), typecast(uint16(1), 'uint8'), zeros(1, 10, 'uint8')];
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
                pkt = typecast(int8(rxPkt.getData()), 'uint8');
                pkt = reshape(pkt(1:rxPkt.getLength()), 1, []);
                if numel(pkt) >= 28 && typecast(pkt(1:2), 'uint16') == 0xA7E1 && pkt(4) == 129 && ...
                        typecast(pkt(5:8), 'uint32') == uint32(seq)
                    reply = struct('status', double(typecast(pkt(17:18), 'uint16')), ...
                                   'value', double(typecast(pkt(25:28), 'uint32')));
                end
            end
            if ~isempty(reply)
                break
            end
        end
        if isempty(reply)
            error('awg_status:timeout', '板卡 %s:%d 无回复；请检查光口连线、IP 和板卡是否已初始化', char(ip), options.Port);
        end
        if reply.status ~= 0
            error('awg_status:fpga', '读取 %s（0x%08X）失败，status=%d', names{r}, addr, reply.status);
        end
        raw.(names{r}) = reply.value;
    end
catch err
    sock.close();
    rethrow(err);
end
sock.close();

s = raw.status;
st = struct('id', sprintf('0x%08X', raw.id), 'build_id', sprintf('0x%08X', raw.build_id), ...
            'abi', sprintf('0x%08X', raw.abi), 'running', logical(bitand(s, 1)), ...
            'busy', logical(bitand(s, 2)), 'ps_ready', logical(bitand(s, 4)), 'fault', logical(bitand(s, 8)), ...
            'last_result', bitand(bitshift(s, -4), 3), 'cap_busy', logical(bitand(s, 64)), ...
            'cap_done', logical(bitand(s, 128)), 'fault_channels', bitand(raw.faults, 255), ...
            'length_samples', raw.tx_length * 32, 'channel_mask', bitand(raw.tx_mask, 255), ...
            'dac_fs_hz', raw.dac_fs_ksps * 1000, 'adc_fs_hz', raw.adc_fs_ksps * 1000, ...
            'cap_samples', raw.cap_samples, 'status_raw', sprintf('0x%08X', s));
end
