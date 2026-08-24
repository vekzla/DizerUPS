#!/usr/bin/env python3  
"""  
DizerUPS - Raspberry Pi UPS Monitor  
Automated UPS monitoring with web dashboard  
Version: 1.0  
"""  
  
__version__ = "1.0"  
  
import os  
import sys  
import logging  
import logging.handlers  
import sqlite3  
import subprocess  
import yaml  
import requests  
from datetime import datetime, timedelta  
from flask import Flask, render_template, jsonify, request, Response  
  
from apscheduler.schedulers.background import BackgroundScheduler  
  
# Load configuration  
def load_config():  
    config_path = os.path.join(os.path.dirname(__file__), 'config.yaml')  
    try:  
        with open(config_path, 'r') as f:  
            return yaml.safe_load(f)  
    except FileNotFoundError:  
        print(f"Config file not found at {config_path}")  
        sys.exit(1)  
    except yaml.YAMLError as e:  
        print(f"Error parsing config: {e}")  
        sys.exit(1)  
  
config = load_config()  
  
# Setup logging  
def setup_logging():  
    log_config = config.get('logging', {})  
    log_file = log_config.get('file', '/var/log/ups-monitor/ups-monitor.log')  
    log_level = getattr(logging, log_config.get('level', 'INFO').upper(), logging.INFO)  
    max_bytes = log_config.get('max_size_mb', 10) * 1024 * 1024  
    backup_count = log_config.get('backup_count', 5)  
  
    logger = logging.getLogger('ups_monitor')  
    logger.setLevel(log_level)  
  
    formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')  
  
    # Console handler  
    ch = logging.StreamHandler()  
    ch.setFormatter(formatter)  
    logger.addHandler(ch)  
  
    # Rotating file handler (non-fatal if the path isn't writable)  
    try:  
        os.makedirs(os.path.dirname(log_file), exist_ok=True)  
        fh = logging.handlers.RotatingFileHandler(  
            log_file, maxBytes=max_bytes, backupCount=backup_count  
        )  
        fh.setFormatter(formatter)  
        logger.addHandler(fh)  
    except (PermissionError, OSError) as e:  
        logger.warning(f"File logging disabled ({log_file}): {e}")  
  
    return logger  
  
logger = setup_logging()  
  
# Database  
DB_PATH = os.path.join(os.path.dirname(__file__), 'ups_history.db')  
  
def init_database():  
    conn = sqlite3.connect(DB_PATH)  
    cursor = conn.cursor()  
  
    cursor.execute('''  
        CREATE TABLE IF NOT EXISTS status_history (  
            id INTEGER PRIMARY KEY AUTOINCREMENT,  
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,  
            battery_charge REAL,  
            battery_voltage REAL,  
            battery_runtime REAL,  
            input_voltage REAL,  
            input_current REAL,  
            input_frequency REAL,  
            load_voltage REAL,  
            load_current REAL,  
            ups_load REAL,  
            status TEXT,  
            battery_charging TEXT,  
            battery_current REAL,  
            faults TEXT  
        )  
    ''')  
  
    cursor.execute('''  
        CREATE TABLE IF NOT EXISTS events (  
            id INTEGER PRIMARY KEY AUTOINCREMENT,  
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,  
            event_type TEXT,  
            message TEXT,  
            severity TEXT  
        )  
    ''')  
  
    conn.commit()  
    conn.close()  
  
def log_status(status_data):  
    conn = sqlite3.connect(DB_PATH)  
    cursor = conn.cursor()  
  
    cursor.execute('''  
        INSERT INTO status_history (  
            battery_charge, battery_voltage, battery_runtime,  
            input_voltage, input_current, input_frequency,  
            load_voltage, load_current,  
            ups_load, status, battery_charging, battery_current, faults  
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)  
    ''', (  
        status_data.get('battery_charge'),  
        status_data.get('battery_voltage'),  
        status_data.get('battery_runtime'),  
        status_data.get('input_voltage'),  
        status_data.get('input_current'),  
        status_data.get('input_frequency'),  
        status_data.get('load_voltage'),  
        status_data.get('load_current'),  
        status_data.get('ups_load'),  
        status_data.get('status'),  
        status_data.get('battery_charging'),  
        status_data.get('battery_current'),  
        status_data.get('faults')  
    ))  
  
    conn.commit()  
    conn.close()  
  
