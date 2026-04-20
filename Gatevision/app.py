"""
Smart Parking Lot - ANPR Flask App
Webcam | best.pt plate detection | PaddleOCR | SQLite Enter/Exit | Random Names | Auth
"""

from flask import Flask, render_template, Response, jsonify, request, session, redirect, url_for
import cv2
import numpy as np
from ultralytics import YOLO
from paddleocr import PaddleOCR
import sqlite3
import os
import random
import hashlib
import secrets
from datetime import datetime
import threading
import functools

app = Flask(__name__)
app.secret_key = secrets.token_hex(32)   # Secure random secret each run

# ============================================
# Parking Charge Configuration
# ============================================
# Real-world standard rates (India / Global)
OWNER_UPI_ID = "owner@okaxis"          # ← Change to your actual GPay UPI ID

PARKING_RATES_INR = {
    'first_hour':       30,    # ₹30 for the first hour (standard mall/commercial rate)
    'per_hour':         20,    # ₹20 per additional hour
    'daily_max':       150,    # ₹150 daily cap (12-hour cap, common in India)
    'overnight':        80,    # ₹80 extra if parked overnight (after 10 PM)
    'min_charge':       10,    # ₹10 minimum (even if <15 min)
}

PARKING_RATES_USD = {
    'first_hour':      2.00,   # $2.00 first hour (US city standard)
    'per_hour':        1.50,   # $1.50 per additional hour
    'daily_max':      15.00,   # $15 daily max (common US parking lot cap)
    'overnight':       5.00,   # $5 overnight surcharge
    'min_charge':      1.00,   # $1.00 minimum charge
}

USD_TO_INR = 83.5              # Approximate rate; update as needed


def calculate_charge(duration_seconds, currency='INR'):
    """
    Calculate parking fee based on duration.
    Rules (mirrors real-world tier pricing):
      - 0–15 min  → minimum charge
      - >15 min   → first hour rate
      - Each additional hour (or part thereof) → per_hour rate
      - Total capped at daily_max
    Returns dict with breakdown.
    """
    rates = PARKING_RATES_INR if currency == 'INR' else PARKING_RATES_USD
    symbol = '₹' if currency == 'INR' else '$'

    if not duration_seconds or duration_seconds <= 0:
        return {'amount': 0, 'symbol': symbol, 'currency': currency, 'breakdown': 'No duration'}

    minutes = duration_seconds / 60.0
    hours   = duration_seconds / 3600.0

    if minutes <= 15:
        charge = rates['min_charge']
        breakdown = f"Min charge (≤15 min)"
    elif hours <= 1:
        charge = rates['first_hour']
        breakdown = f"First hour: {symbol}{rates['first_hour']}"
    else:
        extra_hours = hours - 1
        extra_charge = extra_hours * rates['per_hour']
        # Round up partial hours
        import math
        extra_charge = math.ceil(extra_hours) * rates['per_hour']
        charge = rates['first_hour'] + extra_charge
        breakdown = (f"1st hr: {symbol}{rates['first_hour']} + "
                     f"{math.ceil(extra_hours)} extra hr(s): {symbol}{extra_charge:.2f}")

    # Apply daily cap
    if charge > rates['daily_max']:
        charge = rates['daily_max']
        breakdown += f" (capped at daily max)"

    return {
        'amount':    round(charge, 2),
        'symbol':    symbol,
        'currency':  currency,
        'breakdown': breakdown
    }


# ============================================
# Fake Names Pool
# ============================================
FAKE_NAMES = [
    "Aarav Shah", "Priya Mehta", "Rohan Patel", "Sneha Joshi", "Vikram Nair",
    "Ananya Iyer", "Karan Gupta", "Pooja Singh", "Arjun Rao", "Divya Kumar",
    "Rahul Sharma", "Neha Reddy", "Amit Verma", "Kavya Pillai", "Suresh Bhat",
    "Meera Nambiar", "Rajesh Shetty", "Deepa Krishnan", "Nikhil Jain", "Swati Desai",
    "Aditya Malhotra", "Ritu Agarwal", "Sanjay Tiwari", "Pallavi Pandey", "Varun Bose",
    "Shruti Chatterjee", "Mohit Saxena", "Lakshmi Rajan", "Gaurav Mishra", "Tanvi More",
    "Akash Menon", "Ritika Kapoor", "Harish Nayak", "Sunita Bhatt", "Pavan Reddy",
    "Ishaan Dubey", "Nalini Srinivas", "Kunal Thakur", "Ankita Doshi", "Yash Patil"
]

