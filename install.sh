#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
# The Noctalia service resolves ~/.local/bin/eweadn-battery directly.
bin_home="$HOME/.local/bin"
plugin_dir="$data_home/noctalia/plugins/eweadn-battery"

install -Dm755 "$repo_dir/bin/eweadn-battery" "$bin_home/eweadn-battery"
install -d "$plugin_dir"
install -m644 "$repo_dir/noctalia/plugin.toml" "$plugin_dir/plugin.toml"
install -m644 "$repo_dir/noctalia/service.luau" "$plugin_dir/service.luau"
install -m644 "$repo_dir/noctalia/widget.luau" "$plugin_dir/widget.luau"

echo "Installed the helper to $bin_home/eweadn-battery"
echo "Installed the Noctalia plugin to $plugin_dir"
echo

config="${XDG_CONFIG_HOME:-$HOME/.config}/noctalia/config.toml"
if grep -q 'nawato/eweadn-battery' "$config" 2>/dev/null; then
	echo "Noctalia config already references nawato/eweadn-battery."
else
	echo "Add this to $config:"
	echo
	cat <<'EOF'
[plugins]
enabled = [ "nawato/eweadn-battery" ]

[widget.mouse_battery]
type = "nawato/eweadn-battery:battery"
EOF
	echo
	echo 'Then add "mouse_battery" to the bar section where you want it, for example:'
	echo
	echo '  [bar.default]'
	echo '  end = [ "network", "mouse_battery", "volume", "session" ]'
	echo
fi

if [[ -f /etc/udev/rules.d/70-eweadn-battery.rules ]]; then
	echo "The udev rule is already installed."
else
	echo "Install the udev rule (required for the 2.4 GHz receiver):"
	echo
	echo "  sudo install -Dm644 \"$repo_dir/udev/70-eweadn-battery.rules\" /etc/udev/rules.d/70-eweadn-battery.rules"
	echo "  sudo udevadm control --reload-rules"
	echo "  sudo udevadm trigger --subsystem-match=hidraw"
	echo
fi

echo "Verify with:"
echo "  $bin_home/eweadn-battery --json"