def log_event(event_type, message, severity='INFO'):  
    conn = sqlite3.connect(DB_PATH)  
    cursor = conn.cursor()  
  
    cursor.execute('''  
        INSERT INTO events (event_type, message, severity)  
        VALUES (?, ?, ?)  
    ''', (event_type, message, severity))  
  
    conn.commit()  
    conn.close()  
  
class UPSMonitor:  
    def get_nut_status(self):  
        nut_config = config.get('ups', {}).get('nut', {})  
        host = nut_config.get('host', 'localhost')  
        ups_name = nut_config.get('ups_name', 'ups')  
  
        try:  
            result = subprocess.run(  
                ['upsc', f'{ups_name}@{host}'],  
                capture_output=True, text=True, timeout=10  
            )  
            if result.returncode != 0:  
                logger.error(f"upsc failed: {result.stderr.strip()}")  
                return None  
  
            vars = {}  
            for line in result.stdout.splitlines():  
                if ':' in line:  
                    key, _, value = line.partition(':')  
                    vars[key.strip()] = value.strip()  
  
            def fget(key, default=0.0):  
                try:  
                    return float(vars.get(key, default))  
                except (TypeError, ValueError):  
                    return default  
  
            # Status flags  
            ups_status = vars.get('ups.status', 'Unknown')  
            status_flags = ups_status.split()  
  
            # Charging state  
            if 'CHRG' in status_flags:  
                battery_charging = 'Charging'  
            elif 'DISCHRG' in status_flags:  
                battery_charging = 'Discharging'  
            else:  
                battery_charging = 'Idle'  
  
            # Faults (exact token match; OL/OB are normal states, not faults)  
            faults = []  
            if 'FSD' in status_flags:  
                faults.append('Forced Shutdown')  
            if 'OFF' in status_flags:  
                faults.append('Offline')  
            if 'RB' in status_flags:  
                faults.append('Replace Battery')  
            if 'OVER' in status_flags:  
                faults.append('Overload')  
            if 'LB' in status_flags:  
                faults.append('Low Battery')  
            faults_str = ', '.join(faults) if faults else 'None'  
  
            # Voltages / load  
            input_voltage = fget('input.voltage')  
            output_voltage = fget('output.voltage')  
            ups_load = fget('ups.load')  # percent  
            battery_voltage = fget('battery.voltage')  
  
            # Frequency: correct deci-Hz quirk (e.g. 498.0 -> 49.8)  
            input_frequency = fget('input.frequency')  
            if input_frequency > 100:  
                input_frequency = input_frequency / 10.0  
  
            # Real power: prefer measured, else estimate from load% x nominal  
            realpower = fget('ups.realpower', 0.0)  
            if realpower <= 0:  
                nominal = fget('ups.realpower.nominal', 0.0)  
                realpower = nominal * (ups_load / 100.0)  
  
            # Currents: prefer measured NUT values, else compute from power/voltage  
            input_current = fget('input.current', 0.0)  
            if input_current <= 0 and input_voltage > 0:  
                input_current = realpower / input_voltage  
  
            load_current = fget('output.current', 0.0)  
            if load_current <= 0 and output_voltage > 0:  
                load_current = realpower / output_voltage  
  
            # Battery current only meaningful on discharge  
            battery_current = fget('battery.current', 0.0)  
            if battery_current <= 0 and 'DISCHRG' in status_flags and battery_voltage > 0:  
                battery_current = realpower / battery_voltage  
  
            return {  
                'battery_charge': fget('battery.charge'),  
                'battery_voltage': battery_voltage,  
                'battery_runtime': fget('battery.runtime'),  
                'input_voltage': input_voltage,  
                'input_current': round(input_current, 2),  
                'input_frequency': round(input_frequency, 1),  
                'load_voltage': output_voltage,  
                'load_current': round(load_current, 2),  
                'ups_load': ups_load,  
                'status': ups_status,  
                'battery_charging': battery_charging,  
                'battery_current': round(battery_current, 2),  
                'faults': faults_str  
            }  
  
        except subprocess.TimeoutExpired:  
            logger.error("upsc command timed out")  
            return None  
        except Exception as e:  
            logger.error(f"Error reading UPS status: {e}")  
            return None  
  
    def get_status(self):  
        ups_type = config.get('ups', {}).get('type', 'nut')  
        if ups_type == 'nut':  
            return self.get_nut_status()  
        logger.error(f"Unsupported UPS type: {ups_type}")  
        return None  
  
