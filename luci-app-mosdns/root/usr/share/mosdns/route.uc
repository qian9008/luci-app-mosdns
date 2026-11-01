#!/usr/bin/env ucode
// SPDX-License-Identifier: GPL-3.0-only
//
// 自定义域名路由生成器 —— 配置后处理器（post-processor）
//
// ── 为什么单独拆一个文件 ────────────────────────────────────────────
// 基础配置（日志/缓存/内置集合/内置分流）仍由 /etc/init.d/mosdns 的
// generate_config 用 jshn 生成到 /var/etc/mosdns.base.json，本脚本不参与。
// 本脚本只负责一件事：把 UCI 里的 route 规则翻译成 mosdns 插件，追加进
// 基础配置，再把调用顺序插进 main_sequence，最后写出完整配置。
// 好处是 init.d 里只多三行，规则相关的任何改动都不会碰到主流程。
//
// ── 三个关键约束（改代码前务必先读）───────────────────────────────
// 1. 插件顺序即加载顺序。domain_set 的 sets 字段在 Init 时就会通过
//    GetPlugin 解析，所以引用内置集合（geosite_cn 等）的 domain_set
//    必须排在它们之后 —— 因此这里统一插在 main_sequence 之前。
// 2. 上游参数不硬编码。bootstrap / pipeline / TLS 校验 / idle_timeout
//    全部从基础配置里已有的 forward 插件复制模板，保证与全局设置一致；
//    用户改了「Bootstrap DNS」，自定义路由自动跟着变。
// 3. 失败不能拖垮启动。init.d 会先把 base.json 复制成 mosdns.json 兜底，
//    本脚本失败时只打日志，mosdns 仍能用基础配置起来。
//
// ── UCI 数据结构 ─────────────────────────────────────────────────
//   config route
//       option enabled '1'                    # 缺省视为启用
//       option name 'OpenAI'                  # 仅 UI 显示，不进配置
//       list preset 'geosite_no_cn'           # 引用内置域名集合 tag
//       list domain 'keyword:openai'          # 自定义规则表达式
//       list domain 'chatgpt.com'             # 无前缀 = 后缀匹配
//       list upstream 'tls://8.8.8.8'         # 一个或多个，走 forward 并发
//
// 用法：route.uc            （无参数，路径固定，供 init.d 调用）

'use strict';

import { readfile, writefile } from 'fs';
import { cursor } from 'uci';

// 基础配置由 init.d 生成，最终配置覆盖回 mosdns 实际读取的路径
const BASE_PATH = '/var/etc/mosdns.base.json';
const OUT_PATH  = '/var/etc/mosdns.json';

// 自定义规则在 main_sequence 里的插入锚点。
// 插在「拦截」之后：用户既然拉了黑名单，拦截应该赢；
// 插在 greylist / 内置 geosite 分流之前：用户手动指定的上游优先级更高。
const ANCHOR_PRIMARY  = '$query_is_greylist_domain';
const ANCHOR_FALLBACK = '$fallback';

/* ────────────────────────── 工具函数 ────────────────────────── */

function warn(msg) {
	print('route.uc: ' + msg);
}

function trim(s) {
	return replace(s, /^\s+|\s+$/g, '');
}

// UCI 的 list 在单值时是 string，多值时是 array，统一归一化成字符串数组
function to_array(val) {
	let res = [];
	if (type(val) == 'array') {
		for (let i = 0; i < length(val); i++) {
			if (type(val[i]) == 'string') {
				let s = trim(val[i]);
				if (s != '') push(res, s);
			}
		}
	} else if (type(val) == 'string') {
		let parts = split(val, /[\s,]+/);
		for (let i = 0; i < length(parts); i++) {
			let s = trim(parts[i]);
			if (s != '') push(res, s);
		}
	}
	return res;
}

function contains(arr, val) {
	for (let i = 0; i < length(arr); i++) {
		if (arr[i] == val) return true;
	}
	return false;
}

