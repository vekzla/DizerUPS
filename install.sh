#!/bin/bash  
# DizerUPS Automated Installation Script for Raspberry Pi  
# Version: 1.0 
  
set -e  
  
DIZERUPS_VERSION="1.0"  
  
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
ACTUAL_HOME=$(eval echo ~$ACTUAL_USER)  
ACTUAL_GROUP=$(id -gn $ACTUAL_USER)  
  
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  
APP_DIR="$ACTUAL_HOME/ups-monitor"  
LOG_DIR="/var/log/ups-monitor"  
  
# Check for existing installation  
if [ -d "$APP_DIR" ] || systemctl is-active --quiet ups-monitor; then  
    echo ""  
    echo "=========================================="  
    echo "Existing installation detected"  
    echo "=========================================="  
    echo "1) Fresh install (remove existing and reinstall)"  
    echo "2) Update (keep config.yaml, refresh code)"  
    echo "3) Cancel"  
    read -p "Choose an option (1/2/3): " INSTALL_MODE  
    case "$INSTALL_MODE" in  
        1) echo "Performing fresh install..."; systemctl stop ups-monitor 2>/dev/null || true; rm -rf "$APP_DIR" ;;  
        2) echo "Performing update..." ;;  
        *) echo "Installation cancelled."; exit 0 ;;  
    esac  
fi  
  
# Step 1: Update system packages  
echo "Step 1: Updating system packages..."  
apt-get update  
apt-get upgrade -y  
  
# Step 2: Install system dependencies  
echo "Step 2: Installing system dependencies..."  
apt-get install -y python3 python3-pip python3-venv nut nut-client sqlite3  
  
# Step 3: Stop NUT services and driver (release USB before scanning)  
echo "Step 3: Stopping NUT services and driver..."  
systemctl stop nut-monitor nut-server nut-driver.target 2>/dev/null || true  
upsdrvctl stop 2>/dev/null || true  
  
# Step 4: Scan for UPS devices (informational only)  
echo "Step 4: Scanning for UPS devices (informational)..."  
SCAN_OUTPUT=$(nut-scanner -U 2>/dev/null || true)  
if [ -n "$SCAN_OUTPUT" ]; then  
    echo "UPS devices found:"  
    echo "$SCAN_OUTPUT"  
fi  
# Default to the known-good CyberPower config regardless of scan result  
UPS_DRIVER="usbhid-ups"  
UPS_PORT="auto"  
UPS_VENDOR="CPS"  
UPS_PRODUCT="VP1200ELCD"  
echo "Using UPS configuration:"  
echo "  Driver: $UPS_DRIVER"  
echo "  Port: $UPS_PORT"  
  
# Step 5: Configure NUT (printf-based, no here-docs)  
echo "Step 5: Configuring NUT..."  
  
# nut.conf  
echo "MODE=netserver" > /etc/nut/nut.conf  
  
# ups.conf  
{  
    printf '[myups]\n'  
    printf '    driver = %s\n' "$UPS_DRIVER"  
    printf '    port = %s\n' "$UPS_PORT"  
    printf '    desc = "%s %s"\n' "$UPS_VENDOR" "$UPS_PRODUCT"  
} > /etc/nut/ups.conf  
  
# upsd.conf  
{  
    printf 'LISTEN 0.0.0.0 3493\n'  
    printf 'MAXAGE 30\n'  
} > /etc/nut/upsd.conf  
  