# Flask app  
app = Flask(__name__)  
  
def check_auth(username, password):  
    web_config = config.get('web', {})  
    return (username == web_config.get('username', 'admin') and  
            password == web_config.get('password', ''))  
  
def authenticate():  
    return Response(  
        'Authentication required', 401,  
        {'WWW-Authenticate': 'Basic realm="DizerUPS"'}  
    )  
  
def requires_auth(f):  
    from functools import wraps  
    @wraps(f)  
    def decorated(*args, **kwargs):  
        auth = request.authorization  
        if not auth or not check_auth(auth.username, auth.password):  
            return authenticate()  
        return f(*args, **kwargs)  
    return decorated  
  
@app.route('/')  
@requires_auth  
def index():  
    return render_template('dashboard.html')  
  
@app.route('/api/status')  
@requires_auth  
def api_status():  
    monitor = UPSMonitor()  
    status = monitor.get_status()  
    if status:  
        return jsonify(status)  
    return jsonify({'error': 'Unable to read UPS status'}), 503  
  
@app.route('/api/events')  
@requires_auth  
def api_events():  
    conn = sqlite3.connect(DB_PATH)  
    conn.row_factory = sqlite3.Row  
    cursor = conn.cursor()  
    cursor.execute('SELECT * FROM events ORDER BY timestamp DESC LIMIT 50')  
    events = [dict(row) for row in cursor.fetchall()]  
    conn.close()  
    return jsonify(events)  
  
@app.route('/api/history')  
@requires_auth  
def api_history():  
    conn = sqlite3.connect(DB_PATH)  
    conn.row_factory = sqlite3.Row  
    cursor = conn.cursor()  
    cursor.execute('SELECT * FROM status_history ORDER BY timestamp DESC LIMIT 100')  
    history = [dict(row) for row in cursor.fetchall()]  
    conn.close()  
    return jsonify(history)  
  
@app.route('/api/shutdown', methods=['POST'])  
@requires_auth  
def api_shutdown():  
    shutdown_config = config.get('shutdown', {})  
    if not shutdown_config.get('enabled', False):  
        return jsonify({'success': False,  
                        'message': 'Shutdown is disabled in config.yaml'}), 403  
    try:  
        logger.warning("Manual shutdown requested via web dashboard")  
        log_event('SHUTDOWN', 'Manual shutdown requested via dashboard', 'WARNING')  
        subprocess.Popen(['sudo', '/sbin/shutdown', '-h', 'now'])  
        return jsonify({'success': True, 'message': 'Shutdown initiated'})  
    except Exception as e:  
        logger.error(f"Shutdown failed: {e}")  
        return jsonify({'success': False, 'message': str(e)}), 500  
  
# Scheduler  
scheduler = BackgroundScheduler()  
  
def scheduled_log():  
    monitor = UPSMonitor()  
    status = monitor.get_status()  
    if status:  
        log_status(status)  
  
        # Check for alerts  
        alert_config = config.get('alerts', {})  
        if status.get('battery_charge', 100) < alert_config.get('low_battery_threshold', 20):  
            log_event('LOW_BATTERY', f"Battery charge at {status.get('battery_charge')}%", 'WARNING')  
  
        if status.get('ups_load', 0) > alert_config.get('high_load_threshold', 80):  
            log_event('HIGH_LOAD', f"UPS load at {status.get('ups_load')}%", 'WARNING')  
  
if __name__ == '__main__':  
    init_database()  
    logger.info(f"UPS Monitor starting (v{__version__})")  
  
    # Start background scheduler  
    scheduler.add_job(scheduled_log, 'interval', seconds=config.get('logging_interval', 60))  
    scheduler.start()  
  
    # Run Flask app  
    web_config = config.get('web', {})  
    app.run(  
        host=web_config.get('host', '0.0.0.0'),  
        port=web_config.get('port', 5000),  
        debug=False  
    )
