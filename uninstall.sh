#!/bin/bash  
# DizerUPS Uninstallation Script for Raspberry Pi  
# Version: 1.1  
  
set -e  
  
echo "=========================================="  
echo "DizerUPS Uninstallation"  
echo "=========================================="  
  
# Check if running as root  
if [ "$EUID" -ne 0 ]; then  
    echo "Please run as root (use sudo)"  
    exit 1  
fi  
  
# Get the actual user (not root)  
ACTUAL_USER=${SUDO_USER:-pi}  
ACTUAL_HOME=$(eval echo ~$ACTUAL_USER)  
  
APP_DIR="$ACTUAL_HOME/ups-monitor"  
DIZERUPS_DIR="$ACTUAL_HOME/DizerUPS"  
LOG_DIR="/var/log/ups-monitor"  
  
# Run from home so we don't rm -rf our own working directory  
cd "$ACTUAL_HOME"  
  
echo ""  
echo "This will remove:"  
echo "  - Systemd service: ups-monitor"  
echo "  - Application directory: $APP_DIR"  
echo "  - DizerUPS directory: $DIZERUPS_DIR"  
echo "  - Log directory: $LOG_DIR"  
echo "  - NUT configuration backups (if any)"  
echo "  - Firewall rule for port 5000 (if present)"  
echo ""  
read -p "Are you sure you want to uninstall DizerUPS? (y/n): " CONFIRM  
  
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then  
    echo "Uninstallation cancelled."  
    exit 0  
fi  
  
echo ""  
echo "Stopping and disabling ups-monitor service..."  
systemctl stop ups-monitor 2>/dev/null || true  
systemctl disable ups-monitor 2>/dev/null || true  
systemctl unmask ups-monitor 2>/dev/null || true  
  
echo "Removing systemd service..."  
rm -f /etc/systemd/system/ups-monitor.service  
rm -f /etc/systemd/system/upsd.service  
systemctl daemon-reload  
systemctl reset-failed ups-monitor 2>/dev/null || true  
  
echo "Stopping and disabling NUT services (releasing the UPS)..."  
systemctl stop nut-monitor 2>/dev/null || true  
systemctl stop nut-server 2>/dev/null || true  
systemctl stop upsd 2>/dev/null || true  
systemctl stop nut-driver-enumerator 2>/dev/null || true  
systemctl stop nut-driver.target 2>/dev/null || true  
systemctl stop 'nut-driver@*' 2>/dev/null || true  
upsdrvctl stop 2>/dev/null || true  
systemctl disable nut-monitor nut-server nut-driver-enumerator nut.target 2>/dev/null || true  
systemctl daemon-reload  
  
echo "Removing application directory..."  
rm -rf "$APP_DIR"  
  
echo "Removing DizerUPS directory..."  
rm -rf "$DIZERUPS_DIR"  
  
echo "Removing log directory..."  
rm -rf "$LOG_DIR"  
  
echo "Removing log file from home directory..."  
rm -f "$ACTUAL_HOME/ups-monitor.log"  
  
# Revert firewall rule that install.sh may have added  
if command -v ufw &> /dev/null; then  
    echo "Removing firewall rule for port 5000 (if present)..."  
    ufw delete allow 5000/tcp 2>/dev/null || true  
fi  
  
# Optionally purge NUT entirely (removes /etc/nut with the stored password)  
echo ""  
read -p "Also purge NUT and its configuration (removes stored UPS password)? (y/n): " PURGE_NUT  
if [ "$PURGE_NUT" = "y" ] || [ "$PURGE_NUT" = "Y" ]; then  
    echo "Purging NUT packages and configuration..."  
    apt remove --purge -y nut nut-client nut-server nut-monitor 2>/dev/null || true  
    rm -rf /etc/nut  
    rm -rf /var/lib/nut  
    rm -rf /run/nut  
    apt autoremove -y 2>/dev/null || true  
    echo "NUT and /etc/nut removed."  
else  
    echo "Leaving NUT installed. Removing DizerUPS-related NUT files..."  
    # Remove backups created during install  
    rm -f /etc/nut/nut.conf.bak  
    rm -f /etc/nut/ups.conf.bak  
    rm -f /etc/nut/upsd.conf.bak  
    rm -f /etc/nut/upsd.users.bak  
    rm -f /etc/nut/upsmon.conf.bak  
    # Scrub the stored credentials from the live users file  
    if [ -f /etc/nut/upsd.users ]; then  
        rm -f /etc/nut/upsd.users  
        echo "Removed /etc/nut/upsd.users (contained the UPS password)."  
    fi  
fi  
  
# Optionally remove unattended-upgrades if it was enabled during install  
echo ""  
read -p "Remove unattended-upgrades (only if DizerUPS installed it)? (y/n): " REMOVE_UPD  
if [ "$REMOVE_UPD" = "y" ] || [ "$REMOVE_UPD" = "Y" ]; then  
    apt remove --purge -y unattended-upgrades 2>/dev/null || true  
    echo "unattended-upgrades removed."  
fi  
  
# Verify removal  
echo ""  
echo "Verifying removal..."  
systemctl status ups-monitor >/dev/null 2>&1 || echo "  ups-monitor service removed"  
systemctl status nut-server >/dev/null 2>&1 || echo "  nut-server service removed"  
ls -la "$ACTUAL_HOME" | grep -E "ups-monitor|DizerUPS" >/dev/null 2>&1 || echo "  Application directories removed"  
  
echo ""  
echo "=========================================="  
echo "Uninstallation Complete!"  
echo "=========================================="  
echo ""  
echo "DizerUPS has been removed from your system."  
echo ""  
if [ "$PURGE_NUT" != "y" ] && [ "$PURGE_NUT" != "Y" ]; then  
    echo "Note: NUT (Network UPS Tools) is still installed."  
    echo "To remove NUT as well, run:"  
    echo "  sudo apt remove --purge nut nut-client nut-server"  
    echo "  sudo rm -rf /etc/nut"  
    echo ""  
fi
