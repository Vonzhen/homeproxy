#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2024 ImmortalWrt.org
 * Feature: Airport-Centric Dynamic Node Groups Generator (Ultimate Logic Version)
 */

'use strict';

import { cursor } from 'uci';
import { open } from 'fs';
import { getTime, isEmpty } from 'homeproxy';

const uci = cursor();
const uciconfig = 'homeproxy';
uci.load(uciconfig);

function log(...args) {
    const logfile = open('/var/run/homeproxy/homeproxy.log', 'a');
    logfile.write(`${getTime()} [GROUP_ENGINE] ${join(' ', args)}\n`);
    logfile.close();
}

function main() {
    log('Starting Dynamic Node Groups Generation (Ultimate Logic Mode)...');

    // 1. 清理旧组 (🌟 修复：保护 manual_global 免遭毒手，以便读取其历史状态)
    let removed_groups = 0;
    uci.foreach(uciconfig, 'routing_node', (cfg) => {
        if (cfg.auto_generated === '1' && cfg['.name'] !== 'manual_global') {
            uci.delete(uciconfig, cfg['.name']);
            removed_groups++;
        }
    });
    if (removed_groups > 0) log(`Cleaned up ${removed_groups} old auto-generated groups.`);

    // 2. 读取机场与规则、以及顶级组白名单
    let airports = [];
    let all_regions = {};

    uci.foreach(uciconfig, 'subscription_airport', (cfg) => {
        if (cfg.enabled !== '1') return;
        
        let rules = [];
        let raw_rules = cfg.region_group || [];
        if (type(raw_rules) === 'string') raw_rules = [raw_rules];

        for (let _r = 0; _r < length(raw_rules); _r++) {
            let r = raw_rules[_r];
            let parts = split(r, '|');
            
            let region = "";
            let keywords = "";

            if (length(parts) >= 2) {
                region = trim(parts[0]);
                keywords = replace(trim(parts[1]), /,/g, '|'); 
            } else if (length(parts) === 1 && trim(parts[0]) !== "") {
                region = trim(parts[0]);
                keywords = region; 
            } else { continue; }

            push(rules, { region: region, pattern: regexp(keywords, 'i') });
            all_regions[region] = true;
        }

        // 🌟 读取白名单配置 (处理字符串和数组形式)
        let whitelist = [];
        let raw_wl = cfg.top_level_whitelist || [];
        if (type(raw_wl) === 'string') raw_wl = [raw_wl];
        for (let _w = 0; _w < length(raw_wl); _w++) push(whitelist, trim(raw_wl[_w]));

        push(airports, { 
            id: cfg['.name'], 
            name: cfg.name || 'Unnamed', 
            rules: rules, 
            whitelist: whitelist, // 🌟 挂载白名单到内存
            nodes: {} 
        });
    });

    if (length(airports) === 0) {
        log('No enabled airports found. Aborted.');
        uci.commit(uciconfig);
        return;
    }

    // 3. 节点分拣与存活节点快照
    let total_matched = 0;
    let valid_nodes_set = {};    // 🌟 用于验证手动组老节点是否存活
    let fallback_node = null;    // 🌟 备胎节点

    uci.foreach(uciconfig, 'node', (node) => {
        if (!node.airport_id) return;
        let ap = null;
        for (let _a = 0; _a < length(airports); _a++) {
            if (airports[_a].id === node.airport_id) { ap = airports[_a]; break; }
        }
        if (!ap) return;

        for (let _ri = 0; _ri < length(ap.rules); _ri++) {
            let r = ap.rules[_ri];
            if (match(node.label, r.pattern)) {
                let nid = node['.name'];
                if (!ap.nodes[r.region]) ap.nodes[r.region] = [];
                push(ap.nodes[r.region], nid);
                
                // 🌟 记录有效节点，并抓取第一个可用节点作为备胎
                valid_nodes_set[nid] = true;
                if (!fallback_node) fallback_node = nid;
                
                total_matched++;
                break;
            }
        }
    });
    log(`Successfully categorized ${total_matched} nodes.`);

    // 4. 生成底层出站组，并按白名单收集顶层节点
    let top_level_nodes = {}; 

    for (let i = 0; i < length(airports); i++) {
        let ap = airports[i];
        let ap_index = sprintf('%02d', i + 1); 

        for (let region in ap.nodes) {
            let n_list = ap.nodes[region];
            if (length(n_list) === 0) continue;

            let region_lower = lc(region);
            let group_id = `${region_lower}${ap_index}`; 
            
            let safe_n_list = [];
            for (let _x = 0; _x < length(n_list); _x++) push(safe_n_list, n_list[_x] + ""); 

            // 生成底层组 (照常生成，不受白名单影响)
            uci.set(uciconfig, group_id, 'routing_node');
            uci.set(uciconfig, group_id, 'enabled', '1'); 
            uci.set(uciconfig, group_id, 'label', `[${ap_index}] ${region} - ${ap.name}`);
            uci.set(uciconfig, group_id, 'node', 'urltest');
            uci.set(uciconfig, group_id, 'urltest_tolerance', '150');
            uci.set(uciconfig, group_id, 'auto_generated', '1'); 
            uci.set(uciconfig, group_id, 'urltest_nodes', safe_n_list);

            // 🌟 白名单严格验证系统 (Opt-in / Default Deny)
            let allowed_to_pool = false;
            for (let _w = 0; _w < length(ap.whitelist); _w++) {
                // 如果填了 *，或者精准匹配了当前区域，则放行
                if (ap.whitelist[_w] === '*' || lc(ap.whitelist[_w]) === region_lower) {
                    allowed_to_pool = true;
                    break;
                }
            }

            // 只有验证通过，才有资格把节点倒入顶级组的水池
            if (allowed_to_pool) {
                if (!top_level_nodes[region]) top_level_nodes[region] = [];
                for (let _n = 0; _n < length(safe_n_list); _n++) push(top_level_nodes[region], safe_n_list[_n]);
            } else {
                log(`[Whitelist] Blocked [${ap.name}] from entering Auto - ${region}.`);
            }
        }
    }

    // 5. 生成终极顶层组 (宁缺毋滥版)
    let global_regions_cfg = uci.get(uciconfig, 'subscription', 'global_regions') || [];
    if (type(global_regions_cfg) === 'string') global_regions_cfg = [global_regions_cfg];

    let target_regions = [];
    if (length(global_regions_cfg) > 0) {
        for (let _g = 0; _g < length(global_regions_cfg); _g++) push(target_regions, trim(global_regions_cfg[_g]));
    } else {
        for (let reg in all_regions) push(target_regions, reg);
    }

    for (let _tr = 0; _tr < length(target_regions); _tr++) {
        let region = target_regions[_tr];
        let top_id = `auto_${lc(region)}`;
        let all_nodes_for_region = top_level_nodes[region] || [];
        
        if (length(all_nodes_for_region) > 0) {
            uci.set(uciconfig, top_id, 'routing_node');
            uci.set(uciconfig, top_id, 'enabled', '1'); 
            uci.set(uciconfig, top_id, 'label', `⚡ Auto - ${region}`);
            uci.set(uciconfig, top_id, 'node', 'urltest');
            uci.set(uciconfig, top_id, 'urltest_tolerance', '150');
            uci.set(uciconfig, top_id, 'auto_generated', '1');

            let safe_top_list = [];
            for (let _y = 0; _y < length(all_nodes_for_region); _y++) push(safe_top_list, all_nodes_for_region[_y] + "");
            
            uci.set(uciconfig, top_id, 'urltest_nodes', safe_top_list);
            log(`Success: Attached ${length(safe_top_list)} nodes to [⚡ Auto - ${region}].`);
        } else {
            log(`Warning: Region [${region}] has no valid nodes (or blocked by whitelist). Skipped generating top-level group.`);
        }
    }

    // 6. 🌟 生成全局唯一有状态的手动组 (Manual Selector)
    if (fallback_node) {
        let manual_id = 'manual_global';
        let old_manual_node = uci.get(uciconfig, manual_id, 'node'); // 抓取老状态
        
        let target_node = fallback_node;
        // 验证老节点是否依然幸存于世
        if (old_manual_node && valid_nodes_set[old_manual_node]) {
            target_node = old_manual_node;
            log(`[Manual Group] Inherited state successfully. Kept node unchanged.`);
        } else {
            log(`[Manual Group] Old node dead/missing. Assigned new fallback node.`);
        }

        uci.set(uciconfig, manual_id, 'routing_node');
        uci.set(uciconfig, manual_id, 'enabled', '1');
        
        // 如果用户改过它的名字，尊重用户；否则赋予默认炫酷名字
        if (!uci.get(uciconfig, manual_id, 'label')) {
            uci.set(uciconfig, manual_id, 'label', '🖐️ Manual - Global');
        }
        
        // 绑定最终幸存/备用的单节点
        uci.set(uciconfig, manual_id, 'node', target_node);
        uci.set(uciconfig, manual_id, 'auto_generated', '1'); 
    }

    uci.commit(uciconfig);
    log('Dynamic Node Groups Generation completed successfully!');
}

try {
    call(main);
} catch (e) {
    log('[FATAL] Group engine crashed:');
    log(sprintf('%s: %s', e.type, e.message));
    log(e.stacktrace[0].context);
}