/* ────────────────────── 基础配置读取与探测 ────────────────────── */

function load_base() {
	let raw = readfile(BASE_PATH);
	if (!raw) return null;
	try {
		let cfg = json(raw);
		if (type(cfg) != 'object' || type(cfg.plugins) != 'array') return null;
		return cfg;
	} catch (e) {
		return null;
	}
}

// 收集所有可被 sets 引用的 domain_set tag（用于校验 preset 合法性）
function collect_domain_sets(base) {
	let res = [];
	for (let i = 0; i < length(base.plugins); i++) {
		let p = base.plugins[i];
		if (type(p) == 'object' && p.type == 'domain_set' && p.tag)
			push(res, p.tag);
	}
	return res;
}

// 从已有 forward 插件里挑一个 upstream 作为参数模板（去掉 addr）。
// 注意不能直接取第一个 forward：init.d 里最前面的 forward_xinfeng_udp 只写了 addr，
// 取它会拿到空模板，bootstrap / pipeline / TLS 校验全部丢失。
// 这里按「除 addr 外的字段数量」选最完整的那个，等价于跟随用户配置的远程上游。
function find_upstream_template(base) {
	let best = null;
	let best_score = -1;

	for (let i = 0; i < length(base.plugins); i++) {
		let p = base.plugins[i];
		if (type(p) != 'object' || p.type != 'forward') continue;
		if (type(p.args) != 'object' || type(p.args.upstreams) != 'array') continue;
		if (length(p.args.upstreams) == 0) continue;

		let src = p.args.upstreams[0];
		if (type(src) != 'object') continue;

		let tpl = {};
		let score = 0;
		for (let k in src) {
			if (k == 'addr') continue;
			tpl[k] = src[k];
			score++;
		}
		if (score > best_score) {
			best_score = score;
			best = tpl;
		}
	}

	return best ? best : {};
}

// init.d 把「远程上游」包成了一个 sequence（forward_remote_upstream），
// 里面按用户开关依次放了 prefer_ipv4 / ecs，最后一项才是真正的 forward 调用。
// 自定义路由复用这段前缀，保证和「远程 DNS」行为完全一致：
// 用户开关变了，自定义规则的查询也跟着变，不用在这里重新判断一遍开关。
function find_upstream_wrapper(base) {
	for (let i = 0; i < length(base.plugins); i++) {
		let p = base.plugins[i];
		if (type(p) != 'object' || p.tag != 'forward_remote_upstream') continue;
		if (type(p.args) != 'array' || length(p.args) < 2) return [];

		// 丢掉最后一项（$forward_remote），其余是通用的查询预处理
		let prefix = [];
		for (let j = 0; j < length(p.args) - 1; j++) push(prefix, p.args[j]);
		return prefix;
	}
	return [];
}

// 按模板构造一个 upstream；h3:// 需要转成 https:// 并打开 enable_http3
function make_upstream(addr, tpl) {
	let up = {};
	for (let k in tpl) up[k] = tpl[k];
	up.addr = addr;
	if (index(addr, 'h3://') == 0) {
		up.addr = 'https://' + substr(addr, 5);
		up.enable_http3 = true;
	}
	return up;
}

/* ────────────────────── 读取 UCI 里的 route 规则 ────────────────────── */

// 用索引逐个取，保证顺序与 uci 文件中 section 的先后一致
// （ucode 的 object 不保证插入顺序，不能拿 get_all 的 key 顺序当优先级）
function read_routes(c) {
	let res = [];
	for (let i = 0; ; i++) {
		let s = c.get('mosdns', sprintf('@route[%d]', i));
		if (s == null) break;
		push(res, s);
	}
	return res;
}

/* ────────────────────────── 主构建逻辑 ────────────────────────── */