# Step 6: Prompt for NUT password  
echo ""  
echo "Step 6: Setting NUT password..."  
read -p "Enter NUT password (default: secretpass): " NUT_PASSWORD  
NUT_PASSWORD=${NUT_PASSWORD:-secretpass}  
if [ ${#NUT_PASSWORD} -lt 6 ]; then  
    echo "Password must be at least 6 characters."  
    exit 1  
fi  
  
# upsd.users  
{  
    printf '[upsmon]\n'  
    printf '    password = %s\n' "$NUT_PASSWORD"  
    printf '    upsmon master\n'  
} > /etc/nut/upsd.users  
  
# upsmon.conf  
{  
    printf 'MODE = netserver\n'  
    printf 'MONITOR myups@localhost 1 upsmon %s master\n' "$NUT_PASSWORD"  
    printf 'POWERDOWNFLAG /etc/killpower\n'  
    printf 'SHUTDOWNCMD "/sbin/shutdown -h now"\n'  
} > /etc/nut/upsmon.conf  
  
# Lock down permissions on the credential files  
chown root:nut /etc/nut/upsd.users /etc/nut/upsmon.conf 2>/dev/null || true  
chmod 640 /etc/nut/upsd.users /etc/nut/upsmon.conf 2>/dev/null || true  
  
# Step 7: Start NUT services and driver  
echo "Step 7: Starting NUT services..."  
upsdrvctl start 2>/dev/null || true  
systemctl restart nut-server 2>/dev/null || true  
systemctl restart nut-monitor 2>/dev/null || true  
systemctl enable nut-server nut-monitor 2>/dev/null || true  
sleep 3  
  
# Step 8: Confirm the driver is delivering live data (hard check)  
echo "Step 8: Confirming UPS driver is working..."  
if upsc myups@localhost > /dev/null 2>&1; then  
    echo "Driver confirmed. Live values:"  
    upsc myups@localhost 2>/dev/null | grep -E 'battery.charge|ups.status|input.voltage' || true  
else  
    echo "WARNING: Could not read live data from myups@localhost."  
    echo "Check: journalctl -u nut-driver-enumerator -u nut-server"  
    read -p "Continue anyway? (y/n): " CONT  
    if [ "$CONT" != "y" ] && [ "$CONT" != "Y" ]; then  
        echo "Aborting install."  
        exit 1  
    fi  
fi  
  
# Step 9: Deploy application files  
echo "Step 9: Deploying application files..."  
mkdir -p "$APP_DIR"  
cp -r "$SCRIPT_DIR"/* "$APP_DIR/"  
chown -R "$ACTUAL_USER:$ACTUAL_GROUP" "$APP_DIR"  
  
# Step 10: Create Python virtual environment  
echo "Step 10: Creating Python virtual environment..."  
sudo -u "$ACTUAL_USER" python3 -m venv "$APP_DIR/venv"  
  
# Step 11: Install Python dependencies  
echo "Step 11: Installing Python dependencies..."  
sudo -u "$ACTUAL_USER" "$APP_DIR/venv/bin/pip" install --upgrade pip  
sudo -u "$ACTUAL_USER" "$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"  
  
# Step 12: Prompt for web credentials  
echo ""  
echo "Step 12: Setting web dashboard credentials..."  
read -p "Enter web username (default: admin): " WEB_USERNAME  
WEB_USERNAME=${WEB_USERNAME:-admin}  
read -p "Enter web password (default: secretpass): " WEB_PASSWORD  
WEB_PASSWORD=${WEB_PASSWORD:-secretpass}  
  
# Step 13: Inject credentials into config.yaml  
echo "Step 13: Writing config.yaml..."  
CONFIG_FILE="$APP_DIR/config.yaml"  
# Use '|' as the sed delimiter so '/' and '$' in passwords don't break substitution  
sed -i "s|your_nut_password_here|$NUT_PASSWORD|" "$CONFIG_FILE"  
sed -i "s|your_web_password_here|$WEB_PASSWORD|" "$CONFIG_FILE"  
sed -i "s|username: admin|username: $WEB_USERNAME|" "$CONFIG_FILE"  
chown "$ACTUAL_USER:$ACTUAL_GROUP" "$CONFIG_FILE"  
  
# Step 14: Install systemd service (printf-based)  
echo "Step 14: Installing systemd service..."  
{  
    printf '[Unit]\n'  
    printf 'Description=UPS Monitor Service\n'  
    printf 'After=network.target nut-server.service\n\n'  
    printf '[Service]\n'  
    printf 'Type=simple\n'  
    printf 'User=%s\n' "$ACTUAL_USER"  
    printf 'Group=%s\n' "$ACTUAL_GROUP"  
    printf 'WorkingDirectory=%s\n' "$APP_DIR"  
    printf 'ExecStart=%s/venv/bin/python3 %s/ups_monitor.py\n' "$APP_DIR" "$APP_DIR"  
    printf 'Restart=on-failure\n'  
    printf 'RestartSec=10\n\n'  
    printf '[Install]\n'  
    printf 'WantedBy=multi-user.target\n'  
} > /etc/systemd/system/ups-monitor.service  
  
# Step 15: Configure firewall (if ufw is present)  
echo "Step 15: Configuring firewall..."  
if command -v ufw > /dev/null 2>&1; then  
    ufw allow 5000/tcp 2>/dev/null || true  
fi  
  
# Step 16: Create log directory  
echo "Step 16: Creating log directory..."  
mkdir -p "$LOG_DIR"  
chown -R "$ACTUAL_USER:$ACTUAL_GROUP" "$LOG_DIR"  
  
# Step 17: Enable and start the service  
echo "Step 17: Starting DizerUPS service..."  
systemctl daemon-reload  
systemctl enable ups-monitor  
systemctl restart ups-monitor  
sleep 3  
  
# Step 18: Check service status  
echo ""  
echo "Checking service status..."  
systemctl status ups-monitor --no-pager || true  
  
echo ""  
echo "=========================================="  
echo "Installation Complete!"  
echo "=========================================="  
echo ""  
PI_IP=$(hostname -I | awk '{print $1}')  
echo "Web Dashboard: http://$PI_IP:5000"  
echo ""  
echo "Web Interface Credentials:"  
echo "  Username: $WEB_USERNAME"  
echo "  Password: $WEB_PASSWORD"  
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
echo "To change credentials later, edit:"  
echo "  $APP_DIR/config.yaml"  
echo ""  
echo "Security reminders:"  
echo "  - Change default passwords if you used them"  
echo "  - Consider enabling HTTPS with a reverse proxy"  
echo "  - Keep your Raspberry Pi system updated"  
echo ""
