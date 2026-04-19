/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require dom';
'require form';
'require fs';
'require poll';
'require rpc';
'require uci';
'require ui';
'require view';

/* Thanks to luci-app-aria2 */
const css = '                \
#log_textarea {                \
    padding: 10px;            \
    text-align: left;        \
}                    \
#log_textarea pre {            \
    padding: .5rem;            \
    word-break: break-all;        \
    margin: 0;            \
}                    \
.description {                \
    background-color: #33ccff;    \
}';

const hp_dir = '/var/run/homeproxy';

function getConnStat(o, site) {
    const callConnStat = rpc.declare({
        object: 'luci.homeproxy',
        method: 'connection_check',
        params: ['site'],
        expect: { '': {} }
    });

    o.default = E('div', { 'style': 'cbi-value-field' }, [
        E('button', {
            'class': 'btn cbi-button cbi-button-action',
            'click': ui.createHandlerFn(this, () => {
                return L.resolveDefault(callConnStat(site), {}).then((ret) => {
                    let ele = o.default.firstElementChild.nextElementSibling;
                    if (ret.result) {
                        ele.style.setProperty('color', 'green');
                        ele.innerHTML = _('passed');
                    } else {
                        ele.style.setProperty('color', 'red');
                        ele.innerHTML = _('failed');
                    }
                });
            })
        }, [ _('Check') ]),
        ' ',
        E('strong', { 'style': 'color:gray' }, _('unchecked')),
    ]);
}

function getResVersion(o, type) {
    const callResVersion = rpc.declare({
        object: 'luci.homeproxy',
        method: 'resources_get_version',
        params: ['type'],
        expect: { '': {} }
    });

    const callResUpdate = rpc.declare({
        object: 'luci.homeproxy',
        method: 'resources_update',
        params: ['type'],
        expect: { '': {} }
    });

    return L.resolveDefault(callResVersion(type), {}).then((res) => {
        let spanTemp = E('div', { 'style': 'cbi-value-field' }, [
            E('button', {
                'class': 'btn cbi-button cbi-button-action',
                'click': ui.createHandlerFn(this, () => {
                    return L.resolveDefault(callResUpdate(type), {}).then((res) => {
                        switch (res.status) {
                        case 0: o.description = _('Successfully updated.'); break;
                        case 1: o.description = _('Update failed.'); break;
                        case 2: o.description = _('Already in updating.'); break;
                        case 3: o.description = _('Already at the latest version.'); break;
                        default: o.description = _('Unknown error.'); break;
                        }
                        return o.map.reset();
                    });
                })
            }, [ _('Check update') ]),
            ' ',
            E('strong', { 'style': (res.error ? 'color:red' : 'color:green') },
                [ res.error ? 'not found' : res.version ]
            ),
        ]);

        o.default = spanTemp;
    });
}

