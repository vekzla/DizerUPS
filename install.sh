#!/bin/bash  
# DizerUPS Automated Installation Script for Raspberry Pi  
# Version: 1.5  
  
set -e  
  
DIZERUPS_VERSION="1.5"  
  
echo "=========================================="  
echo "DizerUPS Automated Installation (v$DIZERUPS_VERSION)"  
echo "=========================================="  
  
# Check if running as root  
if [ "$EUID" -ne 0 ]; then  
    echo "Please run as root (use sudo)"  
    exit 1  
fi  
  
# Get the actual user (not root)  
ACTUAL_USER=${SUDO_USER:-pi}  
ACTUAL_HOME=$(eval echo ~"$ACTUAL_USER")  
ACTUAL_GROUP=$(id -gn "$ACTUAL_USER")  
  
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  
APP_DIR="$ACTUAL_HOME/ups-monitor"  
LOG_DIR="/var/log/ups-monitor"  
  
# -------------------------------------------------  
# Step 1: Install system packages  
# -------------------------------------------------  
echo ""  
echo "Step 1: Installing system packages..."  
apt-get update  
apt-get install -y nut nut-client nut-server python3 python3-venv python3-pip  
  
# -------------------------------------------------  
# Step 2: Set credentials  
# -------------------------------------------------  
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
  
# -------------------------------------------------  
# Step 3: Detect UPS  
# -------------------------------------------------  
echo ""  
echo "Step 3: Detecting UPS..."  
# Release the driver/port so nut-scanner can probe the USB device  
systemctl stop nut-driver.target 2>/dev/null || true  
systemctl stop nut-server 2>/dev/null || true  
upsdrvctl stop 2>/dev/null || true  
  
SCAN_OUTPUT="$(nut-scanner -U 2>/dev/null || true)"  
printf '%s\n' "$SCAN_OUTPUT"  
  
# -------------------------------------------------  
# Step 4: Parse scan output (with fallbacks)  
# -------------------------------------------------  
# Extract the text between the double quotes for each field.  
# Trailing space in the patterns avoids matching productid/vendorid/busport.  
UPS_DRIVER="$(printf  '%s\n' "$SCAN_OUTPUT" | awk -F'"' '/driver /  {print $2; exit}')"  
UPS_PORT="$(printf    '%s\n' "$SCAN_OUTPUT" | awk -F'"' '/port /    {print $2; exit}')"  
UPS_VENDOR="$(printf  '%s\n' "$SCAN_OUTPUT" | awk -F'"' '/vendor /  {print $2; exit}')"  
UPS_PRODUCT="$(printf '%s\n' "$SCAN_OUTPUT" | awk -F'"' '/product / {print $2; exit}')"  
  
# Fallbacks for the CyberPower VP1200ELCD if the scan returns nothing  
UPS_DRIVER="${UPS_DRIVER:-usbhid-ups}"  
UPS_PORT="${UPS_PORT:-auto}"  
UPS_VENDOR="${UPS_VENDOR:-CPS}"  
UPS_PRODUCT="${UPS_PRODUCT:-VP1200ELCD}"  
  
echo ""  
echo "Using UPS configuration:"  
echo "  Driver:  $UPS_DRIVER"  
echo "  Port:    $UPS_PORT"  
echo "  Vendor:  $UPS_VENDOR"  
echo "  Product: $UPS_PRODUCT"  
  
# -------------------------------------------------  
# Step 5: Configure NUT (single-line printf, no here-docs)  
# -------------------------------------------------  
echo ""  
echo "Step 5: Configuring NUT..."  
  
# nut.conf  
echo "MODE=netserver" > /etc/nut/nut.conf  
  
# ups.conf  
printf '[myups]\n    driver = %s\n    port = %s\n    desc = "%s %s"\n' "$UPS_DRIVER" "$UPS_PORT" "$UPS_VENDOR" "$UPS_PRODUCT" > /etc/nut/ups.conf  
  
# upsd.conf  
printf 'LISTEN 0.0.0.0 3493\nMAXAGE 30\n' > /etc/nut/upsd.conf  
  
# upsd.users  
printf '[upsmon]\n    password = %s\n    upsmon master\n' "$NUT_PASSWORD" > /etc/nut/upsd.users  
  
# upsmon.conf  
printf 'MODE = netserver\nMONITOR myups@localhost 1 upsmon %s master\nPOWERDOWNFLAG /etc/killpower\nSHUTDOWNCMD "/sbin/shutdown -h now"\n' "$NUT_PASSWORD" > /etc/nut/upsmon.conf  
  