# ============================================
# Global Variables
# ============================================
model_plate = None
ocr = None
processing_active = False
cap = None
seen_track_ids = set()   # Track IDs processed in current session - never re-process
lock = threading.Lock()

# ============================================
# Database Setup
# ============================================
def hash_password(password):
    return hashlib.sha256(password.encode()).hexdigest()


def init_db():
    conn = sqlite3.connect('parking.db')
    c = conn.cursor()

    # ── users table ───────────────────────────────────────────────────────
    c.execute('''
        CREATE TABLE IF NOT EXISTS users (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            username     TEXT    UNIQUE NOT NULL,
            password_hash TEXT   NOT NULL,
            role         TEXT    NOT NULL DEFAULT 'staff',
            upi_id       TEXT    DEFAULT '',
            created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            last_login   DATETIME
        )
    ''')

    # Create default admin if no users exist
    c.execute('SELECT COUNT(*) FROM users')
    if c.fetchone()[0] == 0:
        c.execute('''
            INSERT INTO users (username, password_hash, role, upi_id)
            VALUES (?, ?, 'admin', ?)
        ''', ('admin', hash_password('Admin@123'), 'owner@okaxis'))
        print("✓ Default admin created  →  username: admin  |  password: Admin@123")

    # owners: one row per unique plate — name is assigned once, forever
    c.execute('''
        CREATE TABLE IF NOT EXISTS owners (
            plate_text  TEXT PRIMARY KEY,
            name        TEXT NOT NULL
        )
    ''')

    # parking_log: one row per parking session (enter → exit pair)
    c.execute('''
        CREATE TABLE IF NOT EXISTS parking_log (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            plate_text       TEXT    NOT NULL,
            owner_name       TEXT    NOT NULL,
            track_id         INTEGER,
            entry_time       DATETIME NOT NULL,
            exit_time        DATETIME,
            date             TEXT    NOT NULL,
            duration_seconds INTEGER,
            status           TEXT    NOT NULL DEFAULT 'PARKED'
        )
    ''')

    conn.commit()
    conn.close()
    print("✓ Database ready")


def get_db():
    conn = sqlite3.connect('parking.db')
    conn.row_factory = sqlite3.Row
    return conn


# ============================================
# Auth Helpers
# ============================================
def login_required(f):
    @functools.wraps(f)
    def decorated(*args, **kwargs):
        if 'user_id' not in session:
            if request.is_json or request.path.startswith('/api') or request.headers.get('X-Requested-With'):
                return jsonify({'error': 'Unauthorized', 'redirect': '/login'}), 401
            return redirect('/login')
        return f(*args, **kwargs)
    return decorated


def admin_required(f):
    @functools.wraps(f)
    def decorated(*args, **kwargs):
        if 'user_id' not in session:
            return jsonify({'error': 'Unauthorized'}), 401
        if session.get('role') != 'admin':
            return jsonify({'error': 'Admin access required'}), 403
        return f(*args, **kwargs)
    return decorated


def get_owner_upi():
    """Get UPI ID from admin user record."""
    conn = get_db()
    c    = conn.cursor()
    c.execute("SELECT upi_id FROM users WHERE role='admin' LIMIT 1")
    row = c.fetchone()
    conn.close()
    return row['upi_id'] if row and row['upi_id'] else OWNER_UPI_ID


