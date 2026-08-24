# DizerUPS - Raspberry Pi UPS Monitor
  
A comprehensive UPS monitoring solution for Raspberry Pi with real-time web dashboard, calculated power metrics, automated alerts, and system shutdown capabilities.  
  
## Features  
  
- **Real-time Web Dashboard**: Monitor UPS status, battery levels, load, and more  
- **NUT-based Monitoring**: Reads live data via the `upsc` command (Network UPS Tools)  
- **Calculated Metrics**: Derives input/load/battery current and real power from `ups.load`, `ups.realpower.nominal`, and voltages when the UPS does not report them directly  
- **Frequency Display**: Shows input frequency with automatic deci-Hz correction (e.g. `498.0` -> `49.8 Hz`)  
- **Automated Alerts**: Logs low-battery and high-load events  
- **Manual Refresh**: On-demand refresh button in addition to the 10-second auto-refresh  
- **Manual/Emergency Shutdown**: `POST /api/shutdown` route with a dashboard button (gated behind auth and the `shutdown.enabled` config flag)  
- **Auto Shutdown**: Configurable automatic system shutdown on low battery  
- **Historical Data**: SQLite database stores UPS status history (including `input_frequency`)  
- **Event Logging**: Track important UPS events and system changes  
- **Bar Graph Visualizations**: Visual representation of voltage, current, load, and frequency metrics  
- **Fault Detection**: Display UPS faults and status codes (`OL`, `OB`, `LB`, `RB`, `FSD`, `OFF`, `OVER`)  
- **Legend & Calculations Card**: Explains NUT status abbreviations and how the derived metrics are computed  
  
## Requirements  
  
- Raspberry Pi (tested on Pi 4)  
- Raspberry Pi OS (Debian-based; tested on Trixie / Python 3.13)  
- UPS device compatible with NUT  
- Internet connection for package installation  
- MicroSD card (16GB+ recommended)  
  
> **Note:** Test this yourself before deploying 
  
## Quick Installation (Recommended)  
  
```bash  
# Clone the repository  
cd ~  
git clone https://github.com/vekzla/DizerUPS  
cd DizerUPS  
  
# Make the script executable and run it  
chmod +x install.sh  
sudo bash install.sh  
```  
  
The installer will:  
1. Update system packages and install dependencies (Python, NUT, SQLite)  
2. Scan for your USB UPS device (informational)  
3. Configure NUT (`ups.conf`, `upsd.conf`, `upsd.users`, `upsmon.conf`, `nut.conf`)  
4. Prompt for NUT and web dashboard credentials  
5. Create a Python virtual environment and install requirements  
6. Confirm the driver is delivering live data via `upsc`  
7. Install and start the `ups-monitor` systemd service  
  
## Configuration  
  
Edit `~/ups-monitor/config.yaml` to change settings after install:  
  
```yaml  
ups:  
  type: nut  
  nut:  
    host: localhost  
    port: 3493  
    ups_name: myups  
  
web:  
  host: 0.0.0.0  
  port: 5000  
  username: admin  
  password: your_web_password_here  
  
logging:  
  file: /var/log/ups-monitor/ups-monitor.log  
  level: INFO  
  max_size_mb: 10  
  backup_count: 5  
  
alerts:  
  low_battery_threshold: 20  
  high_load_threshold: 80  
  
shutdown:  
  enabled: false  
  low_battery_threshold: 10  
  delay_seconds: 60  
  
logging_interval: 60  
```  
  
## Calculated Metrics  
  
Many UPS models (e.g. CyberPower VP1200ELCD) do not report current directly. DizerUPS derives these values:  
  
- **Real Power (W)** = `ups.load%` × `ups.realpower.nominal`  
  - Example: `15% × 720W = 108W`  
- **Load/Output Current (A)** = `power / output.voltage`  
  - Example: `108 / 246 ≈ 0.44 A`  
- **Input Current (A)** = `power / input.voltage`  
  - Example: `108 / 248 ≈ 0.44 A`  
- **Battery Current (A)** = `power / battery.voltage` while `ups.status` is `DISCHRG`; otherwise `0 A` (on line power)  
- **Input Frequency (Hz)** = `input.frequency`, divided by 10 when the raw value is reported in deci-Hz (e.g. `498.0` -> `49.8 Hz`)  
  
Real NUT values are preferred when present; the calculations are used only as fallbacks.  
  
## UPS Status Codes (NUT)  
  
| Code   | Meaning                                    |  
|--------|--------------------------------------------|  
| `OL`   | On Line (running on mains power) — normal  |  
| `OB`   | On Battery (mains lost)                     |  
| `LB`   | Low Battery                                |  
| `RB`   | Replace Battery                            |  
| `CHRG` | Battery charging                           |  
| `DISCHRG` | Battery discharging                     |  
| `FSD`  | Forced Shutdown                            |  
| `OFF`  | UPS output is off                          |  
| `OVER` | Overload                                   |  
  
## Web Dashboard  
  
Access at `http://<pi-ip>:5000`  
  
Features:  
- Live tiles for battery, load, input/output voltage, input frequency (Hz), and calculated currents  
- Manual **Refresh** button (plus auto-refresh every 10 seconds)  
- **Shutdown** button (requires `shutdown.enabled: true` and passwordless sudo)  
- Legend & Calculations card explaining status codes and derived metrics  
- Event history panel  
  
## API Endpoints  
  
- `GET /api/status` - Current UPS status (includes `input_frequency`, calculated currents)  
- `GET /api/history?hours=24` - Historical data  
- `GET /api/events?limit=50` - Recent events  
- `POST /api/shutdown` - Trigger emergency shutdown (auth + `shutdown.enabled` required)  
  
## Enabling the Shutdown Button  
  
1. Set `shutdown.enabled: true` in `config.yaml`.  
2. Grant the service user passwordless sudo for shutdown via `sudo visudo -f /etc/sudoers.d/dizerups-shutdown`:  
   ```  
   'user' ALL=(root) NOPASSWD: /sbin/shutdown  
   ```  
   Replace `user` with your service/account user.  
  
## Managing the Service  
  
```bash  
sudo systemctl status ups-monitor  
sudo systemctl restart ups-monitor  
sudo systemctl stop ups-monitor  
```  
  
## Testing NUT Manually  
  
```bash  
upsc myups@localhost  
```  
  
## Troubleshooting  
  
**Data Not Displaying**  
```bash  
# Check the service logs  
sudo journalctl -u ups-monitor -n 50 --no-pager  
  
# Verify NUT is delivering live data  
upsc myups@localhost  
```  
## Uninstallation  
  
```bash  
cd ~/DizerUPS  
sudo bash uninstall.sh  
```  
  
## Security Recommendations  
  
1. Change default passwords immediately after installation  
2. Consider restricting web interface to localhost only  
3. Enable firewall rules to limit access  
4. Use HTTPS with a reverse proxy (nginx, apache)  
5. Keep your Raspberry Pi system updated  
6. Enable automatic security updates  
  
## Supported UPS Devices  
  
DizerUPS works with any UPS device supported by NUT (Network UPS Tools). Popular brands include:  
- APC  
- CyberPower  
- Eaton  
- Tripp Lite  
- And many more  
  
Check [NUT device compatibility](https://networkupstools.org/stable-hcl.html) for your specific model.  
  
## License  
  
This project is open source. See LICENSE file for details.
