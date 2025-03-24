from flask import Flask, render_template, request, jsonify, send_file
from flask_socketio import SocketIO
import subprocess
import os
import threading
import time
from datetime import datetime
import eventlet

eventlet.monkey_patch()

app = Flask(__name__)
socketio = SocketIO(app, async_mode='eventlet')

# Configurações
UPLOAD_FOLDER = 'IBD_FILES'
BACKUP_FOLDER = '/app/backup'
os.makedirs(UPLOAD_FOLDER, exist_ok=True)
os.makedirs(BACKUP_FOLDER, exist_ok=True)

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/upload', methods=['POST'])
def upload_files():
    if 'ibd_files[]' not in request.files:
        return jsonify({'error': 'No files provided'}), 400

    files = request.files.getlist('ibd_files[]')
    create_sql = request.files.get('create_sql')

    if not files or not create_sql:
        return jsonify({'error': 'Missing required files'}), 400

    # Limpa diretório
    for f in os.listdir(UPLOAD_FOLDER):
        os.remove(os.path.join(UPLOAD_FOLDER, f))

    # Salva arquivos
    for file in files:
        if file.filename.endswith('.ibd'):
            file.save(os.path.join(UPLOAD_FOLDER, file.filename))
    
    create_sql.save('create.sql')

    return jsonify({'message': 'Files uploaded successfully'})

@app.route('/start_recovery', methods=['POST'])
def start_recovery():
    def run_recovery():
        process = subprocess.Popen(
            ['./recovery.sh'],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            universal_newlines=True
        )

        while True:
            output = process.stdout.readline()
            if output == '' and process.poll() is not None:
                break
            if output:
                socketio.emit('log_update', {'data': output.strip()})
                
        rc = process.poll()
        socketio.emit('recovery_complete', {'success': rc == 0})

    eventlet.spawn(run_recovery)
    return jsonify({'message': 'Recovery process started'})

@app.route('/download_backup')
def download_backup():
    try:
        # Procura por arquivos de backup no diretório correto
        backup_files = [f for f in os.listdir(BACKUP_FOLDER) 
                       if f.startswith('backup_') and f.endswith('.sql')]
        
        if not backup_files:
            app.logger.error("No backup files found in directory")
            return jsonify({'error': 'No backup file available'}), 404
        
        # Pega o backup mais recente
        latest_backup = max(backup_files)
        backup_path = os.path.join(BACKUP_FOLDER, latest_backup)
        
        if not os.path.exists(backup_path):
            app.logger.error(f"Backup file not found: {backup_path}")
            return jsonify({'error': 'Backup file not found'}), 404

        try:
            return send_file(
                backup_path,
                mimetype='application/sql',
                as_attachment=True,
                download_name=latest_backup
            )
        except Exception as e:
            app.logger.error(f"Error sending file: {str(e)}")
            return jsonify({'error': 'Error sending backup file'}), 500
            
    except Exception as e:
        app.logger.error(f"Error in download_backup: {str(e)}")
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    socketio.run(app, host='0.0.0.0', port=5000)