# ============================================
# Auth Routes
# ============================================
@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'GET':
        if 'user_id' in session:
            return redirect('/')
        return render_template('login.html')

    data = request.get_json() or {}
    username = data.get('username', '').strip()
    password = data.get('password', '')

    if not username or not password:
        return jsonify({'success': False, 'message': 'Username and password are required'}), 400

    conn = get_db()
    c    = conn.cursor()
    c.execute('SELECT * FROM users WHERE username = ?', (username,))
    user = c.fetchone()

    if not user or user['password_hash'] != hash_password(password):
        conn.close()
        return jsonify({'success': False, 'message': 'Invalid username or password'}), 401

    # Update last_login
    c.execute('UPDATE users SET last_login=? WHERE id=?', (datetime.now().isoformat(), user['id']))
    conn.commit()
    conn.close()

    session['user_id']  = user['id']
    session['username'] = user['username']
    session['role']     = user['role']

    return jsonify({'success': True, 'role': user['role'], 'username': user['username']})


@app.route('/logout', methods=['POST'])
def logout():
    session.clear()
    return jsonify({'success': True})


@app.route('/me')
def me():
    if 'user_id' not in session:
        return jsonify({'logged_in': False})
    return jsonify({
        'logged_in': True,
        'username':  session.get('username'),
        'role':      session.get('role')
    })


# ============================================
# Admin: User Management
# ============================================
@app.route('/admin/users', methods=['GET'])
@admin_required
def admin_get_users():
    conn = get_db()
    c    = conn.cursor()
    c.execute('SELECT id, username, role, upi_id, created_at, last_login FROM users ORDER BY id')
    rows = c.fetchall()
    conn.close()
    return jsonify({'users': [dict(r) for r in rows]})


@app.route('/admin/users', methods=['POST'])
@admin_required
def admin_create_user():
    data     = request.get_json() or {}
    username = data.get('username', '').strip()
    password = data.get('password', '')
    role     = data.get('role', 'staff')
    upi_id   = data.get('upi_id', '').strip()

    if not username or not password:
        return jsonify({'success': False, 'message': 'Username and password required'}), 400
    if role not in ('admin', 'staff'):
        return jsonify({'success': False, 'message': 'Role must be admin or staff'}), 400
    if len(password) < 6:
        return jsonify({'success': False, 'message': 'Password must be at least 6 characters'}), 400

    conn = get_db()
    c    = conn.cursor()
    try:
        c.execute('INSERT INTO users (username, password_hash, role, upi_id) VALUES (?,?,?,?)',
                  (username, hash_password(password), role, upi_id))
        conn.commit()
        new_id = c.lastrowid
        conn.close()
        return jsonify({'success': True, 'id': new_id, 'message': f'User "{username}" created'})
    except sqlite3.IntegrityError:
        conn.close()
        return jsonify({'success': False, 'message': f'Username "{username}" already exists'}), 409


@app.route('/admin/users/<int:uid>', methods=['PUT'])
@admin_required
def admin_update_user(uid):
    data     = request.get_json() or {}
    conn     = get_db()
    c        = conn.cursor()
    c.execute('SELECT * FROM users WHERE id=?', (uid,))
    user = c.fetchone()
    if not user:
        conn.close()
        return jsonify({'success': False, 'message': 'User not found'}), 404

    new_password = data.get('password', '').strip()
    new_role     = data.get('role', user['role'])
    new_upi      = data.get('upi_id', user['upi_id'])

    if new_role not in ('admin', 'staff'):
        conn.close()
        return jsonify({'success': False, 'message': 'Invalid role'}), 400

    if new_password:
        if len(new_password) < 6:
            conn.close()
            return jsonify({'success': False, 'message': 'Password must be at least 6 characters'}), 400
        c.execute('UPDATE users SET role=?, upi_id=?, password_hash=? WHERE id=?',
                  (new_role, new_upi, hash_password(new_password), uid))
    else:
        c.execute('UPDATE users SET role=?, upi_id=? WHERE id=?', (new_role, new_upi, uid))

    conn.commit()
    conn.close()
    return jsonify({'success': True, 'message': 'User updated'})


@app.route('/admin/users/<int:uid>', methods=['DELETE'])
@admin_required
def admin_delete_user(uid):
    if uid == session.get('user_id'):
        return jsonify({'success': False, 'message': 'Cannot delete your own account'}), 400
    conn = get_db()
    c    = conn.cursor()
    c.execute('SELECT id FROM users WHERE id=?', (uid,))
    if not c.fetchone():
        conn.close()
        return jsonify({'success': False, 'message': 'User not found'}), 404
    c.execute('DELETE FROM users WHERE id=?', (uid,))
    conn.commit()
    conn.close()
    return jsonify({'success': True, 'message': 'User deleted'})


