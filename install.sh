#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Noctalia-specific overrides take precedence over the XDG variables. Like the
# XDG variables, they are "home roots", so the noctalia/ component is appended
# below (NOCTALIA_DATA_HOME=/tmp/profile -> /tmp/profile/noctalia/plugins/...).
data_home="${NOCTALIA_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}"
config_home="${NOCTALIA_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}"

# The Noctalia service resolves ~/.local/bin/eweadn-battery directly.
bin_home="$HOME/.local/bin"
plugin_dir="$data_home/noctalia/plugins/eweadn-battery"

install -Dm755 "$repo_dir/bin/eweadn-battery" "$bin_home/eweadn-battery"
install -d "$plugin_dir"
install -m644 "$repo_dir/noctalia/plugin.toml" "$plugin_dir/plugin.toml"
install -m644 "$repo_dir/noctalia/service.luau" "$plugin_dir/service.luau"
install -m644 "$repo_dir/noctalia/widget.luau" "$plugin_dir/widget.luau"
install -m644 "$repo_dir/noctalia/panel.luau" "$plugin_dir/panel.luau"

echo "Installed the helper to $bin_home/eweadn-battery"
echo "Installed the Noctalia plugin to $plugin_dir"
echo

config="$config_home/noctalia/config.toml"
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

# EWEADN_UDEV_RULE exists for installer tests; the default remains the system
# path that the documented sudo install command targets.
rule_src="$repo_dir/udev/70-eweadn-battery.rules"
rule_dst="${EWEADN_UDEV_RULE:-/etc/udev/rules.d/70-eweadn-battery.rules}"

print_udev_install() {
	printf '  sudo install -Dm644 "%s" "%s"\n' "$rule_src" "$rule_dst"
	printf '  sudo udevadm control --reload-rules\n'
	printf '  sudo udevadm trigger --subsystem-match=hidraw\n'
}

if [[ -e "$rule_dst" ]] && cmp -s "$rule_src" "$rule_dst"; then
	echo "The udev rule at $rule_dst is already installed and up to date."
elif [[ -e "$rule_dst" ]]; then
	echo "The udev rule at $rule_dst is stale and differs from the bundled rule; update it:"
	echo
	print_udev_install
	echo
else
	echo "Install the udev rule (required for the 2.4 GHz receiver):"
	echo
	print_udev_install
	echo
fi

echo "Verify with:"
echo "  $bin_home/eweadn-battery --json"