function getRuntimeLog(o, name, _option_index, section_id, _in_table) {
    const filename = o.option.split('_')[1];

    let section, log_level_el;
    switch (filename) {
    case 'homeproxy': section = null; break;
    case 'sing-box-c': section = 'config'; break;
    case 'sing-box-s': section = 'server'; break;
    }

    if (section) {
        const selected = uci.get('homeproxy', section, 'log_level') || 'warn';
        const choices = {
            trace: _('Trace'), debug: _('Debug'), info: _('Info'),
            warn: _('Warn'), error: _('Error'), fatal: _('Fatal'), panic: _('Panic')
        };

        log_level_el = E('select', {
            'id': o.cbid(section_id),
            'class': 'cbi-input-select',
            'style': 'margin-left: 4px; width: 6em;',
            'change': ui.createHandlerFn(this, (ev) => {
                uci.set('homeproxy', section, 'log_level', ev.target.value);
                return o.map.save(null, true).then(() => { ui.changes.apply(true); });
            })
        });

        Object.keys(choices).forEach((v) => {
            log_level_el.appendChild(E('option', { 'value': v, 'selected': (v === selected) ? '' : null }, [ choices[v] ]));
        });
    }

    const callLogClean = rpc.declare({
        object: 'luci.homeproxy', method: 'log_clean', params: ['type'], expect: { '': {} }
    });

    const log_textarea = E('div', { 'id': 'log_textarea' },
        E('img', { 'src': L.resource('icons/loading.svg'), 'alt': _('Loading'), 'style': 'vertical-align:middle' }, _('Collecting data...'))
    );

    let log;
    poll.add(L.bind(() => {
        return fs.read_direct(String.format('%s/%s.log', hp_dir, filename), 'text')
        .then((res) => {
            log = E('pre', { 'wrap': 'pre' }, [ res.trim() || _('Log is empty.') ]);
            dom.content(log_textarea, log);
        }).catch((err) => {
            if (err.toString().includes('NotFoundError')) log = E('pre', { 'wrap': 'pre' }, [ _('Log file does not exist.') ]);
            else log = E('pre', { 'wrap': 'pre' }, [ _('Unknown error: %s').format(err) ]);
            dom.content(log_textarea, log);
        });
    }));

    return E([
        E('style', [ css ]),
        E('div', {'class': 'cbi-map'}, [
            E('h3', {'name': 'content', 'style': 'align-items: center; display: flex;'}, [
                _('%s log').format(name),
                log_level_el || '',
                E('button', {
                    'class': 'btn cbi-button cbi-button-action',
                    'style': 'margin-left: 4px;',
                    'click': ui.createHandlerFn(this, () => { return L.resolveDefault(callLogClean(filename), {}); })
                }, [ _('Clean log') ])
            ]),
            E('div', {'class': 'cbi-section'}, [
                log_textarea,
                E('div', {'style': 'text-align:right'}, E('small', {}, _('Refresh every %s seconds.').format(L.env.pollinterval)))
            ])
        ])
    ]);
}