@app.route('/admin/upi', methods=['GET'])
@admin_required
def admin_get_upi():
    return jsonify({'upi_id': get_owner_upi()})


@app.route('/admin/upi', methods=['PUT'])
@admin_required
def admin_set_upi():
    data   = request.get_json() or {}
    upi_id = data.get('upi_id', '').strip()
    if not upi_id:
        return jsonify({'success': False, 'message': 'UPI ID required'}), 400
    conn = get_db()
    c    = conn.cursor()
    c.execute("UPDATE users SET upi_id=? WHERE role='admin'", (upi_id,))
    conn.commit()
    conn.close()
    return jsonify({'success': True, 'message': 'UPI ID updated'})



def get_or_create_owner(plate_text):
    conn = get_db()
    c = conn.cursor()
    c.execute('SELECT name FROM owners WHERE plate_text = ?', (plate_text,))
    row = c.fetchone()
    if row:
        name = row['name']
    else:
        name = random.choice(FAKE_NAMES)
        c.execute('INSERT OR IGNORE INTO owners (plate_text, name) VALUES (?, ?)', (plate_text, name))
        conn.commit()
    conn.close()
    return name


# ============================================
# Core Enter / Exit Logic
# ============================================
def process_plate_entry_exit(plate_text, track_id):
    """
    Rules:
      - No open record for today  →  ENTER  (insert new row, status=PARKED)
      - Open PARKED record today  →  EXIT   (update exit_time, duration, status=EXITED)
    Returns dict describing what happened.
    """
    today = datetime.now().strftime('%Y-%m-%d')
    now   = datetime.now()
    owner_name = get_or_create_owner(plate_text)

    conn = get_db()
    c = conn.cursor()

    # Is there an open (PARKED) session for this plate today?
    c.execute('''
        SELECT id, entry_time
        FROM   parking_log
        WHERE  plate_text = ? AND date = ? AND status = 'PARKED'
        ORDER  BY entry_time DESC
        LIMIT  1
    ''', (plate_text, today))
    existing = c.fetchone()

    if existing:
        # ── EXIT PENDING ───────────────────────────────────────────────────
        # Do NOT write to DB yet. Return pending info so the frontend can
        # show the payment modal first. DB is updated only via /confirm_exit.
        entry_dt = datetime.fromisoformat(existing['entry_time'])
        duration = int((now - entry_dt).total_seconds())
        conn.close()

        charge_inr = calculate_charge(duration, 'INR')
        charge_usd = calculate_charge(duration, 'USD')

        return {
            'action':           'EXIT_PENDING',
            'log_id':           existing['id'],
            'plate':            plate_text,
            'name':             owner_name,
            'track_id':         track_id,
            'entry_time':       existing['entry_time'],
            'duration_seconds': duration,
            'charge_inr':       charge_inr,
            'charge_usd':       charge_usd,
            'upi_id':           get_owner_upi()
        }

    else:
        # ── ENTER ─────────────────────────────────────────────────────────
        c.execute('''
            INSERT INTO parking_log
                (plate_text, owner_name, track_id, entry_time, date, status)
            VALUES (?, ?, ?, ?, ?, 'PARKED')
        ''', (plate_text, owner_name, track_id, now.isoformat(), today))
        conn.commit()
        conn.close()

        return {
            'action':     'ENTER',
            'plate':      plate_text,
            'name':       owner_name,
            'track_id':   track_id,
            'entry_time': now.isoformat()
        }


# ============================================
# Initialize Models
# ============================================
def initialize_models():
    global model_plate, ocr
    try:
        model_plate = YOLO('best.pt')
        ocr = PaddleOCR(
            use_doc_orientation_classify=False,
            use_doc_unwarping=False,
            use_textline_orientation=False
        )
        print("✓ Models loaded successfully")
        return True
    except Exception as e:
        print(f"✗ Error loading models: {e}")
        return False