# Lock down permissions on the NUT config that holds the password  
chown root:nut /etc/nut/upsd.users /etc/nut/upsmon.conf 2>/dev/null || true  
chmod 640 /etc/nut/upsd.users /etc/nut/upsmon.conf 2>/dev/null || true  
  
# -------------------------------------------------  
# Step 6: Deploy application files  
# -------------------------------------------------  
echo ""  
echo "Step 6: Deploying application files..."  
mkdir -p "$APP_DIR"  
mkdir -p "$APP_DIR/templates"  
cp "$SCRIPT_DIR/ups_monitor.py"        "$APP_DIR/"  
cp "$SCRIPT_DIR/config.yaml"           "$APP_DIR/"  
cp "$SCRIPT_DIR/requirements.txt"      "$APP_DIR/"  
cp "$SCRIPT_DIR/templates/dashboard.html" "$APP_DIR/templates/"  
  
# Create log directory  
mkdir -p "$LOG_DIR"  
chown -R "$ACTUAL_USER":"$ACTUAL_GROUP" "$APP_DIR" "$LOG_DIR"  
  
# -------------------------------------------------  
# Step 7: Python virtual environment  
# -------------------------------------------------  
echo ""  
echo "Step 7: Setting up Python environment..."  
python3 -m venv "$APP_DIR/venv"  
"$APP_DIR/venv/bin/pip" install --upgrade pip  
"$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"  
  
# -------------------------------------------------  
# Step 8: Substitute credentials into config.yaml  
# -------------------------------------------------  
echo ""  
echo "Step 8: Writing credentials into config.yaml..."  
# Use | as the sed delimiter so passwords with / or $ don't break substitution.  
sed -i "s|password: CHANGE_ME_NUT|password: $NUT_PASSWORD|"        "$APP_DIR/config.yaml"  
sed -i "s|password: CHANGE_ME_WEB|password: $WEB_PASSWORD|"        "$APP_DIR/config.yaml"  
sed -i "s|username: CHANGE_ME_WEBUSER|username: $WEB_USERNAME|"     "$APP_DIR/config.yaml"  
  
# Keep the log path consistent with the directory created above  
sed -i "s|file: /var/log/ups-monitor.log|file: $LOG_DIR/ups-monitor.log|" "$APP_DIR/config.yaml"  
  
chown "$ACTUAL_USER":"$ACTUAL_GROUP" "$APP_DIR/config.yaml"  
chmod 600 "$APP_DIR/config.yaml"  
  
# -------------------------------------------------  
# Step 9: systemd service for the web monitor  
# -------------------------------------------------  
echo ""  
echo "Step 9: Creating systemd service..."  
printf '[Unit]\nDescription=DizerUPS Web Monitor\nAfter=network-online.target nut-server.service\nWants=network-online.target\n\n[Service]\nType=simple\nUser=%s\nGroup=%s\nWorkingDirectory=%s\nExecStart=%s/venv/bin/python3 %s/ups_monitor.py\nRestart=on-failure\nRestartSec=5\n\n[Install]\nWantedBy=multi-user.target\n' "$ACTUAL_USER" "$ACTUAL_GROUP" "$APP_DIR" "$APP_DIR" "$APP_DIR" > /etc/systemd/system/ups-monitor.service  
  
# -------------------------------------------------  
# Step 10: Enable and start everything  
# -------------------------------------------------  
echo ""  
echo "Step 10: Enabling and starting services..."  
systemctl daemon-reload  
systemctl enable nut-server nut-monitor nut-driver.target 2>/dev/null || true  
systemctl restart nut-driver.target 2>/dev/null || true  
systemctl restart nut-server 2>/dev/null || true  
systemctl restart nut-monitor 2>/dev/null || true  
systemctl enable ups-monitor  
systemctl restart ups-monitor  
  
# Detect LAN IP for the summary  
LAN_IP="$(hostname -I | awk '{print $1}')"  
  
echo ""  
echo "=========================================="  
echo "Installation Complete!"  
echo "=========================================="  
echo ""  
echo "Web dashboard: http://$LAN_IP:5000"  
echo "  Username: $WEB_USERNAME"  
echo "  Password: (the one you entered)"  
echo ""  
echo "NUT Credentials:"  
echo "  Username: upsmon"  
echo "  Password: $NUT_PASSWORD"  
echo ""  
echo "Configuration file: $APP_DIR/config.yaml"  
echo "Log file: $LOG_DIR/ups-monitor.log"  
echo ""  
echo "To manage the service:"  
echo "  sudo systemctl status ups-monitor"  
echo "  sudo systemctl restart ups-monitor"  
echo "  sudo systemctl stop ups-monitor"  
echo ""  
echo "To test NUT manually:"  
echo "  upsc myups@localhost"  
echo ""
