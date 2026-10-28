## Install and configure

find your monitor’s serial number:

```bash
ddcutil detect
```

create the configuration file, replacing the example values with your monitor’s serial number and model:

```bash
mkdir -p ~/.config
cat > ~/.config/sunshine-screen.conf <<'EOF'
MONITOR_SERIAL='REPLACE_WITH_YOUR_MONITOR_SERIAL'
MONITOR_NAME='Your monitor model'
DIM_PERCENT=10
EOF
```

Install the script from the repository directory:

```bash
install -Dm755 sunshine-screen.sh ~/.local/bin/sunshine-screen.sh
```

If the script is in a subdirectory, use its path instead. For example:

```bash
install -Dm755 scripts/sunshine-screen.sh ~/.local/bin/sunshine-screen.sh
```

check the script and show the detected brightness:

```bash
bash -n ~/.local/bin/sunshine-screen.sh
~/.local/bin/sunshine-screen.sh status
```

## Usage

```bash
~/.local/bin/sunshine-screen.sh off
~/.local/bin/sunshine-screen.sh on
~/.local/bin/sunshine-screen.sh status
```

`off` dims the monitor to the configured percentage; it does not power the monitor off. `on` restores the brightness saved when `off` was first run.
