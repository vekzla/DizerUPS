# Complete UPS/NUT/DizerUPS Uninstallation Instructions

Run these commands on your Raspberry Pi to completely remove everything related to UPS monitoring:

```bash
# Stop all NUT and DizerUPS services
sudo systemctl stop ups-monitor 2>/dev/null || true
sudo systemctl disable ups-monitor 2>/dev/null || true
sudo systemctl unmask ups-monitor 2>/dev/null || true
sudo systemctl stop nut-server 2>/dev/null || true
sudo systemctl disable nut-server 2>/dev/null || true
sudo systemctl stop upsd 2>/dev/null || true
sudo systemctl disable upsd 2>/dev/null || true
sudo systemctl stop nut-monitor 2>/dev/null || true
sudo systemctl disable nut-monitor 2>/dev/null || true
sudo systemctl stop nut-driver-enumerator 2>/dev/null || true
sudo systemctl disable nut-driver-enumerator 2>/dev/null || true
sudo systemctl stop nut-driver 2>/dev/null || true
sudo systemctl disable nut-driver 2>/dev/null || true

# Remove systemd service files
sudo rm -f /etc/systemd/system/ups-monitor.service
sudo rm -f /etc/systemd/system/upsd.service
sudo systemctl daemon-reload
sudo systemctl reset-failed ups-monitor 2>/dev/null || true

# Remove application directories
rm -rf ~/ups-monitor
rm -rf ~/DizerUPS
sudo rm -rf /var/log/ups-monitor

# Remove log files
rm ~/ups-monitor.log 2>/dev/null || true

# Remove NUT configuration files
sudo rm -f /etc/nut/nut.conf
sudo rm -f /etc/nut/ups.conf
sudo rm -f /etc/nut/upsd.conf
sudo rm -f /etc/nut/upsd.users
sudo rm -f /etc/nut/upsmon.conf
sudo rm -f /etc/nut/nut.conf.bak
sudo rm -f /etc/nut/ups.conf.bak
sudo rm -f /etc/nut/upsd.conf.bak
sudo rm -f /etc/nut/upsd.users.bak
sudo rm -f /etc/nut/upsmon.conf.bak

# Remove NUT database files
sudo rm -rf /var/lib/nut

# Remove NUT runtime files
sudo rm -rf /run/nut

# Completely remove NUT packages
sudo apt remove --purge -y nut nut-client nut-server nut-monitor
sudo apt autoremove -y

# Verify removal
sudo systemctl status ups-monitor 2>/dev/null || echo "ups-monitor service removed"
sudo systemctl status nut-server 2>/dev/null || echo "nut-server service removed"
ls -la ~ | grep -E "ups-monitor|DizerUPS" || echo "Application directories removed"
```

After running these commands, your Raspberry Pi will have no UPS monitoring software installed.
