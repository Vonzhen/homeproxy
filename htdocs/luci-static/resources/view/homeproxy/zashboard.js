'use strict';
'use ui';

return L.view.extend({
    render: function() {
        // 使用 window.location 自动适配 IP 或域名访问
        var frame = E('iframe', {
            src: window.location.protocol + '//' + window.location.hostname + '/zashboard/',
            style: 'width: 100%; height: 82vh; border: none; background: #fff; border-radius: 4px;'
        });

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', {}, [ _('Zashboard') ]),
            E('div', { 'class': 'cbi-map-descr' }, [ _('实时监控 sing-box 流量与连接状态。') ]),
            frame
        ]);
    },
    handleSaveApply: null,
    handleSave: null,
    handleReset: null
});