# ============================================
# OCR Text Cleaner
# ============================================
def clean_plate_text(result):
    if not result:
        return ""
    try:
        if isinstance(result, list) and len(result) > 0:
            if isinstance(result[0], dict) and "rec_texts" in result[0]:
                texts = result[0]["rec_texts"]
                return "".join(texts).replace(" ", "").upper()
    except Exception as e:
        print(f"OCR parse error: {e}")
    return ""


# ============================================
# Webcam Stream Generator
# ============================================
def generate_frames():
    global cap, processing_active, seen_track_ids

    if cap is None or not cap.isOpened():
        return

    frame_count = 0

    while processing_active:
        ret, frame = cap.read()
        if not ret:
            break

        frame_count += 1
        if frame_count % 2 != 0:      # skip every other frame → faster
            continue

        frame = cv2.resize(frame, (960, 540))

        # ── Detect & track plates (best.pt only) ──────────────────────────
        results = model_plate.track(frame, persist=True, conf=0.4, verbose=False)

        if results[0].boxes is not None and results[0].boxes.id is not None:
            boxes     = results[0].boxes.xyxy.cpu().numpy().astype(int)
            track_ids = results[0].boxes.id.cpu().numpy().astype(int)

            for box, track_id in zip(boxes, track_ids):
                x1, y1, x2, y2 = box
                tid = int(track_id)

                # Check session cache
                with lock:
                    already_seen = tid in seen_track_ids

                # Determine display colour & label
                box_color  = (0, 200, 80) if not already_seen else (100, 100, 100)
                label_text = f"ID:{tid}"

                if not already_seen:
                    # Crop and run OCR — display only, NO auto-save to DB
                    # Plates are only saved when the user clicks the Capture button
                    cropped = frame[y1:y2, x1:x2]
                    if cropped.size > 0 and (y2 - y1) > 10 and (x2 - x1) > 30:
                        try:
                            resized     = cv2.resize(cropped, (200, 80))
                            result_ocr  = ocr.predict(resized)
                            plate_text  = clean_plate_text(result_ocr)

                            if plate_text and len(plate_text) >= 4:
                                # Mark as seen so we don't re-OCR every frame
                                with lock:
                                    seen_track_ids.add(tid)

                                box_color  = (0, 200, 255)   # cyan = detected but not yet saved
                                label_text = f"{plate_text} [DETECTED]"
                                print(f"👁 [DETECTED] Plate:{plate_text}  Track:{tid}  (use Capture to save)")

                        except Exception as e:
                            print(f"OCR Error: {e}")

                # Draw bounding box + label
                cv2.rectangle(frame, (x1, y1), (x2, y2), box_color, 2)
                cv2.rectangle(frame, (x1, y1 - 22), (x1 + len(label_text)*11, y1), box_color, -1)
                cv2.putText(frame, label_text, (x1 + 2, y1 - 5),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 1)

        # ── HUD overlay ───────────────────────────────────────────────────
        with lock:
            session_count = len(seen_track_ids)

        cv2.rectangle(frame, (0, 0), (300, 70), (0, 0, 0), -1)
        cv2.putText(frame, f'Session Plates: {session_count}', (10, 25),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 150), 2)
        cv2.putText(frame, datetime.now().strftime('%d-%m-%Y  %H:%M:%S'), (10, 55),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, (200, 200, 200), 1)

        ret, buffer = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
        yield (b'--frame\r\n'
               b'Content-Type: image/jpeg\r\n\r\n' + buffer.tobytes() + b'\r\n')


# ============================================
# Routes
# ============================================

@app.route('/')
@login_required
def index():
    return render_template('index.html')


@app.route('/video_feed')
@login_required
def video_feed():
    return Response(generate_frames(),
                    mimetype='multipart/x-mixed-replace; boundary=frame')


@app.route('/start_webcam', methods=['POST'])
@login_required
def start_webcam():
    global cap, processing_active, seen_track_ids

    if cap is not None:
        cap.release()

    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        return jsonify({'success': False, 'message': 'Could not open webcam. Check connection.'})

    cap.set(cv2.CAP_PROP_FRAME_WIDTH,  1280)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)

    with lock:
        seen_track_ids = set()   # fresh session — allow all plates to be re-detected

    processing_active = True
    return jsonify({'success': True, 'message': 'Webcam started — show a number plate to the camera'})


