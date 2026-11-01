'use strict';
'require form';
'require rpc';
'require uci';
'require view';

// 预设集合列表来自后端反查（读已生成的 mosdns 配置），不在前端硬编码。
// 这样用户自己在自定义配置里加了 domain_set，下拉里也能出现。
const callGetDomainSets = rpc.declare({
	object: 'luci.mosdns',
	method: 'get_domain_sets',
	expect: { sets: [] }
});

// 内置集合的兜底列表：mosdns 尚未启动过（没有 /var/etc/mosdns.json）时使用
const FALLBACK_SETS = [
	'geosite_cn',
	'geosite_no_cn',
	'geosite_apple',
	'stream_media',
	'whitelist',
	'greylist',
	'ddnslist'
];

// 上游预设：只是输入建议，用户仍可手填任意 DoH / DoT / DoQ / UDP 地址。
// 用函数而不是模块级常量，避免在翻译表就绪前调用 _()。
function upstreamPresets() {
	return [
		['tls://1.1.1.1', _('CloudFlare Public DNS (1.1.1.1)')],
		['tls://8.8.8.8', _('Google Public DNS (8.8.8.8)')],
		['tls://9.9.9.9', _('Quad9 Public DNS (9.9.9.9)')],
		['tls://208.67.222.222', _('Cisco Public DNS (208.67.222.222)')],
		['https://dns.google/dns-query', _('Google Public DNS (DNS over HTTPS)')],
		['https://cloudflare-dns.com/dns-query', _('CloudFlare Public DNS (DNS over HTTPS)')],
		['https://dns.quad9.net/dns-query', _('Quad9 Public DNS (DNS over HTTPS)')],
		['quic://dns.adguard-dns.com', _('AdGuard Public DNS (DNS over QUIC)')],
		['119.29.29.29', _('Tencent Public DNS (119.29.29.29)')],
		['223.5.5.5', _('Aliyun Public DNS (223.5.5.5)')]
	];
}

return view.extend({
	load() {
		return Promise.all([
			L.resolveDefault(callGetDomainSets(), { sets: [] }),
			uci.load('mosdns')
		]);
	},

	render(data) {
		const domainSets = (data[0] && data[0].sets && data[0].sets.length)
			? data[0].sets
			: FALLBACK_SETS;

		const m = new form.Map('mosdns', _('Custom Upstream Routing'),
			_('Sends queries matching the given domain rules to a dedicated upstream DNS.') + ' ' +
			_('Rules are evaluated after the block list and before the built-in GeoIP / GeoSite splitting,') + ' ' +
			_('so a manual match always wins over the automatic classification.') +
			'<br /><font color=\'red\'>' +
			_('Only takes effect with the Default Config. Saving settings restarts MosDNS.') +
			'</font>');

		const s = m.section(form.TypedSection, 'route', _('Routing Rule'));
		s.anonymous = false;
		s.addremove = true;
		s.sortable = true;

		// 折叠标题显示用户自定义的规则名；未命名时显示通用文案
		s.sectiontitle = section_id => uci.get('mosdns', section_id, 'name') || _('New Rule');

		let o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'name', _('Rule Name'),
			_('Display name only, never written into the mosdns config.'));
		o.placeholder = 'OpenAI';
		o.rmempty = true;

		o = s.option(form.DynamicList, 'domain', _('Domain Rules'),
			_('One entry per rule. No prefix means suffix match: example.com matches example.com and every subdomain.') + ' ' +
			_('Use keyword:xxx for substring match, full:xxx for exact match.') + '<br />' +
			_('Setting a dedicated upstream for a large keyword list has a cost: keyword matching scans the whole list on every query.') + ' ' +
			_('Prefer suffix rules unless you really need fuzzy matching.'));
		o.placeholder = 'example.com';
		o.rmempty = true;

		o = s.option(form.DynamicList, 'preset', _('Built-in Domain Sets'),
			_('Reuse an existing domain_set instead of writing domains by hand.') + ' ' +
			_('Entries here and the domain rules above are merged with OR.'));
		domainSets.forEach(name => o.value(name, name));
		o.rmempty = true;

		o = s.option(form.DynamicList, 'upstream', _('Upstream DNS'),
			_('Multiple entries are queried concurrently.') + ' ' +
			_('Rules sharing the same upstream list reuse one forward instance, so there is no duplicate connection pool.'));
		upstreamPresets().forEach(([value, label]) => o.value(value, label));
		o.rmempty = true;

		return m.render();
	},

	handleSaveApply(ev) {
		return this.handleSave(ev).then(() => {
			window.location.reload();
		});
	},

	handleReset: null
});
