#!/usr/bin/env bash
set -euo pipefail

mode="full"
for arg in "$@"; do
	case "$arg" in
		--cli-only)
			mode="cli"
			;;
		--plugin-only)
			mode="plugin"
			;;
		-h | --help)
			cat <<'EOF'
Usage: install.sh [--cli-only] [--plugin-only]

  default       install the CLI helper and, when present, the Noctalia plugin
  --cli-only    install only the CLI helper (skip the Noctalia plugin)
  --plugin-only install only the Noctalia plugin (requires the helper separately)
EOF
			exit 0
			;;
		*)
			echo "Unknown option: $arg" >&2
			echo "Try: install.sh --help" >&2
			exit 1
			;;
	esac
done

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Noctalia-specific overrides take precedence over the XDG variables. Like the
# XDG variables, they are "home roots", so the noctalia/ component is appended
# below (NOCTALIA_DATA_HOME=/tmp/profile -> /tmp/profile/noctalia/plugins/...).
data_home="${NOCTALIA_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}"
config_home="${NOCTALIA_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}"

# The Noctalia service resolves ~/.local/bin/eweadn-linux-control directly.
bin_home="$HOME/.local/bin"
bin_name="eweadn-linux-control"
legacy_bin_name="eweadn-battery"
plugin_id="nawato/eweadn-linux-control"
legacy_plugin_id="nawato/eweadn-battery"
plugin_dir="$data_home/noctalia/plugins/eweadn-linux-control"
legacy_plugin_dir="$data_home/noctalia/plugins/eweadn-battery"

install_helper=false
install_plugin=false
case "$mode" in
	full)
		install_helper=true
		install_plugin=true
		;;
	cli)
		install_helper=true
		;;
	plugin)
		install_plugin=true
		;;
esac

if [[ "$install_helper" == "true" ]]; then
	if [[ -f "$repo_dir/bin/$bin_name" ]]; then
		install -Dm755 "$repo_dir/bin/$bin_name" "$bin_home/$bin_name"
		echo "Installed the helper to $bin_home/$bin_name"
		# Backward compatibility for installs that still reference the old
		# binary name (old plugin releases, scripts, muscle memory).
		if [[ ! -e "$bin_home/$legacy_bin_name" ]]; then
			ln -s "$bin_name" "$bin_home/$legacy_bin_name"
			echo "Created compatibility symlink $bin_home/$legacy_bin_name"
		elif [[ ! -L "$bin_home/$legacy_bin_name" ]]; then
			echo "Note: $bin_home/$legacy_bin_name still exists; remove it once"
			echo "you have migrated to $bin_name."
		fi
	else
		echo "Skipping the helper: bin/$bin_name is not in this bundle."
		install_helper=false
	fi
fi

if [[ "$install_plugin" == "true" ]]; then
	if [[ -f "$repo_dir/noctalia/plugin.toml" ]]; then
		install -d "$plugin_dir"
		install -m644 "$repo_dir/noctalia/plugin.toml" "$plugin_dir/plugin.toml"
		install -m644 "$repo_dir/noctalia/service.luau" "$plugin_dir/service.luau"
		install -m644 "$repo_dir/noctalia/widget.luau" "$plugin_dir/widget.luau"
		install -m644 "$repo_dir/noctalia/panel.luau" "$plugin_dir/panel.luau"
		echo "Installed the Noctalia plugin to $plugin_dir"
		if [[ -d "$legacy_plugin_dir" ]]; then
			echo "Note: legacy plugin dir $legacy_plugin_dir still exists;"
			echo "remove it after updating your Noctalia config."
		fi
	else
		echo "Skipping the Noctalia plugin: noctalia/ is not in this bundle."
		install_plugin=false
	fi
fi

echo

config="$config_home/noctalia/config.toml"
if [[ "$install_plugin" == "true" ]]; then
	if grep -q "$plugin_id" "$config" 2>/dev/null; then
		echo "Noctalia config already references $plugin_id."
	elif grep -q "$legacy_plugin_id" "$config" 2>/dev/null; then
		echo "Your Noctalia config still references $legacy_plugin_id."
		echo "Replace it with $plugin_id:"
		echo
		cat <<EOF
[plugins]
enabled = [ "$plugin_id" ]

[widget.mouse_battery]
type = "$plugin_id:battery"
EOF
		echo
	else
		echo "Add this to $config:"
		echo
		cat <<EOF
[plugins]
enabled = [ "$plugin_id" ]

[widget.mouse_battery]
type = "$plugin_id:battery"
EOF
		echo
		echo 'Then add "mouse_battery" to the bar section where you want it, for example:'
		echo
		echo '  [bar.default]'
		echo '  end = [ "network", "mouse_battery", "volume", "session" ]'
		echo
	fi
fi

# EWEADN_UDEV_RULE exists for installer tests; the default remains the system
# path that the documented sudo install command targets.
rule_src="$repo_dir/udev/70-eweadn-linux-control.rules"
rule_dst="${EWEADN_UDEV_RULE:-/etc/udev/rules.d/70-eweadn-linux-control.rules}"
legacy_rule_dst="/etc/udev/rules.d/70-eweadn-battery.rules"

if [[ -f "$rule_src" ]]; then
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

	if [[ "${EWEADN_UDEV_RULE:-}" == "" && -e "$legacy_rule_dst" ]]; then
		echo "Note: legacy rule $legacy_rule_dst still exists;"
		echo "remove it after installing the new rule."
		echo
	fi
fi

if [[ "$install_helper" == "true" ]]; then
	echo "Verify with:"
	echo "  $bin_home/$bin_name --json"
fi