@app.route('/stop_webcam', methods=['POST'])
@login_required
def stop_webcam():
    global processing_active, cap
    processing_active = False
    if cap is not None:
        cap.release()
        cap = None
    return jsonify({'success': True, 'message': 'Webcam stopped'})


@app.route('/capture_snapshot', methods=['POST'])
@login_required
def capture_snapshot():
    """Manually capture a single frame, run plate detection + OCR, and log entry/exit."""
    global cap, seen_track_ids

    if cap is None or not cap.isOpened():
        return jsonify({'success': False, 'message': 'Webcam not running. Start it first.'})

    ret, frame = cap.read()
    if not ret:
        return jsonify({'success': False, 'message': 'Failed to read frame from webcam.'})

    frame = cv2.resize(frame, (960, 540))

    try:
        results = model_plate.track(frame, persist=False, conf=0.35, verbose=False)
    except Exception as e:
        return jsonify({'success': False, 'message': f'Detection error: {str(e)}'})

    detected = []

    if results[0].boxes is not None and len(results[0].boxes) > 0:
        boxes     = results[0].boxes.xyxy.cpu().numpy().astype(int)
        ids_tensor = results[0].boxes.id
        track_ids = ids_tensor.cpu().numpy().astype(int) if ids_tensor is not None \
                    else list(range(len(boxes)))

        for box, tid in zip(boxes, track_ids):
            x1, y1, x2, y2 = box
            cropped = frame[y1:y2, x1:x2]
            if cropped.size == 0 or (y2 - y1) <= 10 or (x2 - x1) <= 30:
                continue
            try:
                resized    = cv2.resize(cropped, (200, 80))
                result_ocr = ocr.predict(resized)
                plate_text = clean_plate_text(result_ocr)

                if plate_text and len(plate_text) >= 4:
                    info = process_plate_entry_exit(plate_text, int(tid))
                    detected.append(info)
                    print(f"✓ [SNAPSHOT/{info['action']}] Plate:{plate_text}  Owner:{info['name']}")
            except Exception as e:
                print(f'Snapshot OCR error: {e}')

    if detected:
        # Reset seen IDs so the live stream can re-detect plates after this capture
        with lock:
            seen_track_ids = set()
        return jsonify({'success': True, 'detected': detected, 'count': len(detected)})
    else:
        return jsonify({
            'success': False,
            'message': 'No number plate detected. Hold the plate closer to the camera and try again.'
        })


@app.route('/confirm_exit', methods=['POST'])
@login_required
def confirm_exit():
    """
    Called after payment is confirmed on the frontend.
    Writes the EXIT record to the DB (sets status=EXITED, exit_time, duration).
    """
    data     = request.get_json() or {}
    log_id   = data.get('log_id')
    track_id = data.get('track_id', 0)

    if not log_id:
        return jsonify({'success': False, 'message': 'log_id required'}), 400

    now  = datetime.now()
    conn = get_db()
    c    = conn.cursor()

    c.execute('SELECT id, entry_time, status FROM parking_log WHERE id = ?', (log_id,))
    row = c.fetchone()

    if not row:
        conn.close()
        return jsonify({'success': False, 'message': 'Record not found'}), 404

    if row['status'] == 'EXITED':
        conn.close()
        return jsonify({'success': True, 'message': 'Already exited'})

    entry_dt = datetime.fromisoformat(row['entry_time'])
    duration = int((now - entry_dt).total_seconds())

    c.execute('''
        UPDATE parking_log
        SET    exit_time = ?, duration_seconds = ?, status = 'EXITED', track_id = ?
        WHERE  id = ?
    ''', (now.isoformat(), duration, track_id, log_id))
    conn.commit()
    conn.close()

    print(f"✓ [EXIT CONFIRMED] log_id:{log_id}  duration:{duration}s")
    return jsonify({'success': True, 'duration_seconds': duration})


# ── Parking data endpoints ─────────────────────────────────────────────────────