return view.extend({
	load() {
        // 同样在服务状态页也执行一次权限修复，确保万无一失
        return L.fs.exec_direct('chmod', ['+x', '/etc/homeproxy/scripts/hp_kernel.sh']).catch(()=>{});
    },
    render() {
        let m, s, o;

        m = new form.Map('homeproxy');

        s = m.section(form.NamedSection, 'config', 'homeproxy', _('Connection check'));
        s.anonymous = true;

        o = s.option(form.DummyValue, '_check_baidu', _('BaiDu'));
        o.cfgvalue = L.bind(getConnStat, this, o, 'baidu');

        o = s.option(form.DummyValue, '_check_google', _('Google'));
        o.cfgvalue = L.bind(getConnStat, this, o, 'google');

        s = m.section(form.NamedSection, 'config', 'homeproxy', _('Resources management'));
        s.anonymous = true;

        o = s.option(form.DummyValue, '_china_ip4_version', _('China IPv4 list version'));
        o.cfgvalue = L.bind(getResVersion, this, o, 'china_ip4');
        o.rawhtml = true;

        o = s.option(form.DummyValue, '_china_ip6_version', _('China IPv6 list version'));
        o.cfgvalue = L.bind(getResVersion, this, o, 'china_ip6');
        o.rawhtml = true;

        o = s.option(form.DummyValue, '_china_list_version', _('China list version'));
        o.cfgvalue = L.bind(getResVersion, this, o, 'china_list');
        o.rawhtml = true;

        o = s.option(form.DummyValue, '_gfw_list_version', _('GFW list version'));
        o.cfgvalue = L.bind(getResVersion, this, o, 'gfw_list');
        o.rawhtml = true;
      

        /* ========================================================= */
        /* 🚀 Sing-box 内核动力管理注入区 - 开始 🚀 */
        /* ========================================================= */
        o = s.option(form.DummyValue, '_kernel_manager', _('Sing-box 内核管理'));
        o.description = _('检查版本并选择性热替换。建议定期检查并保持内核处于活跃版本。');
        o.renderWidget = function(section_id, option_index, cfgvalue) {
            let container = E('div', { 'class': 'cbi-value-field', 'style': 'display: flex; flex-direction: column; gap: 12px; padding: 10px; background: #f8f9fa; border-radius: 6px; border: 1px solid #ddd;' });

            // 版本展示行
            let local_val = E('span', { 'style': 'color: #555; font-family: monospace;' }, '未知 (点击检查)');
            let stable_val = E('span', { 'style': 'color: #555; font-family: monospace; margin-right: 15px;' }, '-');
            let beta_val = E('span', { 'style': 'color: #555; font-family: monospace; margin-right: 15px;' }, '-');

            // 升级按钮 (初始隐藏)
            let stable_btn = E('button', { 'class': 'btn cbi-button cbi-button-apply', 'style': 'display:none; padding: 2px 10px;', 'click': (ev) => { ev.preventDefault(); do_update('stable'); } }, '📥 升级稳定版');
            let beta_btn = E('button', { 'class': 'btn cbi-button cbi-button-action', 'style': 'display:none; padding: 2px 10px;', 'click': (ev) => { ev.preventDefault(); do_update('beta'); } }, '⚡ 升级预览版');

            let row_local = E('div', {}, [ E('span', { 'style': 'display:inline-block; width: 90px; font-weight:bold;' }, '📍 当前版本:'), local_val ]);
            let row_stable = E('div', {}, [ E('span', { 'style': 'display:inline-block; width: 90px; font-weight:bold;' }, '🟢 稳定版本:'), stable_val, stable_btn ]);
            let row_beta = E('div', {}, [ E('span', { 'style': 'display:inline-block; width: 90px; font-weight:bold;' }, '🟠 预览版本:'), beta_val, beta_btn ]);

            // 检查更新按钮
            let check_btn = E('button', { 'class': 'btn cbi-button cbi-button-neutral', 'style': 'width: 140px; margin-top: 5px;', 'click': function(ev) {
                ev.preventDefault();
                check_btn.disabled = true;
                check_btn.textContent = '🔄 正在连接 GitHub...';
                L.require('fs').then(fs => {
                    fs.exec_direct('sh', ['-c', '/etc/homeproxy/scripts/hp_kernel.sh --check']).then(res => {
                        check_btn.disabled = false;
                        check_btn.textContent = '🔄 重新检查';
                        try {
                            let data = JSON.parse(res.trim());
                            
                            local_val.textContent = data.local || '获取失败';
                            local_val.style.color = '#007bff';
                            
                            stable_val.textContent = data.stable || '获取失败';
                            if (data.stable && data.local !== data.stable) {
                                stable_val.style.color = '#28a745';
                                stable_val.style.fontWeight = 'bold';
                                stable_btn.style.display = 'inline-block';
                            } else {
                                stable_btn.style.display = 'none';
                            }

                            beta_val.textContent = data.beta || '获取失败';
                            if (data.beta && data.local !== data.beta) {
                                beta_val.style.color = '#fd7e14';
                                beta_val.style.fontWeight = 'bold';
                                beta_btn.style.display = 'inline-block';
                            } else {
                                beta_btn.style.display = 'none';
                            }

                        } catch(e) {
                            alert('解析版本信息失败: ' + res);
                        }
                    }).catch(err => {
                        check_btn.disabled = false;
                        check_btn.textContent = '❌ 检查失败重试';
                        alert('执行检查脚本失败！请检查网络是否畅通。');
                    });
                });
            }}, '🔍 检查线上版本');

            // 执行升级的独立逻辑
            let do_update = function(track) {
                L.require('ui').then(ui => L.require('fs').then(fs => {
                    let track_name = track === 'stable' ? '稳定版 (Stable)' : '预览版 (Beta/Next)';
                    let status_txt = E('p', { 'class': 'spinning', 'style': 'font-weight:bold; margin-bottom:10px;' }, '正在准备拉取文件...');
                    let log_pre = E('pre', { 'style': 'width: 100%; height: 280px; overflow-y: auto; background: #1e1e1e; color: #4af626; padding: 10px; font-family: monospace; font-size: 12px; border-radius: 4px; white-space: pre-wrap; word-wrap: break-word;' }, '启动跨国抓取引擎：目标轨道 [' + track_name + ']\n');
                    let close_btn = E('button', { 'class': 'cbi-button cbi-button-action', 'style': 'display: none; margin-top: 15px;', 'click': () => location.reload() }, '关闭并刷新');

                    ui.showModal('🚀 Sing-box 内核热升级', [ status_txt, log_pre, close_btn ]);

                    let log_timer = setInterval(() => {
                        fs.exec_direct('tail', ['-n', '25', '/tmp/hp_kernel_update.log']).then((log_data) => {
                            if (log_data && log_pre.textContent !== log_data) {
                                log_pre.textContent = log_data;
                                log_pre.scrollTop = log_pre.scrollHeight;
                            }
                        }).catch(() => {});
                    }, 1000);

                    fs.exec_direct('sh', ['-c', 'mkdir -p /tmp && /etc/homeproxy/scripts/hp_kernel.sh ' + track + ' > /tmp/hp_kernel_update.log 2>&1']).then(() => {
                        clearInterval(log_timer);
                        return fs.exec_direct('cat', ['/tmp/hp_kernel_update.log']);
                    }).then((final_log) => {
                        if (final_log) log_pre.textContent = final_log;
                        status_txt.className = '';
                        status_txt.style.color = '#28a745';
                        status_txt.innerHTML = '✅ 内核升级执行完毕。';
                        log_pre.scrollTop = log_pre.scrollHeight;
                        close_btn.style.display = 'inline-block';
                    }).catch((err) => {
                        clearInterval(log_timer);
                        status_txt.className = '';
                        status_txt.style.color = '#dc3545';
                        status_txt.innerHTML = '❌ 引擎崩溃！';
                        log_pre.style.color = '#dc3545';
                        log_pre.textContent += '\n\n[FATAL ERROR] ' + err;
                        close_btn.style.display = 'inline-block';
                    });
                }));
            };

            container.appendChild(row_local);
            container.appendChild(row_stable);
            container.appendChild(row_beta);
            container.appendChild(check_btn);
            return container;
        };
        /* ========================================================= */
        /* 🚀 Sing-box 内核动力管理注入区 - 结束 🚀 */
        /* ========================================================= */
        
        o = s.option(form.Value, 'github_token', _('GitHub token'));
        o.password = true;
        o.renderWidget = function() {
            let node = form.Value.prototype.renderWidget.apply(this, arguments);
            (node.querySelector('.control-group') || node).appendChild(E('button', {
                'class': 'cbi-button cbi-button-apply',
                'title': _('Save'),
                'click': ui.createHandlerFn(this, () => {
                    return this.map.save(null, true).then(() => { ui.changes.apply(true); });
                }, this.option)
            }, [ _('Save') ]));
            return node;
        }

        s = m.section(form.NamedSection, 'config', 'homeproxy');
        s.anonymous = true;

        o = s.option(form.DummyValue, '_homeproxy_logview');
        o.render = L.bind(getRuntimeLog, this, o, _('HomeProxy'));

        o = s.option(form.DummyValue, '_sing-box-c_logview');
        o.render = L.bind(getRuntimeLog, this, o, _('sing-box client'));

        o = s.option(form.DummyValue, '_sing-box-s_logview');
        o.render = L.bind(getRuntimeLog, this, o, _('sing-box server'));

        return m.render();
    },

    handleSaveApply: null,
    handleSave: null,
    handleReset: null
});