function build(base, routes, concurrent) {
	let known_sets   = collect_domain_sets(base);
	let tpl          = find_upstream_template(base);
	let wrapper      = find_upstream_wrapper(base);

	let set_plugins  = [];
	let fwd_plugins  = [];
	let up_plugins   = [];
	let seq_plugins  = [];
	let seq_tags     = [];       // 已生成的 sequence tag，按规则顺序
	let fwd_index    = {};       // 上游组合 key -> forward tag，用于去重
	let call_index   = {};       // forward tag -> 实际调用的 tag（可能带包装层）
	let seq_no       = 0;

	for (let i = 0; i < length(routes); i++) {
		let r = routes[i];

		// 未显式关闭即启用（用户刚加完一条规则不必再点一次开关）
		if (r.enabled == '0') continue;

		let exps = to_array(r.domain);
		let presets = [];
		let raw_presets = to_array(r.preset);
		for (let j = 0; j < length(raw_presets); j++) {
			// 引用了不存在的 tag 会让 mosdns 直接启动失败，这里必须过滤
			if (contains(known_sets, raw_presets[j])) push(presets, raw_presets[j]);
			else warn(sprintf('skip unknown domain_set "%s"\n', raw_presets[j]));
		}

		if (length(exps) == 0 && length(presets) == 0) {
			warn(sprintf('rule #%d has no domain source, skipped\n', i));
			continue;
		}

		let upstreams = to_array(r.upstream);
		if (length(upstreams) == 0) {
			warn(sprintf('rule #%d has no upstream, skipped\n', i));
			continue;
		}

		seq_no++;
		let set_tag = sprintf('route_set_%d', seq_no);

		// 1) 域名集合：自定义表达式 + 内置集合引用
		let set_args = {};
		if (length(exps) > 0) set_args.exps = exps;
		if (length(presets) > 0) set_args.sets = presets;
		push(set_plugins, {
			tag: set_tag,
			type: 'domain_set',
			args: set_args
		});

		// 2) 上游：相同上游组合共用一个 forward 实例，避免重复连接池 / bootstrap
		let key = join("\n", sort(upstreams));
		let fwd_tag = fwd_index[key];
		let call_tag;

		if (!fwd_tag) {
			fwd_tag = sprintf('route_fwd_%d', length(fwd_plugins) + 1);
			fwd_index[key] = fwd_tag;

			let ups = [];
			for (let j = 0; j < length(upstreams); j++)
				push(ups, make_upstream(upstreams[j], tpl));

			push(fwd_plugins, {
				tag: fwd_tag,
				type: 'forward',
				args: { concurrent: concurrent, upstreams: ups }
			});

			// 包装层：复用「远程上游」的预处理前缀（prefer_ipv4 / ecs）。
			// 没有前缀时直接用 forward 本身，不多套一层无意义的 sequence。
			if (length(wrapper) > 0) {
				let up_tag = sprintf('route_up_%d', length(up_plugins) + 1);
				let up_args = [];
				for (let j = 0; j < length(wrapper); j++) push(up_args, wrapper[j]);
				push(up_args, { exec: '$' + fwd_tag });
				push(up_plugins, { tag: up_tag, type: 'sequence', args: up_args });
				call_tag = up_tag;
			} else {
				call_tag = fwd_tag;
			}
			call_index[fwd_tag] = call_tag;
		} else {
			// 复用已有 forward，连带复用它的包装 tag
			call_tag = call_index[fwd_tag];
		}

		// 3) 单条规则的执行序列
		let seq_tag = sprintf('route_seq_%d', seq_no);
		push(seq_plugins, {
			tag: seq_tag,
			type: 'sequence',
			args: [{
				matches: sprintf('qname $%s', set_tag),
				exec: '$' + call_tag
			}]
		});
		push(seq_tags, seq_tag);
	}

	return { set_plugins, fwd_plugins, up_plugins, seq_plugins, seq_tags };
}

