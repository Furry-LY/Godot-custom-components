func get_local_ip() -> String:
	var interfaces = IP.get_local_interfaces()
	var candidates = []
	
	for iface in interfaces:
		var _name = iface.name.to_lower()
		# 1. 排除虚拟网卡和回环
		if _name.contains('virtual') or _name.contains('vmware') or _name.contains('vbox'):
			continue
		if _name.contains('loopback') or _name.contains('docker'):
			continue
		
		for ip in iface.addresses:
			# 2. 筛选 IPv4 且排除 127.x.x.x
			if '.' in ip and not ip.begins_with('127.'):
				var segments = ip.split('.')
				var first = segments[0].to_int()
				var second = segments[1].to_int()
				var is_private = (first == 10) or (first == 192 and second == 168) or (first == 172 and second >= 16 and second <= 31)
				
				if is_private:
					var priority = 0
					if _name.contains('wlan') or _name.contains('wi-fi') or _name.contains('无线'):
						priority = 10
					elif _name.contains('eth') or _name.contains('enp') or _name.contains('以太网'):
						priority = 5
					candidates.append({'ip': ip, 'priority': priority})
	
	if candidates.is_empty():
		return '127.0.0.1'
	candidates.sort_custom(func(a, b): return a.priority > b.priority)
	return candidates[0].ip
