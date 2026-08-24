#!/bin/bash  
# DizerUPS Automated Installation Script for Raspberry Pi  
# Version: 1.2  
  
set -e  
  
DIZERUPS_VERSION="1.2"  
  
echo "=========================================="  
echo "DizerUPS Automated Installation (v$DIZERUPS_VERSION)"  
echo "=========================================="  
  
# Must run as root  
if [ "$EUID" -ne 0 ]; then  
    echo "Please run as root (use sudo)"  
    exit 1  
fi  
  
# Resolve the real (non-root) user  
ACTUAL_USER=${SUDO_USER:-pi}  
ACTUAL_HOME=$(eval echo ~"$ACTUAL_USER")  
ACTUAL_GROUP=$(id -gn "$ACTUAL_USER")  
  
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  
APP_DIR="$ACTUAL_HOME/ups-monitor"  
LOG_DIR="/var/log/ups-monitor"  
  
# ------------------------------------------------------------------  
# Step 1: Install system packages  
# ------------------------------------------------------------------  
echo ""  
echo "Step 1: Installing system packages..."  
apt-get update  
apt-get install -y nut nut-client nut-server python3 python3-venv python3-pip usbutils  
  
# ------------------------------------------------------------------  
# Step 2: Prompt for credentials (NUT + web)  
# ------------------------------------------------------------------  
echo ""  
echo "Step 2: Setting credentials..."  
  