// 在 main_sequence 里插入自定义规则的调用与判定。返回是否成功。
function inject_main_sequence(base, seq_tags) {
	if (length(seq_tags) == 0) return false;

	let main = null;
	for (let i = 0; i < length(base.plugins); i++) {
		let p = base.plugins[i];
		if (type(p) == 'object' && p.tag == 'main_sequence') { main = p; break; }
	}
	if (main == null || type(main.args) != 'array') {
		warn('main_sequence not found, custom routes will not take effect\n');
		return false;
	}

	// 优先插在 greylist 之前；找不到就退化到 fallback 之前
	let pos = -1;
	for (let i = 0; i < length(main.args); i++) {
		let a = main.args[i];
		if (type(a) == 'object' && a.exec == ANCHOR_PRIMARY) { pos = i; break; }
	}
	if (pos < 0) {
		for (let i = 0; i < length(main.args); i++) {
			let a = main.args[i];
			if (type(a) == 'object' && a.exec == ANCHOR_FALLBACK) { pos = i; break; }
		}
	}
	if (pos < 0) {
		warn('anchor not found in main_sequence, custom routes will not take effect\n');
		return false;
	}

	let args = [];
	for (let i = 0; i < length(main.args); i++) {
		if (i == pos) {
			for (let j = 0; j < length(seq_tags); j++) {
				push(args, { exec: '$' + seq_tags[j] });
				// 命中后立刻收尾，避免继续走到后面的内置分流
				push(args, { exec: 'jump has_resp_sequence' });
			}
		}
		push(args, main.args[i]);
	}
	main.args = args;
	return true;
}

// 把生成好的插件追加到数组末尾，顺序：集合 → 上游 → 包装 → 执行序列。
// domain_set 必须早于引用它的 sequence，所以这里不能乱序。
function append_built(out, built) {
	for (let j = 0; j < length(built.set_plugins); j++) push(out, built.set_plugins[j]);
	for (let j = 0; j < length(built.fwd_plugins); j++) push(out, built.fwd_plugins[j]);
	for (let j = 0; j < length(built.up_plugins); j++) push(out, built.up_plugins[j]);
	for (let j = 0; j < length(built.seq_plugins); j++) push(out, built.seq_plugins[j]);
}

// 把自定义插件插到 main_sequence 之前（此时内置 domain_set 都已注册）
function merge_plugins(base, built) {
	let out = [];
	let inserted = false;

	for (let i = 0; i < length(base.plugins); i++) {
		let p = base.plugins[i];
		if (!inserted && type(p) == 'object' && p.tag == 'main_sequence') {
			append_built(out, built);
			inserted = true;
		}
		push(out, p);
	}

	if (!inserted) {
		warn('main_sequence not found, custom plugins appended at tail\n');
		append_built(out, built);
	}

	base.plugins = out;
}

/* ────────────────────────── 入口 ────────────────────────── */

function main() {
	let base = load_base();
	if (base == null) {
		warn('base config not found or invalid, skip custom routes\n');
		exit(1);
	}

	let c = cursor();
	c.load('mosdns');

	let concurrent = c.get('mosdns', 'config', 'concurrent');
	concurrent = int(concurrent) > 0 ? int(concurrent) : 2;

	let routes = read_routes(c);
	if (length(routes) == 0) {
		// 没有自定义规则：init.d 已把 base.json 复制成 mosdns.json，
		// 这里不做任何改写，避免重新序列化带来的格式/类型差异。
		exit(0);
	}

	let built = build(base, routes, concurrent);
	if (length(built.seq_tags) == 0) {
		warn('no valid rule, keep base config untouched\n');
		exit(0);
	}

	if (!inject_main_sequence(base, built.seq_tags)) {
		warn('failed to inject into main_sequence, keep base config untouched\n');
		exit(0);
	}
	merge_plugins(base, built);

	writefile(OUT_PATH, sprintf('%J', base));
	print(sprintf('route.uc: %d rule(s) applied\n', length(built.seq_tags)));
}

main();