@app.route('/get_parked')
@login_required
def get_parked():
    """Live list of currently parked vehicles with elapsed duration."""
    today = datetime.now().strftime('%Y-%m-%d')
    now   = datetime.now()

    conn = get_db()
    c    = conn.cursor()
    c.execute('''
        SELECT id, plate_text, owner_name, track_id, entry_time
        FROM   parking_log
        WHERE  date = ? AND status = 'PARKED'
        ORDER  BY entry_time DESC
    ''', (today,))
    rows = c.fetchall()
    conn.close()

    parked = []
    for row in rows:
        entry_dt = datetime.fromisoformat(row['entry_time'])
        elapsed  = int((now - entry_dt).total_seconds())
        parked.append({
            'id':              row['id'],
            'plate_text':      row['plate_text'],
            'owner_name':      row['owner_name'],
            'track_id':        row['track_id'],
            'entry_time':      row['entry_time'],
            'duration_seconds': elapsed
        })

    return jsonify({'parked': parked, 'count': len(parked)})


@app.route('/get_history')
@login_required
def get_history():
    """Last 200 parking log entries (enter + exit)."""
    conn = get_db()
    c    = conn.cursor()
    c.execute('''
        SELECT id, plate_text, owner_name, track_id,
               entry_time, exit_time, duration_seconds, status, date
        FROM   parking_log
        ORDER  BY entry_time DESC
        LIMIT  200
    ''')
    rows = c.fetchall()
    conn.close()
    return jsonify({'history': [dict(r) for r in rows]})


@app.route('/get_stats')
@login_required
def get_stats():
    today = datetime.now().strftime('%Y-%m-%d')
    conn  = get_db()
    c     = conn.cursor()

    c.execute("SELECT COUNT(*) FROM parking_log WHERE date=? AND status='PARKED'",  (today,))
    currently_parked = c.fetchone()[0]

    c.execute("SELECT COUNT(*) FROM parking_log WHERE date=? AND status='EXITED'", (today,))
    exits_today = c.fetchone()[0]

    c.execute("SELECT COUNT(*) FROM parking_log WHERE date=?", (today,))
    total_today = c.fetchone()[0]

    c.execute("SELECT COUNT(DISTINCT plate_text) FROM parking_log")
    unique_plates = c.fetchone()[0]

    conn.close()
    return jsonify({
        'currently_parked': currently_parked,
        'entries_today':    total_today,
        'exits_today':      exits_today,
        'unique_plates':    unique_plates
    })


@app.route('/search')
@login_required
def search():
    q = request.args.get('q', '').strip()
    if not q:
        return get_history()

    conn = get_db()
    c    = conn.cursor()
    like = f'%{q.upper()}%'
    c.execute('''
        SELECT id, plate_text, owner_name, track_id,
               entry_time, exit_time, duration_seconds, status, date
        FROM   parking_log
        WHERE  UPPER(plate_text) LIKE ? OR UPPER(owner_name) LIKE ?
        ORDER  BY entry_time DESC
    ''', (like, like))
    rows = c.fetchall()
    conn.close()
    return jsonify({'history': [dict(r) for r in rows]})


