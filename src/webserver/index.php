<?php
/**
 * 客户端连接信息展示页。
 *
 * 同一台后端服务器同时承接两条入口路径，用于对比两种「拿到客户端真实 IP」的机制：
 *
 *   入口 A —— ELB TLS 监听器（已开启 Proxy Protocol）
 *     ELB 在业务数据前插入 Proxy Protocol 头，Web 服务器解析后得到客户端 IP + 端口。
 *     nginx  ：$proxy_protocol_addr / $proxy_protocol_port 经 fastcgi_param 传入。
 *     haproxy：bind accept-proxy 后 %[src] / %[src_port] 即为客户端地址。
 *
 *   入口 B —— ELB TCP 监听器（源地址透传）
 *     独享型负载均衡的 TCP 监听器默认与后端服务器直接使用客户端真实 IP 通信，
 *     不需要 Proxy Protocol，客户端地址直接体现在 TCP 连接的源地址上。
 *
 * 页面把两者并排列出，便于直观确认当前请求走的是哪条路径、真实 IP 从哪来。
 */

function server_value(string $key, string $fallback = '—'): string
{
    return isset($_SERVER[$key]) && $_SERVER[$key] !== '' ? $_SERVER[$key] : $fallback;
}

$ingress       = server_value('INGRESS_PATH', 'unknown');
$ppClientAddr  = server_value('CLIENT_ADDR');
$ppClientPort  = server_value('CLIENT_PORT');
$remoteAddr    = server_value('REMOTE_ADDR');
$remotePort    = server_value('REMOTE_PORT');
$viaProxyProto = $ppClientAddr !== '—';

$rows = [
    ['当前入口', htmlspecialchars($ingress, ENT_QUOTES)],
    ['真实 IP 来源', $viaProxyProto ? 'Proxy Protocol 头' : 'TCP 连接源地址（源地址透传）'],
    ['客户端 IP（Proxy Protocol 头）', htmlspecialchars($ppClientAddr, ENT_QUOTES)],
    ['客户端端口（Proxy Protocol 头）', htmlspecialchars($ppClientPort, ENT_QUOTES)],
    ['TCP 连接源地址 REMOTE_ADDR', htmlspecialchars($remoteAddr, ENT_QUOTES)],
    ['TCP 连接源端口 REMOTE_PORT', htmlspecialchars($remotePort, ENT_QUOTES)],
    ['客户端软件', htmlspecialchars(server_value('HTTP_USER_AGENT'), ENT_QUOTES)],
    ['服务端软件', htmlspecialchars(server_value('SERVER_SOFTWARE'), ENT_QUOTES)],
];
?>
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <title>客户端连接信息</title>
  <style>
    body { font-family: -apple-system, "Segoe UI", "Microsoft YaHei", sans-serif; margin: 40px; }
    table { border-collapse: collapse; min-width: 620px; }
    caption { font-weight: bold; padding-bottom: 10px; text-align: left; font-size: 18px; }
    td, th { border: 1px solid #ddd; padding: 8px 12px; }
    tr:nth-child(even) { background-color: #f2f2f2; }
    td:first-child { color: #555; width: 300px; }
    .tag { display: inline-block; padding: 2px 8px; border-radius: 3px; font-size: 12px; color: #fff; }
    .pp  { background: #c7000b; }
    .tp  { background: #1f6feb; }
  </style>
</head>
<body>
<table>
  <caption>
    客户端连接信息
    <?php if ($viaProxyProto): ?>
      <span class="tag pp">Proxy Protocol</span>
    <?php else: ?>
      <span class="tag tp">源地址透传</span>
    <?php endif; ?>
  </caption>
  <?php foreach ($rows as [$label, $value]): ?>
  <tr>
    <td><?= $label ?></td>
    <td><?= $value ?></td>
  </tr>
  <?php endforeach; ?>
</table>
</body>
</html>