read -p "Enter NUT password (min 6 chars, default: secretpass): " NUT_PASSWORD  
NUT_PASSWORD=${NUT_PASSWORD:-secretpass}  
if [ ${#NUT_PASSWORD} -lt 6 ]; then  
    echo "NUT password must be at least 6 characters."  
    exit 1  
fi  
  
read -p "Enter web dashboard username (default: admin): " WEB_USERNAME  
WEB_USERNAME=${WEB_USERNAME:-admin}  
  
read -p "Enter web dashboard password (min 6 chars, default: dizerups): " WEB_PASSWORD  
WEB_PASSWORD=${WEB_PASSWORD:-dizerups}  
if [ ${#WEB_PASSWORD} -lt 6 ]; then  
    echo "Web password must be at least 6 characters."  
    exit 1  
fi  
  
# ------------------------------------------------------------------  
# Step 3: Release any running NUT driver, then scan (informational)  
# ------------------------------------------------------------------  
echo ""  
echo "Step 3: Detecting UPS..."  
systemctl stop nut-driver-enumerator 2>/dev/null || true  
systemctl stop nut-server 2>/dev/null || true  
upsdrvctl stop 2>/dev/null || true  
sleep 1  
  
echo "Scanning for UPS devices (informational):"  
nut-scanner -U 2>/dev/null || echo "  (nut-scanner produced no output; using defaults)"  
  
# Fixed config for the CyberPower VP1200ELCD (usbhid-ups / auto)  
UPS_DRIVER="usbhid-ups"  
UPS_PORT="auto"  
UPS_DESC="CyberPower VP1200ELCD"  
  
# ------------------------------------------------------------------  
# Step 4: Write NUT config (printf — no here-docs, whitespace-safe)  
# ------------------------------------------------------------------  
echo ""  
echo "Step 4: Configuring NUT..."  
  
printf 'MODE=netserver\n' > /etc/nut/nut.conf  
  
printf '[myups]\n    driver = %s\n    port = %s\n    desc = "%s"\n' \  
    "$UPS_DRIVER" "$UPS_PORT" "$UPS_DESC" > /etc/nut/ups.conf  
  
printf 'LISTEN 0.0.0.0 3493\nMAXAGE 30\n' > /etc/nut/upsd.conf  
  
printf '[upsmon]\n    password = %s\n    upsmon master\n' \  
    "$NUT_PASSWORD" > /etc/nut/upsd.users  
  
printf 'MODE = netserver\nMONITOR myups@localhost 1 upsmon %s master\nPOWERDOWNFLAG /etc/killpower\nSHUTDOWNCMD "/sbin/shutdown -h now"\n' \  
    "$NUT_PASSWORD" > /etc/nut/upsmon.conf  
  
chown root:nut /etc/nut/*.conf /etc/nut/upsd.users  
chmod 640 /etc/nut/*.conf /etc/nut/upsd.users  
  
# ------------------------------------------------------------------  
# Step 5: Start NUT services  
# ------------------------------------------------------------------  
echo ""  
echo "Step 5: Starting NUT services..."  
systemctl enable nut-server nut-monitor 2>/dev/null || true  
upsdrvctl start 2>/dev/null || true  
systemctl restart nut-server  
systemctl restart nut-monitor 2>/dev/null || true  
sleep 3  
  
# ------------------------------------------------------------------  
# Step 6: Confirm the driver is delivering live data  
# ------------------------------------------------------------------  
echo ""  
echo "Step 6: Confirming UPS driver..."  
if upsc myups@localhost ups.status >/dev/null 2>&1; then  
    echo "  Driver confirmed. Live status: $(upsc myups@localhost ups.status 2>/dev/null)"  
else  
    echo "  ERROR: could not read myups@localhost."  
    echo "  Check 'lsusb' for the UPS and 'upsdrvctl -D start' for driver errors."  
    exit 1  
fi  
  
# ------------------------------------------------------------------  
# Step 7: Deploy application files  
# ------------------------------------------------------------------  
echo ""  
echo "Step 7: Installing application..."  
mkdir -p "$APP_DIR/templates"  
cp "$SCRIPT_DIR/ups_monitor.py" "$APP_DIR/"  
cp "$SCRIPT_DIR/config.yaml"    "$APP_DIR/"  
cp "$SCRIPT_DIR/requirements.txt" "$APP_DIR/"  
cp "$SCRIPT_DIR/templates/dashboard.html" "$APP_DIR/templates/"  
  
# ------------------------------------------------------------------  
# Step 8: Write config.yaml credentials DIRECTLY (no placeholder sed)  
# ------------------------------------------------------------------  
echo ""  
echo "Step 8: Writing credentials into config.yaml..."  
python3 - "$APP_DIR/config.yaml" "$NUT_PASSWORD" "$WEB_USERNAME" "$WEB_PASSWORD" <<'PYEOF'  
import sys, yaml  
path, nut_pw, web_user, web_pw = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]  
with open(path) as f:  
    cfg = yaml.safe_load(f)  
cfg.setdefault('ups', {}).setdefault('nut', {})['password'] = nut_pw  
cfg.setdefault('web', {})['username'] = web_user  
cfg.setdefault('web', {})['password'] = web_pw  
with open(path, 'w') as f:  
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)  
print("  Credentials written (web user: %s)" % web_user)  
PYEOF  
  
# ------------------------------------------------------------------  
# Step 9: Python virtual environment  
# ------------------------------------------------------------------  
echo ""  
echo "Step 9: Setting up Python environment..."  
python3 -m venv "$APP_DIR/venv"  
"$APP_DIR/venv/bin/pip" install --upgrade pip  
"$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"  
  
# ------------------------------------------------------------------  
# Step 10: Log directory + ownership  
# ------------------------------------------------------------------  
echo ""  
echo "Step 10: Creating log directory..."  
mkdir -p "$LOG_DIR"  
chown -R "$ACTUAL_USER":"$ACTUAL_GROUP" "$LOG_DIR" "$APP_DIR"  
  
# ------------------------------------------------------------------  
# Step 11: systemd service (printf — no here-doc)  
# ------------------------------------------------------------------  
echo ""  
echo "Step 11: Installing systemd service..."  
printf '[Unit]\nDescription=DizerUPS Monitor\nAfter=network.target nut-server.service\n\n[Service]\nType=simple\nUser=%s\nGroup=%s\nWorkingDirectory=%s\nExecStart=%s/venv/bin/python3 %s/ups_monitor.py\nRestart=always\nRestartSec=5\n\n[Install]\nWantedBy=multi-user.target\n' \  
    "$ACTUAL_USER" "$ACTUAL_GROUP" "$APP_DIR" "$APP_DIR" "$APP_DIR" \  
    > /etc/systemd/system/ups-monitor.service  
  
systemctl daemon-reload  
systemctl enable ups-monitor  
systemctl restart ups-monitor  
  
# ------------------------------------------------------------------  
# Step 12: Firewall (optional, allow dashboard port on LAN)  
# ------------------------------------------------------------------  
if command -v ufw >/dev/null 2>&1; then  
    ufw allow 5000/tcp 2>/dev/null || true  
fi  
  
# ------------------------------------------------------------------  
# Done  
# ------------------------------------------------------------------  
sleep 2  
echo ""  
echo "=========================================="  
echo "Installation Complete! (v$DIZERUPS_VERSION)"  
echo "=========================================="  
echo ""  
echo "Web Dashboard: http://$(hostname -I | awk '{print $1}'):5000"  
echo "  Username: $WEB_USERNAME"  
echo "  Password: (the web password you entered)"  
echo ""  
echo "NUT Credentials:"  
echo "  Username: upsmon"  
echo "  Password: (the NUT password you entered)"  
echo ""  
echo "Config file: $APP_DIR/config.yaml"  
echo "Log file:    $LOG_DIR/ups-monitor.log"  
echo ""  
echo "Service management:"  
echo "  sudo systemctl status ups-monitor"  
echo "  sudo systemctl restart ups-monitor"  
echo ""  
echo "Test NUT manually:  upsc myups@localhost"  
echo ""  
echo "Service status:"  
systemctl status ups-monitor --no-pager || true