@app.route('/export_csv')
@login_required
def export_csv():
    import csv
    from io import StringIO

    conn = get_db()
    c    = conn.cursor()
    c.execute('SELECT * FROM parking_log ORDER BY entry_time DESC')
    rows = c.fetchall()
    conn.close()

    output = StringIO()
    writer = csv.writer(output)
    writer.writerow(['ID', 'Plate', 'Owner Name', 'Track ID',
                     'Entry Time', 'Exit Time', 'Duration (sec)', 'Status', 'Date'])
    for r in rows:
        mins = (r['duration_seconds'] // 60) if r['duration_seconds'] else 0
        secs = (r['duration_seconds'] % 60)  if r['duration_seconds'] else 0
        writer.writerow([r['id'], r['plate_text'], r['owner_name'], r['track_id'],
                         r['entry_time'], r['exit_time'],
                         f"{mins}m {secs}s" if r['duration_seconds'] else '-',
                         r['status'], r['date']])

    response = app.make_response(output.getvalue())
    response.headers['Content-Disposition'] = 'attachment; filename=parking_log.csv'
    response.headers['Content-Type']        = 'text/csv'
    return response


@app.route('/get_charge')
@login_required
def get_charge():
    """Return charge for a given parking session by log id or plate."""
    log_id   = request.args.get('id')
    currency = request.args.get('currency', 'INR').upper()
    if currency not in ('INR', 'USD'):
        currency = 'INR'

    conn = get_db()
    c    = conn.cursor()

    if log_id:
        c.execute('SELECT * FROM parking_log WHERE id = ?', (log_id,))
    else:
        plate = request.args.get('plate', '').upper()
        today = datetime.now().strftime('%Y-%m-%d')
        c.execute('''SELECT * FROM parking_log WHERE plate_text=? AND date=?
                     ORDER BY entry_time DESC LIMIT 1''', (plate, today))

    row = c.fetchone()
    conn.close()

    if not row:
        return jsonify({'error': 'Record not found'}), 404

    dur = row['duration_seconds']
    if not dur and row['status'] == 'PARKED':
        # Still parked – calculate live duration
        entry_dt = datetime.fromisoformat(row['entry_time'])
        dur = int((datetime.now() - entry_dt).total_seconds())

    charge = calculate_charge(dur, currency)
    return jsonify({
        'id':               row['id'],
        'plate':            row['plate_text'],
        'owner':            row['owner_name'],
        'status':           row['status'],
        'duration_seconds': dur,
        'charge':           charge,
        'upi_id':           get_owner_upi()
    })


@app.route('/get_charges_all')
@login_required
def get_charges_all():
    """Return today's exited sessions with charges for revenue view."""
    today    = datetime.now().strftime('%Y-%m-%d')
    currency = request.args.get('currency', 'INR').upper()
    if currency not in ('INR', 'USD'):
        currency = 'INR'

    conn = get_db()
    c    = conn.cursor()
    c.execute('''SELECT id, plate_text, owner_name, duration_seconds, entry_time, exit_time
                 FROM parking_log WHERE date=? AND status='EXITED'
                 ORDER BY exit_time DESC''', (today,))
    rows = c.fetchall()
    conn.close()

    total = 0
    result = []
    for r in rows:
        ch = calculate_charge(r['duration_seconds'], currency)
        total += ch['amount']
        result.append({
            'id':       r['id'],
            'plate':    r['plate_text'],
            'owner':    r['owner_name'],
            'duration': r['duration_seconds'],
            'charge':   ch
        })

    sym = '₹' if currency == 'INR' else '$'
    return jsonify({
        'sessions':       result,
        'total_revenue':  round(total, 2),
        'symbol':         sym,
        'currency':       currency,
        'upi_id':         get_owner_upi()
    })


# ============================================
# Clear Database (Admin Only)
# ============================================
@app.route('/admin/clear_database', methods=['POST'])
@login_required
def clear_database():
    """Wipe all parking_log records. Admin only."""
    if session.get('role') != 'admin':
        return jsonify({'success': False, 'message': 'Admin access required.'}), 403

    confirm = request.json.get('confirm', '') if request.is_json else ''
    if confirm != 'CLEAR':
        return jsonify({'success': False, 'message': 'Confirmation token missing.'}), 400

    conn = get_db()
    c    = conn.cursor()
    c.execute('DELETE FROM parking_log')
    deleted = conn.total_changes
    conn.commit()
    conn.close()

    print(f"⚠️  Database cleared by {session.get('username')} — {deleted} record(s) deleted.")
    return jsonify({'success': True, 'message': f'{deleted} record(s) permanently deleted.'})


# ============================================
# Main
# ============================================
if __name__ == '__main__':
    print("=" * 55)
    print("  Smart Parking ANPR System — Initializing...")
    print("=" * 55)

    init_db()

    if initialize_models():
        print("\n🚀  Flask server starting...")
        print("🌐  Open browser → http://127.0.0.1:8000")
        print("=" * 55)
        app.run(debug=False, threaded=True,host='0.0.0.0',port=8000)
    else:
        print("\n✗  Could not load models. Make sure best.pt is in the same folder.")