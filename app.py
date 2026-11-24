# -*- coding: utf-8 -*-
"""
Сайт НТО + МКД — Автодорожный округ г. Якутска (версия 4).
Поддерживает ДВЕ базы данных одновременно:
  - NtoDB (НТО) — основная
  - AvtodorDB (МКД) — вторая база
Сервер: waitress (production-grade, не зависает на Windows).
Авторизация: ЛЮБОЕ имя + пароль admin/editor (как в avto_web1).
"""
import os, json, re, uuid, shutil, secrets, datetime, io, socket, time, threading, functools, decimal
from flask import Flask, request, jsonify, session, send_from_directory, send_file, abort
from werkzeug.exceptions import HTTPException

BASE = os.path.dirname(os.path.abspath(__file__))
CFG_PATH = os.path.join(BASE, 'config.json')

# ----------- Создание config.json при первом запуске -----------
if not os.path.exists(CFG_PATH):
    alphabet = "abcdefghjkmnpqrstuvwxyz23456789"
    gen = lambda n: "".join(secrets.choice(alphabet) for _ in range(n))
    cfg = {
        'server': r'localhost\SQLEXPRESS',
        'database': 'NtoDB',           # НТО
        'database_mkd': 'AvtodorDB',   # МКД (пусто = отключено)
        'port': 8080,
        'secret': secrets.token_hex(32),
        # Один пароль admin и один editor — подходят для любого имени пользователя
        'admin_password': gen(8),
        'editor_password': gen(8),
    }
    json.dump(cfg, open(CFG_PATH, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
    print('Создан config.json — в нём пароли admin_password и editor_password.')

CFG = json.load(open(CFG_PATH, encoding='utf-8'))

UPLOAD = os.path.join(BASE, 'uploads'); TRASH = os.path.join(UPLOAD, '_удалённые')
for p in (UPLOAD, TRASH):
    if not os.path.isdir(p): os.makedirs(p)
BAD_EXT = set('exe bat cmd com msi scr js vbs ps1 dll jar sh lnk'.split())

# ВАЖНО: static_folder задаём АБСОЛЮТНЫМ путём — иначе Flask ищет папку относительно
# рабочей директории, и на некоторых запусках файлы статики (в т.ч. okrug_boundary.geojson) дают 404.
app = Flask(__name__, static_folder=os.path.join(BASE, 'static'), static_url_path='/static')
app.secret_key = CFG['secret']
# Лимит на размер ОДНОГО HTTP-запроса (включая все файлы в нём).
# 500 МБ — достаточно для пачки файлов или целой папки с документами.
# Если загрузить больше — Flask вернёт 413, и пользователь увидит понятное сообщение.
app.config['MAX_CONTENT_LENGTH'] = 500 * 1024 * 1024
app.config.update(SESSION_COOKIE_SAMESITE="Lax", PERMANENT_SESSION_LIFETIME=datetime.timedelta(hours=12))

# Обработка ошибки 413 (файл слишком большой) — возвращаем JSON, а не HTML
@app.errorhandler(413)
def too_large(e):
    return jsonify(error='Файлы слишком большие. Суммарный размер одного запроса — до 500 МБ. Загрузите файлы меньшими порциями.'), 413

# ============ Подключение к базам ============
def pick_driver():
    try:
        import pyodbc
        found = pyodbc.drivers()
        for name in ("ODBC Driver 18 for SQL Server", "ODBC Driver 17 for SQL Server", "ODBC Driver 13 for SQL Server"):
            if name in found: return name
        if "SQL Server" in found: return "SQL Server"
        raise RuntimeError("Не найден ODBC-драйвер. Найдены: " + ", ".join(found))
    except ImportError:
        return "ODBC Driver 17 for SQL Server"

DRIVER = pick_driver()

def _make_conn_str(dbname):
    return ('DRIVER={%s};SERVER=%s;DATABASE=%s;Trusted_Connection=yes;TrustServerCertificate=yes'
            % (DRIVER, CFG['server'], dbname))

def conn(db=None):
    """Открыть соединение. db=None → NtoDB (НТО); db='mkd' → AvtodorDB (МКД)."""
    import pyodbc
    if db == 'mkd':
        mkd_db = CFG.get('database_mkd') or ''
        if not mkd_db:
            abort(500, 'В config.json не указана database_mkd — база МКД не настроена.')
        return pyodbc.connect(_make_conn_str(mkd_db), timeout=8)
    return pyodbc.connect(_make_conn_str(CFG['database']), timeout=8)

def rows(sql, p=(), db=None):
    c = conn(db); cur = c.cursor(); cur.execute(sql, p)
    if cur.description:
        cols = [d[0] for d in cur.description]
        out = [dict(zip(cols, r)) for r in cur.fetchall()]
    else:
        out = []
    c.close(); return out

def run(sql, p=(), db=None):
    c = conn(db); c.cursor().execute(sql, p); c.commit(); c.close()

def insert_returning_id(table, d, idcol='id', db=None):
    """Универсальный INSERT, возвращающий id новой строки."""
    c = conn(db); cur = c.cursor(); k = list(d)
    cur.execute('INSERT INTO %s (%s) OUTPUT INSERTED.%s VALUES (%s)' % (table, ','.join(k), idcol, ','.join('?' * len(k))), [d[x] for x in k])
    i = cur.fetchone()[0]; c.commit(); c.close(); return i

# Старый API для совместимости с NTO кодом — там id автоинкремент
def insert(table, d, db=None):
    return insert_returning_id(table, d, 'id', db)

# ============ Хост пользователя (IP + имя компьютера) ============
def get_host_info():
    ip = request.remote_addr or ''
    xff = request.headers.get('X-Forwarded-For', '')
    if xff:
        ip = xff.split(',')[0].strip()
    hostname = ''
    if ip:
        try:
            result = [None]
            def _do():
                try: result[0] = socket.gethostbyaddr(ip)[0]
                except Exception: result[0] = None
            t = threading.Thread(target=_do, daemon=True); t.start(); t.join(1.5)
            hostname = result[0] or ''
        except Exception:
            hostname = ''
    return ip, hostname

# ============ Онлайн-пользователи (в памяти) ============
ONLINE = {}
ONLINE_LOCK = threading.Lock()
ONLINE_TIMEOUT = 300

def track_online(page=''):
    sid = session.get('_sid') or ''
    if not sid:
        sid = secrets.token_hex(8); session['_sid'] = sid
    ip, host = get_host_info()
    user = session.get('name') or '(аноним)'
    with ONLINE_LOCK:
        ONLINE[sid] = {
            'user': user, 'ip': ip, 'host': host,
            'last_seen': time.time(), 'page': page,
            'started': ONLINE.get(sid, {}).get('started', time.time()),
        }
        now = time.time()
        for k in list(ONLINE.keys()):
            if now - ONLINE[k]['last_seen'] > ONLINE_TIMEOUT:
                del ONLINE[k]

def online_list():
    now = time.time()
    out = []
    with ONLINE_LOCK:
        for sid, v in ONLINE.items():
            out.append({
                'user': v['user'], 'ip': v['ip'], 'host': v['host'],
                'page': v['page'],
                'seconds_ago': int(now - v['last_seen']),
                'session_seconds': int(now - v.get('started', now)),
                'active': (now - v['last_seen']) < 60,
            })
    out.sort(key=lambda x: -x['session_seconds'])
    return out

# ============ Поля НТО ============
FIELDS = ['in_scheme','scheme_num','address','address_alt','map_url','lat','lon','area','authority','owner_name','inn','ogrn',
          'fns_status','fns_date','obj_kind','trade_type','specialization','trade_area','term_text','term_start','term_end',
          'conditions','notes','contract_state','chk_contract','chk_kkt','chk_match','chk_compare','chk_kupavy','phone','comment','src']
DATES = ('fns_date', 'term_start', 'term_end')

# Максимальная длина каждого поля (для защиты от усечения)
# Реальные размеры в SQL Server см. в миграции 05.
MAX_LEN = {
    'scheme_num': 20, 'address': 500, 'address_alt': 500, 'map_url': 500,
    'area': 50, 'authority': 1000, 'owner_name': 500, 'inn': 12, 'ogrn': 15,
    'fns_status': 200, 'obj_kind': 200, 'trade_type': 200, 'specialization': 500,
    'trade_area': 50, 'term_text': 300, 'conditions': 2000, 'notes': 4000,
    'contract_state': 30, 'chk_contract': 500, 'chk_kkt': 500, 'chk_match': 500,
    'chk_compare': 500, 'chk_kupavy': 500, 'phone': 500, 'comment': 4000, 'src': 200,
}

def fmt(v):
    if isinstance(v, datetime.datetime): return v.strftime('%d.%m.%Y %H:%M')
    if isinstance(v, datetime.date): return v.strftime('%d.%m.%Y')
    if v is not None and v.__class__.__name__ == 'Decimal': return round(float(v), 2)
    return v

def pdate(s):
    s = (s or '').strip()
    if not s: return None
    if re.fullmatch(r'\d{8}', s):
        d, m, y = s[:2], s[2:4], s[4:]
        return datetime.date(int(y), int(m), int(d))
    m = re.match(r'^(\d{4})-(\d{2})-(\d{2})', s)
    if m:
        return datetime.date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    m = re.match(r'^(\d{1,2})[.\-/](\d{1,2})[.\-/](\d{4})$', s)
    if m:
        d, mo, y = m.groups()
        return datetime.date(int(y), int(mo), int(d))
    raise ValueError('Дата должна быть в виде ДД.ММ.ГГГГ (можно без точек: 11122025): ' + s)

def state(o):
    if o.get('contract_state'): return o['contract_state']
    t = ((o.get('conditions') or '') + ' ' + (o.get('notes') or '') + ' ' + (o.get('comment') or '')).lower()
    if 'расторгнут' in t: return 'Расторгнут'
    if 'прекращ' in t: return 'Прекращён'
    if 'на расторжение' in t or 'расторжени' in t: return 'На расторжение'
    e = o.get('term_end')
    if isinstance(e, str):
        try: e = pdate(e)
        except Exception: e = None
    if isinstance(e, datetime.datetime): e = e.date()
    if e:
        d = (e - datetime.date.today()).days
        return 'Истёк' if d < 0 else ('Истекает' if d < 90 else 'Действует')
    if 'договор' in t or 'дс' in t or (o.get('chk_contract') or '').lower().startswith('есть'): return 'Срок не указан'
    return 'Нет договора'

def prep(o):
    r = {k: fmt(v) for k, v in o.items() if k not in ('created_at', 'updated_at')}
    r['state'] = state(o); r['in_scheme'] = 1 if o.get('in_scheme') else 0
    return r

# ============ Авторизация (имя + пароль) ============
def role(): return session.get('role')

def need(level):
    allowed = ('editor', 'admin') if level == 'editor' else ('admin',)
    def deco(fn):
        @functools.wraps(fn)
        def wrap(*a, **k):
            if session.get('role') not in allowed:
                return jsonify({'error': 'Для этого действия нужно войти' + (' как администратор.' if level == 'admin' else '.')}), 403
            return fn(*a, **k)
        return wrap
    return deco

@app.errorhandler(Exception)
def on_error(e):
    if isinstance(e, HTTPException):
        return e
    import traceback
    traceback.print_exc()
    msg = str(e)
    # Особый случай: усечение строки в SQL Server
    if 'усечение' in msg.lower() or 'string or binary data would be truncated' in msg.lower():
        return jsonify({'error': 'Слишком длинный текст для одного из полей. Сократите текст или запустите миграцию 05_widen_text_columns.sql'}), 400
    return jsonify({'error': msg}), 500

@app.errorhandler(413)
def _e413(e): return jsonify(error='Файл слишком большой (максимум 30 МБ).'), 413

# ============ Журнал НТО (с IP и компьютером) ============
def log_nto(action, oid, before=None, after=None):
    ip, host = get_host_info()
    try:
        run('INSERT INTO nto_journal (at, user_name, action, object_id, before_val, after_val, host_ip, host_name) '
            'VALUES (SYSDATETIME(), ?, ?, ?, ?, ?, ?, ?)',
            (session.get('name'), action, oid,
             json.dumps(before, ensure_ascii=False, default=str) if before is not None else None,
             json.dumps(after, ensure_ascii=False, default=str) if after is not None else None,
             ip, host))
    except Exception:
        try:
            run('INSERT INTO nto_journal (user_name, action, object_id, before_val, after_val) VALUES (?,?,?,?,?)',
                (session.get('name'), action, oid,
                 json.dumps(before, ensure_ascii=False, default=str) if before is not None else None,
                 json.dumps(after, ensure_ascii=False, default=str) if after is not None else None))
        except Exception as e2:
            print('LOG FAIL:', e2)

# ============ BEFORE — трекинг онлайн-сессий ============
@app.before_request
def _before():
    try: track_online(request.path)
    except Exception: pass

@app.after_request
def no_cache(resp):
    resp.headers["Cache-Control"] = "no-store"
    return resp

# ============ Вход/выход ============
@app.route('/api/login', methods=['POST'])
def login():
    b = request.get_json(force=True) or {}
    name = (b.get('name') or b.get('user') or '').strip()
    pw = b.get('password') or ''
    if not name:
        return jsonify({'error': 'Впишите своё имя — оно попадёт в журнал изменений.'}), 400
    role_val = None
    if secrets.compare_digest(pw, CFG.get('admin_password', '')): role_val = 'admin'
    elif secrets.compare_digest(pw, CFG.get('editor_password', '')): role_val = 'editor'
    # Обратная совместимость: если в config.json есть users (admin/editor → пароль), поддержим и их
    if not role_val:
        users = CFG.get('users', {})
        for un, up in users.items():
            if secrets.compare_digest(pw, up or ''):
                role_val = 'admin' if un == 'admin' else 'editor'
                break
    if not role_val:
        time.sleep(1)
        return jsonify({'error': 'Неверный пароль.'}), 401
    session.permanent = True
    session['name'] = name[:100]
    session['role'] = role_val
    # Запись в таблицу session_log (если миграция 04 выполнена)
    ip, host = get_host_info()
    try:
        run('INSERT INTO nto_session_log (user_name, host_ip, host_name, action, page) VALUES (?,?,?,?,?)',
            (name, ip, host, 'login', '/login'))
    except Exception: pass
    return jsonify({'name': name, 'role': role_val})

@app.route('/api/logout', methods=['POST'])
def logout():
    sid = session.get('_sid')
    if sid:
        with ONLINE_LOCK: ONLINE.pop(sid, None)
    session.clear()
    return jsonify(ok=True)

@app.route('/api/me')
def me():
    return jsonify({'name': session.get('name'), 'role': role()})

@app.route('/api/online')
def online():
    if role() != 'admin':
        return jsonify({'error': 'Только для администратора.'}), 403
    return jsonify(online_list())

# ============ НТО — CRUD ============
def clean(d):
    """Очистить и проверить поля НТО. Обрезать слишком длинные значения."""
    out = {}
    for k in FIELDS:
        if k not in d: continue
        v = d[k]
        if isinstance(v, str): v = v.strip()
        if v == '': v = None
        if k in DATES:
            v = pdate(v) if v else None
        if k == 'in_scheme':
            v = 1 if str(v) in ('1', 'True', 'true') else 0
        if k in ('lat', 'lon') and v is not None:
            try: v = float(str(v).replace(',', '.'))
            except: v = None
        # Обрезаем слишком длинные значения
        if k in MAX_LEN and isinstance(v, str) and len(v) > MAX_LEN[k]:
            v = v[:MAX_LEN[k]]
        out[k] = v
    if out.get('inn') and not re.fullmatch(r'\d{10}|\d{12}', out['inn']):
        raise ValueError('ИНН: должно быть 10 цифр (организация) или 12 цифр (ИП).')
    if out.get('ogrn') and not re.fullmatch(r'\d{13}|\d{15}', out['ogrn']):
        raise ValueError('ОГРН: 13 цифр, ОГРНИП: 15 цифр.')
    return out

@app.route('/api/nto')
def nto_list():
    q = (request.args.get('q') or '').lower().strip(); sc = request.args.get('scheme'); st = request.args.get('state')
    data = [prep(o) for o in rows('SELECT * FROM nto_object WHERE is_deleted=0')]
    cnt = {r['object_id']: r['n'] for r in rows('SELECT object_id, COUNT(*) AS n FROM nto_file WHERE is_deleted=0 GROUP BY object_id')}
    out = []
    for o in data:
        o['files'] = cnt.get(o['id'], 0)
        if sc in ('0', '1') and str(o['in_scheme']) != sc: continue
        if st and o['state'] != st: continue
        if q and q not in ' '.join(str(o.get(k) or '') for k in ('scheme_num','address','address_alt','owner_name','inn','ogrn','specialization','phone','conditions','notes','comment','obj_kind')).lower(): continue
        out.append(o)
    return jsonify(out)

@app.route('/api/nto/<int:i>')
def nto_get(i):
    r = rows('SELECT * FROM nto_object WHERE id=? AND is_deleted=0', (i,))
    if not r: abort(404)
    o = prep(r[0]); o['file_list'] = []
    if role():
        file_rows = rows('SELECT id,file_name,caption,is_photo,size_bytes,uploaded_by,uploaded_at FROM nto_file WHERE object_id=? AND is_deleted=0 ORDER BY id', (i,))
    else:
        file_rows = rows('SELECT id,file_name,caption,is_photo,size_bytes,uploaded_by,uploaded_at FROM nto_file WHERE object_id=? AND is_deleted=0 AND is_photo=1 ORDER BY id', (i,))
    o['file_list'] = [{k: fmt(v) for k, v in f.items()} for f in file_rows]
    o['file_count_total'] = rows('SELECT COUNT(*) AS n FROM nto_file WHERE object_id=? AND is_deleted=0', (i,))[0]['n']
    return jsonify(o)

@app.route('/api/nto', methods=['POST'])
@need('editor')
def nto_add():
    try: d = clean(request.get_json() or {})
    except ValueError as e: return jsonify(error=str(e)), 400
    d.setdefault('in_scheme', 1)
    i = insert('nto_object', d); log_nto('добавление', i, None, d)
    return jsonify(id=i)

@app.route('/api/nto/<int:i>', methods=['PUT'])
@need('editor')
def nto_edit(i):
    old = rows('SELECT * FROM nto_object WHERE id=? AND is_deleted=0', (i,))
    if not old: abort(404)
    try: d = clean(request.get_json() or {})
    except ValueError as e: return jsonify(error=str(e)), 400
    ch = {k: v for k, v in d.items() if (old[0][k] if not isinstance(old[0][k], bool) else int(old[0][k])) != v and not (old[0][k] is None and v is None)}
    if ch:
        run('UPDATE nto_object SET %s, updated_at=SYSDATETIME() WHERE id=?' % ','.join(k + '=?' for k in ch), list(ch.values()) + [i])
        log_nto('изменение', i, {k: old[0][k] for k in ch}, ch)
    return jsonify(ok=1, changed=len(ch))

@app.route('/api/nto/<int:i>', methods=['DELETE'])
@need('admin')
def nto_del(i):
    old = rows('SELECT * FROM nto_object WHERE id=? AND is_deleted=0', (i,))
    if not old: abort(404)
    log_nto('удаление', i, old[0], None)
    run('UPDATE nto_object SET is_deleted=1, updated_at=SYSDATETIME() WHERE id=?', (i,))
    return jsonify(ok=1)

# ============ Файлы ============
@app.route('/api/nto/<int:i>/files', methods=['POST'])
@need('editor')
def file_add(i):
    """Загрузка одного или нескольких файлов к НТО.
       Принимает multipart/form-data с одним или несколькими полями 'file'.
       Возвращает {added: N, ids: [...], skipped: [...]}."""
    if not rows('SELECT id FROM nto_object WHERE id=? AND is_deleted=0', (i,)): abort(404)
    files = request.files.getlist('file')
    if not files or all(not f.filename for f in files):
        return jsonify(error='Файлы не выбраны.'), 400
    folder = os.path.join(UPLOAD, 'nto_%d' % i)
    if not os.path.isdir(folder): os.makedirs(folder)
    added_ids = []
    skipped = []
    for f in files:
        if not f or not f.filename:
            continue
        ext = f.filename.rsplit('.', 1)[-1].lower() if '.' in f.filename else ''
        if not ext or ext in BAD_EXT:
            skipped.append({'name': f.filename, 'reason': 'недопустимый тип'})
            continue
        stored = uuid.uuid4().hex + '.' + ext
        try:
            f.save(os.path.join(folder, stored))
            photo = 1 if ext in ('jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic') else 0
            fid = insert('nto_file', dict(object_id=i, file_name=f.filename[:300], stored_name=stored,
                         caption='', is_photo=photo,
                         size_bytes=os.path.getsize(os.path.join(folder, stored)),
                         uploaded_by=session.get('name')))
            added_ids.append(fid)
            log_nto('файл добавлен', i, None, {'file': f.filename})
        except Exception as e:
            skipped.append({'name': f.filename, 'reason': str(e)[:100]})
    return jsonify(added=len(added_ids), ids=added_ids, skipped=skipped)

@app.route('/api/nto/<int:i>/files/delete', methods=['POST'])
@need('editor')
def nto_files_delete(i):
    """Удаление нескольких файлов НТО сразу.
       Принимает JSON: {"ids": [1, 2, 3]}.
       Файлы помечаются is_deleted=1 (мягкое удаление), физически переносятся в TRASH."""
    if not rows('SELECT id FROM nto_object WHERE id=? AND is_deleted=0', (i,)): abort(404)
    d = request.get_json() or {}
    ids = d.get('ids') or []
    if not ids:
        return jsonify(error='Список ids пуст.'), 400
    deleted = []
    for fid in ids:
        try:
            fid = int(fid)
            r = rows('SELECT * FROM nto_file WHERE id=? AND object_id=? AND is_deleted=0', (fid, i))
            if not r:
                continue
            r = r[0]
            src = os.path.join(UPLOAD, 'nto_%d' % r['object_id'], r['stored_name'])
            if os.path.exists(src):
                shutil.move(src, os.path.join(TRASH, '%d_%s' % (fid, r['stored_name'])))
            run('UPDATE nto_file SET is_deleted=1 WHERE id=?', (fid,))
            log_nto('файл удалён', r['object_id'], {'file': r['file_name']}, None)
            deleted.append(fid)
        except Exception as e:
            print('file delete error fid=%s: %s' % (fid, e))
    return jsonify(ok=1, deleted=deleted, count=len(deleted))

def frow(fid):
    r = rows('SELECT * FROM nto_file WHERE id=? AND is_deleted=0', (fid,))
    if not r: abort(404)
    return r[0]

@app.route('/api/files/<int:fid>')
def file_get(fid):
    r = frow(fid)
    if not r['is_photo']:
        if role() not in ('admin', 'editor'):
            return jsonify(error='Нужно войти.'), 401
    return send_from_directory(os.path.join(UPLOAD, 'nto_%d' % r['object_id']), r['stored_name'],
                               as_attachment=not r['is_photo'], download_name=r['file_name'])

@app.route('/api/files/<int:fid>', methods=['DELETE'])
@need('editor')
def file_del(fid):
    r = frow(fid)
    src = os.path.join(UPLOAD, 'nto_%d' % r['object_id'], r['stored_name'])
    if os.path.exists(src): shutil.move(src, os.path.join(TRASH, '%d_%s' % (fid, r['stored_name'])))
    run('UPDATE nto_file SET is_deleted=1 WHERE id=?', (fid,)); log_nto('файл удалён', r['object_id'], {'file': r['file_name']}, None)
    return jsonify(ok=1)

# ============ Журнал ============
@app.route('/api/journal')
@need('admin')
def journal():
    try:
        return jsonify([{k: fmt(v) for k, v in r.items()} for r in rows(
            'SELECT TOP 300 id, at, user_name, action, object_id, host_ip, host_name, before_val, after_val '
            'FROM nto_journal ORDER BY id DESC')])
    except Exception:
        return jsonify([{k: fmt(v) for k, v in r.items()} for r in rows(
            'SELECT TOP 300 id, at, user_name, action, object_id, before_val, after_val '
            'FROM nto_journal ORDER BY id DESC')])

# ============ Карта-заглушка: точки ============
@app.route('/api/map_points')
def map_points_list():
    """Старый endpoint для заглушки-картинки. Возвращает точки с x_pct/y_pct."""
    try:
        return jsonify([{k: fmt(v) for k, v in r.items()} for r in rows(
            'SELECT id, object_id, x_pct, y_pct, label, color, is_test, updated_at FROM nto_map_point ORDER BY id')])
    except Exception:
        return jsonify([])

@app.route('/api/map_markers')
def map_markers_list():
    """Endpoint для Leaflet-карты. Параметр kind: nto (по умолчанию) | mkd | all.
       kind=nto → точки НТО из NtoDB: 1) кастомные точки nto_map_point с lat/lon,
       2) НТО-объекты (nto_object) с lat/lon.
       kind=mkd → точки МКД напрямую из AvtodorDB.House (с lat/lon, не снесённые).
       Карта зеркалит базы SQL Server: дом есть в AvtodorDB с координатами → показываем;
       нет в базе или снесён → не показываем. Аналогично для НТО: удалённые НТО скрыты.
       Для МКД нужна миграция 11 (добавляет колонки Lat, Lon, IsDemolished и др. в House).
    """
    kind = (request.args.get('kind') or 'nto').strip().lower()
    if kind not in ('nto', 'mkd', 'all'):
        kind = 'nto'
    out = []
    covered_object_ids = set()
    # ============ РЕЖИМ МКД — точки берём напрямую из AvtodorDB.House ============
    # (НЕ из nto_map_point!) — карта зеркалит базу МКД: дом есть в AvtodorDB.House
    # с координатами → показываем; нет в базе → не показываем; снесён → не показываем.
    # Чтобы работало, нужна миграция 11 (добавляет колонки Lat, Lon, IsDemolished и т.д.).
    if kind in ('mkd', 'all'):
        try:
            # проверим, что колонки Lat/Lon добавлены (миграция 11 выполнена)
            cols_ok = rows(
                "SELECT COUNT(*) AS c FROM sys.columns "
                "WHERE object_id = OBJECT_ID(N'AvtodorDB.dbo.House') "
                "AND name IN ('Lat','Lon')", db='mkd')
            if cols_ok and cols_ok[0]['c'] >= 2:
                # выбираем дома с координатами, кроме снесённых
                sql = (
                    "SELECT h.HouseID AS hid, h.Street, h.HouseNo, h.FullAddress, "
                    "h.Floors, h.FlatsCount, h.YearBuilt, h.IsEmergency, "
                    "h.IsDemolished, h.DemolitionDate, h.ActNumber, h.RelocationProgram, "
                    "h.IsResettled, h.Quarter, h.ResidentsCount, h.Area, "
                    "h.HouseType, h.HeatingType, h.StatusText, h.Note, "
                    "h.IsAuction, h.IsNoUk, h.IsUndefined, h.IsEgrnQuery, h.CoordsApprox, "
                    "h.Lat, h.Lon, h.UKName, uk.Name AS uk_name "
                    "FROM AvtodorDB.dbo.House h "
                    "LEFT JOIN AvtodorDB.dbo.UK uk ON uk.UKID = h.UKID "
                    "WHERE h.Lat IS NOT NULL AND h.Lon IS NOT NULL "
                    "  AND ISNULL(h.IsDemolished, 0) = 0 "
                    "  AND ISNULL(h.IsHiddenFromMap, 0) = 0 "
                    "ORDER BY h.Street, h.HouseNo")
                houses = rows(sql, db='mkd')
                for h in houses:
                    label_parts = []
                    if h.get('Street'):
                        label_parts.append(str(h['Street']).strip())
                    if h.get('HouseNo'):
                        label_parts.append(str(h['HouseNo']).strip())
                    label = ', '.join(label_parts) or (h.get('FullAddress') or ('дом #' + str(h['hid'])))
                    desc = []
                    uk = h.get('uk_name') or h.get('UKName')
                    if uk:
                        desc.append('УК: ' + str(uk))
                    if h.get('HouseType'):
                        desc.append(str(h['HouseType']))
                    if h.get('HeatingType'):
                        desc.append('отопление: ' + str(h['HeatingType']))
                    if h.get('Floors'):
                        desc.append('этажей: ' + str(h['Floors']))
                    if h.get('FlatsCount'):
                        desc.append('квартир: ' + str(h['FlatsCount']))
                    if h.get('ResidentsCount'):
                        desc.append('жильцов: ' + str(h['ResidentsCount']))
                    if h.get('Area'):
                        desc.append('площадь: ' + str(h['Area']) + ' м²')
                    if h.get('YearBuilt'):
                        desc.append('год: ' + str(h['YearBuilt']))
                    if h.get('Quarter'):
                        desc.append('квартал: ' + str(h['Quarter']))
                    if h.get('IsEmergency'):
                        desc.append('АВАРИЙНЫЙ')
                        if h.get('ActNumber'):
                            desc.append('распоряжение: ' + str(h['ActNumber']))
                        if h.get('RelocationProgram'):
                            desc.append('программа: ' + str(h['RelocationProgram']))
                        if h.get('DemolitionDate'):
                            desc.append('снос: ' + str(h['DemolitionDate'])[:10])
                        if h.get('IsResettled'):
                            desc.append('РАССЕЛЁН')
                    if h.get('IsAuction'):
                        desc.append('АУКЦИОН (выбор УК)')
                    if h.get('IsNoUk'):
                        desc.append('БЕЗ УК')
                    if h.get('IsUndefined'):
                        desc.append('способ управления не определён')
                    if h.get('IsEgrnQuery'):
                        desc.append('запрос ЕГРН')
                    if h.get('Note'):
                        desc.append('примечание: ' + str(h['Note']))
                    if h.get('CoordsApprox'):
                        desc.append('координаты приблизительные')
                    out.append({
                        'source': 'mkd',
                        'id': h['hid'],
                        'object_id': h['hid'],
                        'object_type': 'mkd',
                        'lat': float(h['Lat']),
                        'lon': float(h['Lon']),
                        'label': label,
                        'color': 'violet',
                        'is_test': 0,
                        'description': '\n'.join(desc),
                        'emergency': 1 if h.get('IsEmergency') else 0,
                        'demolished': 1 if h.get('IsDemolished') else 0,
                        'resettled': 1 if h.get('IsResettled') else 0,
                        'auction': 1 if h.get('IsAuction') else 0,
                        'no_uk': 1 if h.get('IsNoUk') else 0,
                        'coords_approx': 1 if h.get('CoordsApprox') else 0,
                        'uk_name': uk or '',
                    })
            else:
                print('map_markers: колонок Lat/Lon нет в AvtodorDB.House — выполните миграцию 11')
        except Exception as e:
            print('map_markers mkd error (AvtodorDB недоступна?):', e)
        if kind == 'mkd':
            return jsonify(out)  # для МКД только дома из AvtodorDB, без НТО
    # ============ РЕЖИМ НТО — точки из NtoDB ============
    # (только для НТО; object_type='mkd' больше НЕ используется для карты)
    try:
        where = 'WHERE lat IS NOT NULL AND lon IS NOT NULL'
        if kind == 'nto':
            # карта зеркалит базу: точки МКД не показываем, а точки, привязанные
            # к удалённым/несуществующим НТО, скрываем (НТО мог быть удалён позже)
            where += (" AND ISNULL(object_type, 'nto') <> 'mkd'"
                      " AND (object_id IS NULL OR EXISTS (SELECT 1 FROM nto_object o"
                      " WHERE o.id = nto_map_point.object_id AND o.is_deleted = 0))")
        pts = rows('SELECT id, object_id, object_type, lat, lon, label, color, is_test, description, updated_at '
                   'FROM nto_map_point ' + where + ' ORDER BY id')
        for r in pts:
            out.append({
                'source': 'custom',
                'id': r['id'],
                'object_id': r.get('object_id'),
                'object_type': r.get('object_type') or 'nto',
                'lat': float(r['lat']),
                'lon': float(r['lon']),
                'label': r.get('label') or '',
                'color': r.get('color') or 'red',
                'is_test': 1 if r.get('is_test') else 0,
                'description': r.get('description') or '',
            })
            if r.get('object_id'):
                covered_object_ids.add(r['object_id'])
    except Exception as e:
        print('map_markers custom error:', e)
    # ============ НТО-объекты с координатами (пропускаем те, что уже показаны) ============
    if kind in ('nto', 'all'):
        try:
            objs = rows('SELECT id, scheme_num, in_scheme, address, owner_name, inn, specialization, lat, lon '
                        'FROM nto_object WHERE is_deleted=0 AND lat IS NOT NULL AND lon IS NOT NULL')
            for o in objs:
                if o['id'] in covered_object_ids:
                    continue  # уже есть кастомный маркер с привязкой к этому НТО
                out.append({
                    'source': 'nto',
                    'id': o['id'],
                    'object_id': o['id'],
                    'object_type': 'nto',
                    'lat': float(o['lat']),
                    'lon': float(o['lon']),
                    'label': '#' + str(o.get('scheme_num') or '?') + ' ' + (o.get('address') or ''),
                    'color': 'blue' if o.get('in_scheme') else 'orange',
                    'is_test': 0,
                    'description': (o.get('specialization') or '') + ' · ' + (o.get('owner_name') or '') + (('\nИНН: ' + o['inn']) if o.get('inn') else ''),
                })
        except Exception as e:
            print('map_markers nto error:', e)
    return jsonify(out)

def _check_point_link(oid, object_type):
    """Проверка ссылки точки карты на НТО. Внешний ключ object_id -> nto_object
    снят миграцией 10 (точкам МКД в object_id пишется номер дома из AvtodorDB,
    а не номер НТО), поэтому корректность ссылки проверяем здесь, на уровне приложения."""
    if not oid or (object_type or 'nto') == 'mkd':
        return None
    if not rows('SELECT id FROM nto_object WHERE id=? AND is_deleted=0', (oid,)):
        return 'НТО №%s не найден в базе (или удалён) — проверьте номер объекта.' % oid
    return None

@app.route('/api/map_points', methods=['POST'])
@need('editor')
def map_point_add():
    d = request.get_json() or {}
    # поддерживаем как lat/lon (новый формат), так и x_pct/y_pct (старый)
    rec = dict(is_test=0, x_pct=None, y_pct=None)  # явно NULL, чтобы не падало на NOT NULL
    if 'lat' in d and 'lon' in d:
        rec['lat'] = float(d['lat']); rec['lon'] = float(d['lon'])
        rec['object_type'] = (d.get('object_type') or 'nto')[:10]
    elif 'x_pct' in d and 'y_pct' in d:
        x = float(d['x_pct']); y = float(d['y_pct'])
        if not (0 <= x <= 100 and 0 <= y <= 100):
            return jsonify(error='x_pct/y_pct должны быть 0..100'), 400
        rec['x_pct'] = x; rec['y_pct'] = y
    else:
        return jsonify(error='Нужны lat/lon или x_pct/y_pct'), 400
    rec['object_id'] = int(d['object_id']) if d.get('object_id') else None
    err = _check_point_link(rec['object_id'], rec.get('object_type', 'nto'))
    if err: return jsonify(error=err), 400
    rec['label'] = (d.get('label') or '')[:200] or None
    rec['color'] = (d.get('color') or 'red')[:20]
    rec['description'] = (d.get('description') or '')[:500] or None
    i = insert('nto_map_point', rec)
    log_nto('точка карты добавлена', None, None, d)
    return jsonify(id=i)

@app.route('/api/map_points/<int:pid>', methods=['PUT'])
@need('editor')
def map_point_edit(pid):
    d = request.get_json() or {}
    sets = []; vals = []
    for k in ('x_pct', 'y_pct', 'lat', 'lon', 'label', 'color', 'object_id', 'object_type', 'description'):
        if k in d:
            v = d[k]
            if k in ('x_pct', 'y_pct', 'lat', 'lon'):
                if v is None or v == '':
                    v = None
                else:
                    v = float(v)
                    if k in ('x_pct', 'y_pct') and not (0 <= v <= 100):
                        return jsonify(error='x_pct/y_pct 0..100'), 400
                    if k in ('lat',) and not (-90 <= v <= 90):
                        return jsonify(error='lat должна быть -90..90'), 400
                    if k in ('lon',) and not (-180 <= v <= 180):
                        return jsonify(error='lon должна быть -180..180'), 400
            if k == 'object_id':
                v = int(v) if v else None
                cur_row = rows("SELECT ISNULL(object_type, 'nto') AS t FROM nto_map_point WHERE id=?", (pid,))
                cur_type = cur_row[0]['t'] if cur_row else 'nto'
                err = _check_point_link(v, d.get('object_type') or cur_type)
                if err: return jsonify(error=err), 400
            if k == 'label': v = (v or '')[:200] or None
            if k == 'color': v = (v or 'red')[:20]
            if k == 'object_type': v = (v or 'nto')[:10]
            if k == 'description': v = (v or '')[:500] or None
            sets.append('%s=?' % k); vals.append(v)
    if not sets: return jsonify(ok=0, changed=0)
    sets.append('updated_at=SYSDATETIME()'); vals.append(pid)
    run('UPDATE nto_map_point SET %s WHERE id=?' % ','.join(sets), vals)
    log_nto('точка карты изменена', None, None, d)
    return jsonify(ok=1)

@app.route('/api/map_points/<int:pid>', methods=['DELETE'])
@need('admin')
def map_point_del(pid):
    run('DELETE FROM nto_map_point WHERE id=?', (pid,))
    log_nto('точка карты удалена', None, None, None)
    return jsonify(ok=1)

@app.route('/api/map_image')
def map_image():
    """Старая заглушка-картинка. Оставлена для совместимости."""
    img = os.path.join(BASE, 'static', 'map_stub.jpg')
    if not os.path.exists(img):
        abort(404, 'Файл static/map_stub.jpg не найден.')
    return send_file(img, mimetype='image/jpeg')

# ============ МКД — ПОЛНОЦЕННЫЕ маршруты из avto_web1 ============
# Преобразования значений для МКД
def s_(v):
    if v is None: return None
    t = str(v).strip()
    return t or None

def i_(v):
    t = s_(v)
    if t is None: return None
    try: return int(float(t.replace(",", ".")))
    except ValueError: raise ValueError("Здесь нужно целое число: " + t)

def d_(v):
    t = s_(v)
    if t is None: return None
    try: return round(float(t.replace(",", ".")), 2)
    except ValueError: raise ValueError("Здесь нужно число: " + t)

def b_(v):
    return 1 if v in (True, 1, "1", "true", "on") else 0

HOUSE = {"street": ("Street", s_), "house_no": ("HouseNo", s_), "uk_id": ("UKID", i_), "heat_source": ("HeatSource", s_),
         "heat_system": ("HeatSystem", s_), "heat_supplier": ("HeatSupplier", s_), "service_org": ("ServiceOrg", s_),
         "year_built": ("YearBuilt", i_), "floors": ("Floors", i_), "flats": ("FlatsCount", i_), "wall": ("WallMaterial", s_),
         "municipal_percent": ("MunicipalPercent", d_), "municipal_note": ("MunicipalNote", s_),
         "emergency": ("IsEmergency", b_), "auction": ("IsAuction", b_), "note": ("Note", s_)}
REG = {"premises": ("PremisesCount", i_), "cap_repair": ("LastCapRepair", s_), "tech_state": ("TechState", s_),
       "contract_start": ("ContractStart", s_), "contract_end": ("ContractEnd", s_), "faults": ("Faults", s_), "reg_note": ("RegistryNote", s_)}
EM = {"quarter": ("Quarter", s_), "residents": ("Residents", i_), "area": ("TotalAreaM2", d_), "act": ("ActText", s_)}
NOUK = {"order_text": ("OrderText", s_), "kind": ("HouseKind", s_), "egrn": ("EgrnType", s_), "status": ("Status", s_),
        "municipal": ("MunicipalFlats", s_), "refused_by": ("RefusedBy", s_), "gis_type": ("GisType", s_), "roa": ("RoaText", s_),
        "program": ("ProgramText", s_), "deadline": ("RelocationDeadline", s_)}
SECTION_TABLES = {"registry": ("HouseRegistryInfo", REG), "emergency": ("HouseEmergency", EM), "no_uk": ("HouseNoUK", NOUK)}

def conv(data, spec):
    out = {}
    for k, (col, fn) in spec.items():
        if k in data:
            out[col] = fn(data[k])
    return out

def norm(v):
    if isinstance(v, (decimal.Decimal, float)): return round(float(v), 2)
    if isinstance(v, bool): return int(v)
    return v

def write_mkd_log(cur, action, table, rid, details):
    cur.execute("INSERT INTO dbo.ChangeLog (UserName, Role, Action, TableName, RecordID, Details) VALUES (?, ?, ?, ?, ?, ?)",
                session.get("name"), session.get("role"), action, table, rid,
                json.dumps(details, ensure_ascii=False, default=str)[:3900])

def lookup_id(cur, table, idcol, name):
    name = s_(name)
    if not name: return None
    cur.execute("SELECT " + idcol + " FROM dbo." + table + " WHERE Name = ?", name)
    r = cur.fetchone()
    if r: return r[0]
    cur.execute("INSERT INTO dbo." + table + " (Name) OUTPUT INSERTED." + idcol + " VALUES (?)", name)
    return cur.fetchone()[0]

def row_dict(cur):
    r = cur.fetchone()
    if r is None: return None
    return dict(zip([c[0] for c in cur.description], r))

def save_section(cur, hid, table, vals):
    cur.execute("SELECT * FROM dbo." + table + " WHERE HouseID = ?", hid)
    old = row_dict(cur)
    if all(v is None for v in vals.values()):
        if old:
            cur.execute("DELETE FROM dbo." + table + " WHERE HouseID = ?", hid)
            write_mkd_log(cur, "удаление блока", table, hid, {"было": {k: v for k, v in old.items() if v is not None}})
        return
    if old:
        diff = {c: [old.get(c), v] for c, v in vals.items() if norm(old.get(c)) != norm(v)}
        if diff:
            cur.execute("UPDATE dbo." + table + " SET " + ", ".join(c + " = ?" for c in vals) + " WHERE HouseID = ?", *vals.values(), hid)
            write_mkd_log(cur, "изменение", table, hid, diff)
    else:
        cols = ["HouseID"] + list(vals)
        cur.execute("INSERT INTO dbo." + table + " (" + ", ".join(cols) + ") VALUES (" + ", ".join("?" * len(cols)) + ")", hid, *vals.values())
        write_mkd_log(cur, "добавление блока", table, hid, {c: v for c, v in vals.items() if v is not None})

def run_tx_mkd(fn):
    c = conn('mkd')
    try:
        cur = c.cursor()
        res = fn(cur)
        c.commit()
        return res
    except Exception:
        c.rollback()
        raise
    finally:
        c.close()

# Кэш для МКД
_cache = {"t": 0, "data": None}
def drop_cache():
    _cache["data"] = None

# Базовый запрос к AvtodorDB. LEFT JOIN к HouseNoUK добавляется только если таблица существует
# (в базе пользователя её может не быть).
BASE_MKD_SQL_CORE = """
SELECT h.HouseID AS id, h.FullAddress AS address, h.Street AS street, h.HouseNo AS house_no, h.UKID AS uk_id, uk.Name AS uk,
       ht.Name AS house_type, he.Name AS heating, h.HeatSource AS heat_source, h.HeatSystem AS heat_system,
       h.HeatSupplier AS heat_supplier, h.ServiceOrg AS service_org, h.MunicipalNote AS municipal_note,
       h.YearBuilt AS year_built, h.Floors AS floors, h.FlatsCount AS flats, h.WallMaterial AS wall,
       h.MunicipalPercent AS municipal_percent, h.IsEmergency AS emergency, h.IsAuction AS auction, h.Note AS note,
       h.Lat AS lat, h.Lon AS lon,
       h.IsDemolished AS demolished, h.DemolitionDate AS demo_date, h.ActNumber AS act_number,
       h.RelocationProgram AS relocation_program, h.IsResettled AS resettled, h.Quarter AS quarter,
       h.ResidentsCount AS residents, h.Area AS area,
       h.HouseType AS house_type_text, h.HeatingType AS heating_text, h.StatusText AS status_text,
       h.IsNoUk AS no_uk, h.IsUndefined AS undefined, h.IsEgrnQuery AS egrn_query,
       h.CoordsApprox AS coords_approx, h.UKName AS uk_name,
       0 AS no_uk_legacy
FROM dbo.House h
LEFT JOIN dbo.UK uk ON uk.UKID = h.UKID
LEFT JOIN dbo.HouseType ht ON ht.HouseTypeID = h.HouseTypeID
LEFT JOIN dbo.HeatingType he ON he.HeatingTypeID = h.HeatingTypeID
"""

def mkd_base_sql():
    """Вернуть SQL с LEFT JOIN HouseNoUK если таблица существует, иначе без него.
       После миграции 11 колонка IsNoUk в самой таблице House — основной источник
       признака «без УК». HouseNoUK (если есть) — дополнительная проверка."""
    if mkd_has('HouseNoUK'):
        # объединяем: IsNoUk из House ИЛИ наличие записи в HouseNoUK
        return BASE_MKD_SQL_CORE.replace(
            'h.IsNoUk AS no_uk,',
            'CASE WHEN ISNULL(h.IsNoUk, 0) = 1 OR n.HouseID IS NOT NULL THEN 1 ELSE 0 END AS no_uk,'
        ) + 'LEFT JOIN dbo.HouseNoUK n ON n.HouseID = h.HouseID\n'
    return BASE_MKD_SQL_CORE

# Совместимость: оставим старое имя как ссылку (используется в mkd_all и mkd_house через mkd_base_sql())
BASE_MKD_SQL = BASE_MKD_SQL_CORE  # на случай прямого использования — но лучше через mkd_base_sql()

@app.route('/api/mkd/ping')
def mkd_ping():
    try:
        n = rows("SELECT COUNT(*) AS n FROM dbo.House", db='mkd')
        return jsonify({'ok': True, 'driver': DRIVER, 'houses': n[0]['n'] if n else 0})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 200

@app.route('/api/mkd/info')
def mkd_info():
    mkd_db = CFG.get('database_mkd') or ''
    if not mkd_db:
        return jsonify({'available': False, 'message': 'В config.json не указана database_mkd.', 'tables': []})
    try:
        tbls = rows("SELECT TABLE_NAME AS name FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE='BASE TABLE' ORDER BY TABLE_NAME", db='mkd')
        result = []
        for t in tbls:
            tn = t['name']
            try:
                cnt = rows('SELECT COUNT(*) AS n FROM [' + tn + ']', db='mkd')
                n = cnt[0]['n'] if cnt else 0
            except Exception:
                n = -1
            try:
                cols = rows("SELECT COLUMN_NAME AS name, DATA_TYPE AS dtype FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME=? ORDER BY ORDINAL_POSITION", (tn,), db='mkd')
            except Exception:
                cols = []
            result.append({'name': tn, 'rows': n, 'columns': cols})
        # проверим, какие из ОЖИДАЕМЫХ таблиц отсутствуют (нужны для карточки МКД)
        existing = set(t['name'].lower() for t in tbls)
        expected = ['House', 'UK', 'HouseType', 'HeatingType', 'UKContact',
                    'HouseRegistryInfo', 'HouseEmergency', 'HouseNoUK', 'ChangeLog']
        missing = [t for t in expected if t.lower() not in existing]
        msg = 'База МКД подключена.'
        if missing:
            msg += ' ВНИМАНИЕ: отсутствуют ожидаемые таблицы: ' + ', '.join(missing) + '. Карточка МКД покажет только те разделы, таблицы для которых есть.'
        return jsonify({'available': True, 'database': mkd_db, 'tables': result, 'missing_tables': missing, 'message': msg})
    except Exception as e:
        return jsonify({'available': False, 'message': 'Не удалось подключиться к базе МКД (' + mkd_db + '): ' + str(e), 'tables': []}), 200

@app.route('/api/mkd/all')
def mkd_all():
    if _cache["data"] is None or time.time() - _cache["t"] > 30:
        try:
            _cache["data"] = rows(mkd_base_sql() + " ORDER BY h.Street, h.HouseNo", db='mkd')
            _cache["t"] = time.time()
        except Exception as e:
            return jsonify({'error': 'Не удалось прочитать список домов: ' + str(e)}), 500
    out = []
    for r in _cache["data"]:
        out.append({k: fmt(v) for k, v in r.items()})
    return jsonify(out)

@app.route('/api/mkd/uks')
def mkd_uks():
    try:
        return jsonify(rows("SELECT UKID AS id, Name AS name FROM dbo.UK ORDER BY Name", db='mkd'))
    except Exception as e:
        return jsonify([])  # если таблицы нет — пустой список

@app.route('/api/mkd/lookups')
def mkd_lookups():
    def safe_list(sql):
        try:
            return [r['n'] for r in rows(sql, db='mkd')]
        except Exception:
            return []
    return jsonify({
        'types': safe_list("SELECT Name AS n FROM dbo.HouseType ORDER BY Name"),
        'heating': safe_list("SELECT Name AS n FROM dbo.HeatingType ORDER BY Name")
    })

# Кэш существующих таблиц в AvtodorDB (обновляется раз в 60 секунд)
_tables_cache = {'at': 0, 'set': set()}
def mkd_existing_tables():
    """Вернуть множество существующих таблиц в AvtodorDB. Кэшируется."""
    import time as _t
    now = _t.time()
    if _tables_cache['set'] and now - _tables_cache['at'] < 60:
        return _tables_cache['set']
    try:
        r = rows("SELECT TABLE_NAME AS name FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE='BASE TABLE'", db='mkd')
        _tables_cache['set'] = set(x['name'].lower() for x in r)
        _tables_cache['at'] = now
    except Exception:
        _tables_cache['set'] = set()
    return _tables_cache['set']

def mkd_has(table_name):
    """Проверить, существует ли таблица в AvtodorDB (без учёта регистра)."""
    return table_name.lower() in mkd_existing_tables()

def safe_mkd_rows(sql, params=()):
    """Выполнить запрос к AvtodorDB; если таблицы нет — вернуть пустой список."""
    try:
        return rows(sql, params, db='mkd')
    except Exception as e:
        # логируем, но не падаем
        print('MKD query failed (will be ignored):', str(e)[:200])
        return []

@app.route('/api/mkd/house/<int:hid>')
def mkd_house(hid):
    # Сначала проверим, есть ли дом
    try:
        rs = rows(mkd_base_sql() + " WHERE h.HouseID = ?", (hid,), db='mkd')
    except Exception as e:
        return jsonify({'error': 'Не удалось прочитать дом: ' + str(e)}), 500
    if not rs: return jsonify({'error': 'not found'}), 404
    d = rs[0]
    d = {k: fmt(v) for k, v in d.items()}
    # Каждый блок — с проверкой существования таблицы
    if mkd_has('HouseRegistryInfo'):
        rg = safe_mkd_rows("SELECT LastCapRepair AS cap_repair, PremisesCount AS premises, TechState AS tech_state, ContractStart AS contract_start, ContractEnd AS contract_end, Faults AS faults, RegistryNote AS reg_note, SourceFile AS source FROM dbo.HouseRegistryInfo WHERE HouseID = ?", (hid,))
        d["registry_info"] = ({k: fmt(v) for k, v in rg[0].items()} if rg else None)
    else:
        d["registry_info"] = None
        d["registry_info_missing"] = True  # интерфейс покажет «таблица не создана»
    if mkd_has('HouseEmergency'):
        em = safe_mkd_rows("SELECT Quarter AS quarter, Residents AS residents, TotalAreaM2 AS area, ActText AS act FROM dbo.HouseEmergency WHERE HouseID = ?", (hid,))
        d["emergency_info"] = ({k: fmt(v) for k, v in em[0].items()} if em else None)
    else:
        d["emergency_info"] = None
        d["emergency_info_missing"] = True
    if mkd_has('HouseNoUK'):
        nu = safe_mkd_rows("SELECT OrderText AS order_text, HouseKind AS kind, EgrnType AS egrn, Status AS status, MunicipalFlats AS municipal, RefusedBy AS refused_by, GisType AS gis_type, RoaText AS roa, ProgramText AS program, RelocationDeadline AS deadline FROM dbo.HouseNoUK WHERE HouseID = ?", (hid,))
        d["no_uk_info"] = ({k: fmt(v) for k, v in nu[0].items()} if nu else None)
    else:
        d["no_uk_info"] = None
        d["no_uk_info_missing"] = True
    if mkd_has('UKContact'):
        ct = safe_mkd_rows("SELECT c.FullName AS name, c.Position AS position, c.Phone AS phone FROM dbo.UKContact c JOIN dbo.House h ON h.UKID = c.UKID WHERE h.HouseID = ? ORDER BY c.ContactID", (hid,))
        d["contacts"] = ([{k: fmt(v) for k, v in c.items()} for c in ct] if ct else [])
    else:
        d["contacts"] = []
        d["contacts_missing"] = True
    return jsonify(d)

def apply_house_body(cur, hid, b):
    for key, (table, spec) in SECTION_TABLES.items():
        if key in b:
            save_section(cur, hid, table, conv(b[key] or {}, spec))

@app.route('/api/mkd/house', methods=['POST'])
@need('editor')
def mkd_house_create():
    b = request.get_json(force=True) or {}
    h = conv(b.get("house") or {}, HOUSE)
    if not h.get("Street") or not h.get("HouseNo"):
        return jsonify({'error': 'Нужно заполнить улицу и номер дома.'}), 400
    def work(cur):
        h["HouseTypeID"] = lookup_id(cur, "HouseType", "HouseTypeID", (b["house"] or {}).get("house_type"))
        h["HeatingTypeID"] = lookup_id(cur, "HeatingType", "HeatingTypeID", (b["house"] or {}).get("heating"))
        cols = list(h)
        cur.execute("INSERT INTO dbo.House (" + ", ".join(cols) + ") OUTPUT INSERTED.HouseID VALUES (" + ", ".join("?" * len(cols)) + ")", *h.values())
        hid = cur.fetchone()[0]
        write_mkd_log(cur, "добавление", "House", hid, {k: v for k, v in h.items() if v is not None})
        apply_house_body(cur, hid, b)
        return hid
    hid = run_tx_mkd(work)
    drop_cache()
    return jsonify({'id': hid})

@app.route('/api/mkd/house/<int:hid>', methods=['PUT'])
@need('editor')
def mkd_house_update(hid):
    b = request.get_json(force=True) or {}
    hb = b.get("house") or {}
    h = conv(hb, HOUSE)
    if ("Street" in h and not h["Street"]) or ("HouseNo" in h and not h["HouseNo"]):
        return jsonify({'error': 'Улица и номер дома не могут быть пустыми.'}), 400
    def work(cur):
        cur.execute("SELECT HouseID FROM dbo.House WHERE HouseID = ?", hid)
        if not cur.fetchone(): raise ValueError("Такого дома нет в базе.")
        if "house_type" in hb: h["HouseTypeID"] = lookup_id(cur, "HouseType", "HouseTypeID", hb.get("house_type"))
        if "heating" in hb: h["HeatingTypeID"] = lookup_id(cur, "HeatingType", "HeatingTypeID", hb.get("heating"))
        if h:
            cols = list(h)
            cur.execute("SELECT " + ", ".join(cols) + " FROM dbo.House WHERE HouseID = ?", hid)
            old = row_dict(cur)
            diff = {c: [old[c], h[c]] for c in cols if norm(old[c]) != norm(h[c])}
            if diff:
                cur.execute("UPDATE dbo.House SET " + ", ".join(c + " = ?" for c in diff) + " WHERE HouseID = ?",
                            *[h[c] for c in diff], hid)
                write_mkd_log(cur, "изменение", "House", hid, diff)
        apply_house_body(cur, hid, b)
    try:
        run_tx_mkd(work)
    except Exception as e:
        return jsonify({'error': str(e)}), 400
    drop_cache()
    return jsonify({'ok': True})

@app.route('/api/mkd/house/<int:hid>', methods=['DELETE'])
@need('admin')
def mkd_house_delete(hid):
    def work(cur):
        cur.execute("SELECT * FROM dbo.House WHERE HouseID = ?", hid)
        old = row_dict(cur)
        if not old: raise ValueError("Такого дома уже нет.")
        snap = {k: v for k, v in old.items() if v is not None and k != "FullAddress"}
        # перед обращением к каждой связанной таблице проверяем, что она существует
        # (в базе пользователя части из них может не быть — это норма)
        for t in ("HouseRegistryInfo", "HouseEmergency", "HouseNoUK"):
            if not mkd_has(t):
                continue  # таблицы нет — пропускаем (и SELECT, и DELETE)
            cur.execute("SELECT * FROM dbo." + t + " WHERE HouseID = ?", hid)
            r = row_dict(cur)
            if r: snap[t] = {k: v for k, v in r.items() if v is not None}
            cur.execute("DELETE FROM dbo." + t + " WHERE HouseID = ?", hid)
        cur.execute("DELETE FROM dbo.House WHERE HouseID = ?", hid)
        write_mkd_log(cur, "удаление", "House", hid, snap)
    try:
        run_tx_mkd(work)
    except Exception as e:
        return jsonify({'error': str(e)}), 400
    drop_cache()
    return jsonify({'ok': True})

@app.route('/api/mkd/house/<int:hid>/toggle_map_visibility', methods=['POST'])
@need('editor')
def mkd_house_toggle_visibility(hid):
    """Скрыть дом с карты (или показать обратно). Дом остаётся в базе.
       Полезно для домов, которые не относятся к Автодорожному округу —
       их не нужно видеть на карте, но удалять из базы не хочется."""
    if not mkd_has('House'):
        return jsonify({'error': 'В базе AvtodorDB нет таблицы House.'}), 400
    # если колонки IsHiddenFromMap нет — добавим её на лету
    if not rows("SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'AvtodorDB.dbo.House') "
                "AND name = N'IsHiddenFromMap'", db='mkd'):
        try:
            run('ALTER TABLE AvtodorDB.dbo.House ADD IsHiddenFromMap BIT NOT NULL DEFAULT 0', db='mkd')
        except Exception as e:
            print('Не удалось добавить колонку IsHiddenFromMap:', e)
    try:
        cur_state = rows("SELECT ISNULL(IsHiddenFromMap, 0) AS v FROM AvtodorDB.dbo.House WHERE HouseID = ?", (hid,), db='mkd')
        if not cur_state:
            return jsonify({'error': 'Дом не найден.'}), 404
        new_v = 0 if cur_state[0]['v'] else 1
        run("UPDATE AvtodorDB.dbo.House SET IsHiddenFromMap = ? WHERE HouseID = ?", (new_v, hid), db='mkd')
        action = 'скрыт с карты' if new_v else 'показан на карте'
        drop_cache()
        return jsonify({'ok': True, 'hidden': bool(new_v), 'action': action})
    except Exception as e:
        return jsonify({'error': str(e)}), 400

@app.route('/api/mkd/house/<int:hid>/move', methods=['PUT'])
@need('editor')
def mkd_house_move(hid):
    """Переместить дом на карте в новые координаты.
       Принимает JSON: {"lat": 62.028, "lon": 129.731, "approx": false}
       Если approx=true — координаты приблизительные (центр улицы)."""
    if not mkd_has('House'):
        return jsonify({'error': 'В базе AvtodorDB нет таблицы House.'}), 400
    d = request.get_json() or {}
    if 'lat' not in d or 'lon' not in d:
        return jsonify({'error': 'Нужны lat и lon.'}), 400
    try:
        lat = float(d['lat'])
        lon = float(d['lon'])
    except (TypeError, ValueError):
        return jsonify({'error': 'lat/lon должны быть числами.'}), 400
    if not (-90 <= lat <= 90):
        return jsonify({'error': 'lat должна быть -90..90'}), 400
    if not (-180 <= lon <= 180):
        return jsonify({'error': 'lon должна быть -180..180'}), 400
    approx = 1 if d.get('approx') else 0
    # проверим, что дом существует
    existing = rows("SELECT HouseID, Street, HouseNo FROM AvtodorDB.dbo.House WHERE HouseID = ?", (hid,), db='mkd')
    if not existing:
        return jsonify({'error': 'Дом не найден.'}), 404
    # если колонки CoordsApprox нет — добавим
    if not rows("SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'AvtodorDB.dbo.House') "
                "AND name = N'CoordsApprox'", db='mkd'):
        try:
            run('ALTER TABLE AvtodorDB.dbo.House ADD CoordsApprox BIT NOT NULL DEFAULT 0', db='mkd')
        except Exception as e:
            print('Не удалось добавить колонку CoordsApprox:', e)
    run("UPDATE AvtodorDB.dbo.House SET Lat = ?, Lon = ?, CoordsApprox = ? WHERE HouseID = ?",
        (lat, lon, approx, hid), db='mkd')
    drop_cache()
    h = existing[0]
    label = ((h.get('Street') or '') + ' ' + (h.get('HouseNo') or '')).strip()
    return jsonify({'ok': True, 'lat': lat, 'lon': lon, 'approx': approx,
                    'message': 'Координаты дома ' + label + ' обновлены.'})

@app.route('/api/mkd/house/<int:hid>/coords', methods=['GET'])
@need('editor')
def mkd_house_coords(hid):
    """Получить текущие координаты дома (для отображения при перемещении)."""
    if not mkd_has('House'):
        return jsonify({'error': 'В базе AvtodorDB нет таблицы House.'}), 400
    r = rows("SELECT Lat, Lon, ISNULL(CoordsApprox, 0) AS approx FROM AvtodorDB.dbo.House WHERE HouseID = ?",
             (hid,), db='mkd')
    if not r:
        return jsonify({'error': 'Дом не найден.'}), 404
    return jsonify({'lat': float(r[0]['Lat']) if r[0].get('Lat') else None,
                    'lon': float(r[0]['Lon']) if r[0].get('Lon') else None,
                    'approx': bool(r[0]['approx'])})

# ============ Файлы МКД (множественная загрузка, любое расширение) ============
# Хранятся в AvtodorDB.dbo.HouseFile (создаётся при первом обращении)
# и физически — в uploads/mkd_<houseID>/. Физически та же папка UPLOAD,
# что и для НТО — чтобы было одно место для бэкапа.

def _ensure_mkd_files_table():
    """Создать таблицу HouseFile в AvtodorDB, если её нет. Идемпотентно."""
    if not mkd_has('House'):
        return False
    if not mkd_has('HouseFile'):
        try:
            run("""CREATE TABLE AvtodorDB.dbo.HouseFile (
                FileID INT IDENTITY(1,1) PRIMARY KEY,
                HouseID INT NOT NULL,
                FileName NVARCHAR(300) NOT NULL,
                StoredName NVARCHAR(300) NOT NULL,
                IsPhoto BIT NOT NULL DEFAULT 0,
                SizeBytes BIGINT NULL,
                UploadedBy NVARCHAR(100) NULL,
                UploadedAt DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
                IsDeleted BIT NOT NULL DEFAULT 0
            )""", db='mkd')
            # внешний ключ не ставим — HouseID может ссылаться на AvtodorDB.House,
            # но в случае если база одна и та же — это работает; если нет — мягкая ссылка.
        except Exception as e:
            print('Не удалось создать таблицу HouseFile:', e)
            return False
    return True

@app.route('/api/mkd/house/<int:hid>/files', methods=['GET'])
def mkd_files_list(hid):
    """Список файлов дома МКД."""
    if not _ensure_mkd_files_table():
        return jsonify([])
    try:
        r = rows("SELECT FileID AS id, FileName AS name, IsPhoto AS is_photo, "
                 "SizeBytes AS size, UploadedBy AS uploaded_by, UploadedAt AS uploaded_at "
                 "FROM AvtodorDB.dbo.HouseFile WHERE HouseID = ? AND IsDeleted = 0 "
                 "ORDER BY FileID", (hid,), db='mkd')
        return jsonify([{k: fmt(v) for k, v in row.items()} for row in r])
    except Exception as e:
        print('mkd files list error:', e)
        return jsonify([])

@app.route('/api/mkd/house/<int:hid>/files', methods=['POST'])
@need('editor')
def mkd_files_add(hid):
    """Загрузка одного или нескольких файлов к дому МКД."""
    if not mkd_has('House'):
        return jsonify({'error': 'В базе AvtodorDB нет таблицы House.'}), 400
    if not rows("SELECT HouseID FROM AvtodorDB.dbo.House WHERE HouseID = ?", (hid,), db='mkd'):
        return jsonify({'error': 'Дом не найден.'}), 404
    if not _ensure_mkd_files_table():
        return jsonify({'error': 'Не удалось создать таблицу HouseFile.'}), 500
    files = request.files.getlist('file')
    if not files or all(not f.filename for f in files):
        return jsonify({'error': 'Файлы не выбраны.'}), 400
    folder = os.path.join(UPLOAD, 'mkd_%d' % hid)
    if not os.path.isdir(folder): os.makedirs(folder)
    added_ids = []
    skipped = []
    for f in files:
        if not f or not f.filename:
            continue
        ext = f.filename.rsplit('.', 1)[-1].lower() if '.' in f.filename else ''
        if not ext or ext in BAD_EXT:
            skipped.append({'name': f.filename, 'reason': 'недопустимый тип'})
            continue
        stored = uuid.uuid4().hex + '.' + ext
        try:
            f.save(os.path.join(folder, stored))
            photo = 1 if ext in ('jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic') else 0
            size = os.path.getsize(os.path.join(folder, stored))
            # используем прямую вставку, т.к. insert() для NtoDB
            _name = f.filename[:300]
            _by = session.get('name')
            def _do_insert(cur, _hid=hid, _name=_name, _stored=stored, _photo=photo, _size=size, _by=_by):
                cur.execute("INSERT INTO dbo.HouseFile (HouseID, FileName, StoredName, IsPhoto, SizeBytes, UploadedBy) "
                            "OUTPUT INSERTED.FileID VALUES (?, ?, ?, ?, ?, ?)",
                            (_hid, _name, _stored, _photo, _size, _by))
                return cur.fetchone()[0]
            new_id = run_tx_mkd(_do_insert)
            added_ids.append(new_id)
        except Exception as e:
            skipped.append({'name': f.filename, 'reason': str(e)[:100]})
    return jsonify(added=len(added_ids), ids=added_ids, skipped=skipped)

@app.route('/api/mkd/house/<int:hid>/files/delete', methods=['POST'])
@need('editor')
def mkd_files_delete(hid):
    """Удаление нескольких файлов МКД сразу. JSON: {"ids": [1,2,3]}."""
    if not mkd_has('HouseFile'):
        return jsonify({'error': 'Таблицы HouseFile нет — удалять нечего.'}), 400
    d = request.get_json() or {}
    ids = d.get('ids') or []
    if not ids:
        return jsonify({'error': 'Список ids пуст.'}), 400
    deleted = []
    for fid in ids:
        try:
            fid = int(fid)
            r = rows("SELECT * FROM AvtodorDB.dbo.HouseFile WHERE FileID = ? AND HouseID = ? AND IsDeleted = 0",
                     (fid, hid), db='mkd')
            if not r:
                continue
            r = r[0]
            src = os.path.join(UPLOAD, 'mkd_%d' % r['HouseID'], r['StoredName'])
            if os.path.exists(src):
                shutil.move(src, os.path.join(TRASH, 'mkd_%d_%s' % (fid, r['StoredName'])))
            run("UPDATE AvtodorDB.dbo.HouseFile SET IsDeleted = 1 WHERE FileID = ?", (fid,), db='mkd')
            deleted.append(fid)
        except Exception as e:
            print('mkd file delete error fid=%s: %s' % (fid, e))
    return jsonify(ok=1, deleted=deleted, count=len(deleted))

@app.route('/api/mkd/file/<int:fid>')
def mkd_file_get(fid):
    """Отдать файл МКД по id (картинку — всем, документ — после входа)."""
    if not mkd_has('HouseFile'):
        abort(404, 'Таблицы HouseFile нет.')
    r = rows("SELECT * FROM AvtodorDB.dbo.HouseFile WHERE FileID = ? AND IsDeleted = 0", (fid,), db='mkd')
    if not r:
        abort(404)
    r = r[0]
    if not r['IsPhoto']:
        if role() not in ('admin', 'editor'):
            return jsonify(error='Нужно войти.'), 401
    return send_from_directory(os.path.join(UPLOAD, 'mkd_%d' % r['HouseID']), r['StoredName'],
                               as_attachment=not r['IsPhoto'], download_name=r['FileName'])

@app.route('/api/mkd/uk/<int:uid>/contacts')
def mkd_uk_contacts(uid):
    return jsonify(rows("SELECT ContactID AS id, FullName AS name, Position AS position, Phone AS phone FROM dbo.UKContact WHERE UKID = ? ORDER BY ContactID", (uid,), db='mkd'))

@app.route('/api/mkd/uk', methods=['POST'])
@need('editor')
def mkd_uk_create():
    name = s_((request.get_json(force=True) or {}).get("name"))
    if not name: return jsonify({'error': 'Впиши название УК.'}), 400
    def work(cur):
        cur.execute("INSERT INTO dbo.UK (Name) OUTPUT INSERTED.UKID VALUES (?)", name)
        uid = cur.fetchone()[0]
        write_mkd_log(cur, "добавление", "UK", uid, {"Name": name})
        return uid
    uid = run_tx_mkd(work); drop_cache()
    return jsonify({'id': uid})

@app.route('/api/mkd/uk/<int:uid>', methods=['PUT'])
@need('editor')
def mkd_uk_update(uid):
    name = s_((request.get_json(force=True) or {}).get("name"))
    if not name: return jsonify({'error': 'Название УК не может быть пустым.'}), 400
    def work(cur):
        cur.execute("SELECT Name FROM dbo.UK WHERE UKID = ?", uid)
        r = cur.fetchone()
        if not r: raise ValueError("Такой УК нет.")
        if r[0] != name:
            cur.execute("UPDATE dbo.UK SET Name = ? WHERE UKID = ?", name, uid)
            write_mkd_log(cur, "изменение", "UK", uid, {"Name": [r[0], name]})
    try: run_tx_mkd(work)
    except Exception as e: return jsonify({'error': str(e)}), 400
    drop_cache()
    return jsonify({'ok': True})

@app.route('/api/mkd/uk/<int:uid>', methods=['DELETE'])
@need('admin')
def mkd_uk_delete(uid):
    def work(cur):
        cur.execute("SELECT COUNT(*) FROM dbo.House WHERE UKID = ?", uid)
        n = cur.fetchone()[0]
        if n: raise ValueError("Нельзя удалить: за этой УК закреплено домов: " + str(n) + ". Сначала смени УК у этих домов.")
        cur.execute("SELECT Name FROM dbo.UK WHERE UKID = ?", uid)
        r = cur.fetchone()
        if not r: raise ValueError("Такой УК уже нет.")
        cur.execute("DELETE FROM dbo.UKContact WHERE UKID = ?", uid)
        cur.execute("DELETE FROM dbo.UK WHERE UKID = ?", uid)
        write_mkd_log(cur, "удаление", "UK", uid, {"Name": r[0]})
    try: run_tx_mkd(work)
    except Exception as e: return jsonify({'error': str(e)}), 400
    drop_cache()
    return jsonify({'ok': True})

@app.route('/api/mkd/uk/<int:uid>/contacts', methods=['POST'])
@need('editor')
def mkd_contact_create(uid):
    b = request.get_json(force=True) or {}
    vals = (s_(b.get("name")), s_(b.get("position")), s_(b.get("phone")))
    if not any(vals): return jsonify({'error': 'Заполни хотя бы одно поле контакта.'}), 400
    def work(cur):
        cur.execute("INSERT INTO dbo.UKContact (UKID, FullName, Position, Phone) OUTPUT INSERTED.ContactID VALUES (?, ?, ?, ?)", uid, *vals)
        cid = cur.fetchone()[0]
        write_mkd_log(cur, "добавление", "UKContact", cid, {"UKID": uid, "FullName": vals[0], "Position": vals[1], "Phone": vals[2]})
        return cid
    try: cid = run_tx_mkd(work)
    except Exception as e: return jsonify({'error': str(e)}), 400
    return jsonify({'id': cid})

@app.route('/api/mkd/contact/<int:cid>', methods=['PUT'])
@need('editor')
def mkd_contact_update(cid):
    b = request.get_json(force=True) or {}
    vals = {"FullName": s_(b.get("name")), "Position": s_(b.get("position")), "Phone": s_(b.get("phone"))}
    def work(cur):
        cur.execute("SELECT FullName, Position, Phone FROM dbo.UKContact WHERE ContactID = ?", cid)
        old = row_dict(cur)
        if not old: raise ValueError("Такого контакта нет.")
        diff = {c: [old[c], v] for c, v in vals.items() if old[c] != v}
        if diff:
            cur.execute("UPDATE dbo.UKContact SET FullName = ?, Position = ?, Phone = ? WHERE ContactID = ?", *vals.values(), cid)
            write_mkd_log(cur, "изменение", "UKContact", cid, diff)
    try: run_tx_mkd(work)
    except Exception as e: return jsonify({'error': str(e)}), 400
    return jsonify({'ok': True})

@app.route('/api/mkd/contact/<int:cid>', methods=['DELETE'])
@need('editor')
def mkd_contact_delete(cid):
    def work(cur):
        cur.execute("SELECT FullName, Position, Phone FROM dbo.UKContact WHERE ContactID = ?", cid)
        old = row_dict(cur)
        if not old: raise ValueError("Такого контакта уже нет.")
        cur.execute("DELETE FROM dbo.UKContact WHERE ContactID = ?", cid)
        write_mkd_log(cur, "удаление", "UKContact", cid, old)
    try: run_tx_mkd(work)
    except Exception as e: return jsonify({'error': str(e)}), 400
    return jsonify({'ok': True})

@app.route('/api/mkd/log')
@need('admin')
def mkd_log():
    rs = rows("SELECT TOP (300) LogID AS id, At AS at, UserName AS user_name, Role AS role, Action AS action, TableName AS tbl, RecordID AS rid, Details AS details FROM dbo.ChangeLog ORDER BY LogID DESC", db='mkd')
    for r in rs:
        r['at'] = r['at'].strftime('%Y-%m-%d %H:%M:%S') if r['at'] else None
    return jsonify(rs)

@app.route('/api/mkd/table/<table>')
def mkd_table(table):
    if role() not in ('admin', 'editor'):
        return jsonify({'error': 'Нужно войти.'}), 403
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', table):
        return jsonify({'error': 'Недопустимое имя таблицы.'}), 400
    try:
        data = rows('SELECT TOP 100 * FROM [' + table + ']', db='mkd')
        out = []
        for r in data:
            out.append({k: fmt(v) for k, v in r.items()})
        return jsonify(out)
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# ============ Экспорт ============
def _style_xlsx_header(ws, ncols):
    """Жирный шапечник + закрепление первой строки + автоширина."""
    from openpyxl.styles import Font, PatternFill, Alignment
    head_font = Font(bold=True, color='FFFFFF')
    head_fill = PatternFill('solid', fgColor='1F3A5F')
    for c in ws[1]:
        c.font = head_font
        c.fill = head_fill
        c.alignment = Alignment(horizontal='center', vertical='center', wrap_text=True)
    ws.freeze_panes = 'A2'
    # автоширина
    for col in ws.columns:
        max_len = 0
        col_letter = col[0].column_letter
        for cell in col:
            try:
                v = str(cell.value) if cell.value is not None else ''
                if len(v) > max_len:
                    max_len = len(v)
            except Exception:
                pass
        # ограничим ширину
        ws.column_dimensions[col_letter].width = min(max(max_len + 2, 10), 50)

@app.route('/api/export.xlsx')
def export():
    """Выгрузка НТО в Excel с фильтрами.
       Параметры (все необязательные):
         scheme=all|in|out    — все / в схеме / вне схемы
         state=all|active|expiring|expired  — статус договора
         q=...               — поиск по адресу/владельцу/ИНН
         uk=...               — не используется для НТО (для совместимости)
       По умолчанию — все НТО."""
    import openpyxl
    from openpyxl.styles import Font
    scheme = (request.args.get('scheme') or 'all').lower()
    state = (request.args.get('state') or 'all').lower()
    q = (request.args.get('q') or '').strip().lower()
    # соберём SQL с фильтрами
    sql = 'SELECT * FROM nto_object WHERE is_deleted=0'
    params = []
    if scheme == 'in':
        sql += ' AND in_scheme=1'
    elif scheme == 'out':
        sql += ' AND in_scheme=0'
    if state in ('active', 'expiring', 'expired'):
        # фильтр по расчётному состоянию договора
        # active — term_end >= сегодня + 30 дней
        # expiring — term_end в ближайшие 30 дней
        # expired — term_end < сегодня
        today = datetime.date.today()
        if state == 'active':
            sql += " AND term_end IS NOT NULL AND term_end >= ?"
            params.append(today + datetime.timedelta(days=30))
        elif state == 'expiring':
            sql += " AND term_end IS NOT NULL AND term_end >= ? AND term_end < ?"
            params.append(today)
            params.append(today + datetime.timedelta(days=30))
        elif state == 'expired':
            sql += " AND term_end IS NOT NULL AND term_end < ?"
            params.append(today)
    if q:
        sql += " AND (LOWER(address) LIKE ? OR LOWER(owner_name) LIKE ? OR LOWER(inn) LIKE ? OR LOWER(specialization) LIKE ?)"
        like = '%' + q + '%'
        params.extend([like, like, like, like])
    sql += ' ORDER BY in_scheme DESC, scheme_num, id'
    all_rows = rows(sql, params)
    # если q не задан, но state задан и нет term_end — фильтруем в Python
    if state in ('active', 'expiring', 'expired') and not q:
        # дополнительно: строки без term_end (договор бессрочный) попадают в active
        # SQL выше это уже учёл, здесь ничего не делаем
        pass
    # ===== формат выгрузки: revision (бланк «Ревизия НТО») или full (по умолчанию) =====
    fmt = (request.args.get('format') or 'full').lower()
    if fmt == 'revision':
        return _export_nto_revision(all_rows, scheme, state, q)
    wb = openpyxl.Workbook(); ws = wb.active; ws.title = 'НТО'
    head = ['ID', 'В схеме', '№'] + FIELDS[2:] + ['Договор (расчёт)']
    ws.append(head)
    for r in all_rows:
        p = prep(r)
        ws.append([p['id'], 'да' if p['in_scheme'] else 'нет', p['scheme_num']] + [p.get(k) for k in FIELDS[2:]] + [p['state']])
    _style_xlsx_header(ws, len(head))
    # добавим второй лист — сводка по фильтру
    ws2 = wb.create_sheet('Сводка')
    ws2.append(['Параметр', 'Значение'])
    ws2.append(['Фильтр по схеме', {'all':'все','in':'в схеме','out':'вне схемы'}.get(scheme, scheme)])
    ws2.append(['Фильтр по договору', {'all':'все','active':'действующие','expiring':'истекают','expired':'истёкшие'}.get(state, state)])
    ws2.append(['Поиск', q or '(нет)'])
    ws2.append(['Всего объектов', len(all_rows)])
    ws2.append(['Дата выгрузки', datetime.datetime.now().strftime('%d.%m.%Y %H:%M')])
    _style_xlsx_header(ws2, 2)
    b = io.BytesIO(); wb.save(b); b.seek(0)
    name = 'НТО_%s.xlsx' % datetime.date.today().strftime('%d.%m.%Y')
    return send_file(b, as_attachment=True, download_name=name)


def _export_nto_revision(all_rows, scheme, state, q):
    """Выгрузка НТО в формате бланка «Ревизия НТО» (как образец пользователя).
       Колонки: № п/п, ТОУ, ФИО собственника, ФИО арендатора, Адрес размещения,
       Реквизиты договора (№/дата, срок, с кем заключён), специализация,
       Соответствие специализации со схемой, Наличие специализации, Наличие ККТ.
       Отличие «в схеме» от «вне схемы»:
         - в схеме = муниципальная земля, договор с управой → ТОУ = «Автодорожный округ»,
           реквизиты договора заполняются из базы, соответствие схемы = «да»
         - вне схемы = частники на своей земле → ТОУ = «(вне схемы) — частник»,
           договор обычно отсутствует, соответствие схемы = «нет» (объект не в схеме)"""
    import openpyxl
    from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
    from openpyxl.utils import get_column_letter
    wb = openpyxl.Workbook(); ws = wb.active; ws.title = 'Ревизия НТО'
    # ====== Заголовок таблицы — двухуровневый с объединением ячеек ======
    # Строка 1: № п/п | ТОУ | ФИО собственника | ФИО арендатора | Адрес размещения | Реквизиты договора (объединено F:H) | специализация | Соответствие... | Наличие... | ККТ
    # Строка 2:     |     |                   |                 |                   | №, дата договора | срок договора | с кем заключен  |           |                 |             |
    headers1 = ['№ п/п', 'ТОУ', 'ФИО собственника', 'ФИО арендатора', 'Адрес размещения',
                'Реквизиты договора', '', '',
                'специализация',
                'Соответствие специализации со схемой размещения НТО в случае наличия объекта в Схеме',
                'Наличие и соответствие заявленного вида специализации НТО',
                'Наличие и исправность ККТ']
    headers2 = ['', '', '', '', '',
                '№, дата договора', 'срок договора', 'с кем заключен договор',
                '', '', '', '']
    ws.append(headers1)
    ws.append(headers2)
    # объединения ячеек в шапке
    ws.merge_cells('A1:A2')   # № п/п
    ws.merge_cells('B1:B2')   # ТОУ
    ws.merge_cells('C1:C2')   # ФИО собственника
    ws.merge_cells('D1:D2')   # ФИО арендатора
    ws.merge_cells('E1:E2')   # Адрес размещения
    ws.merge_cells('F1:H1')   # Реквизиты договора
    ws.merge_cells('I1:I2')   # специализация
    ws.merge_cells('J1:J2')   # Соответствие специализации
    ws.merge_cells('K1:K2')   # Наличие специализации
    ws.merge_cells('L1:L2')   # ККТ
    # ====== Стиль шапки ======
    head_font = Font(bold=True, color='FFFFFF', size=10)
    head_fill = PatternFill('solid', fgColor='1F3A5F')
    head_align = Alignment(horizontal='center', vertical='center', wrap_text=True)
    thin = Side(style='thin', color='808080')
    border = Border(left=thin, right=thin, top=thin, bottom=thin)
    for r in (1, 2):
        for c in range(1, 13):
            cell = ws.cell(row=r, column=c)
            cell.font = head_font
            cell.fill = head_fill
            cell.alignment = head_align
            cell.border = border
    # высота строк шапки
    ws.row_dimensions[1].height = 50
    ws.row_dimensions[2].height = 22
    # ====== Данные ======
    n = 0
    in_scheme_count = 0
    out_scheme_count = 0
    for r in all_rows:
        p = prep(r)
        n += 1
        if p['in_scheme']:
            in_scheme_count += 1
            # в схеме = муниципальная земля, договор с управой
            tou = 'Администрация Автодорожного округа г. Якутска'
            # собственник — ГО «город Якутск» (муниципальная земля)
            owner = p.get('authority') or 'ГО «город Якутск»'
            # арендатор — фактический пользователь (ИП/ООО)
            tenant = p.get('owner_name') or ''
            # реквизиты договора
            contract_num = p.get('conditions') or ''
            # срок договора
            term = p.get('term_text') or ''
            if not term and p.get('term_start') and p.get('term_end'):
                term = str(p['term_start']) + ' – ' + str(p['term_end'])
            # с кем заключён договор — с арендатором (ИП/ООО)
            contract_with = p.get('owner_name') or ''
            # соответствие схеме — да (объект в схеме)
            scheme_match = 'да'
            # наличие специализации
            spec_present = 'да' if p.get('specialization') else 'нет'
            # ККТ
            kkt = p.get('chk_kkt') or ''
            if not kkt:
                # если нет явного признака — для объектов в схеме обычно «да»
                kkt = 'да'
        else:
            out_scheme_count += 1
            # вне схемы = частник на своей земле
            tou = '(вне схемы) — частный объект'
            # собственник — фактический владелец земли (частник)
            owner = p.get('owner_name') or '(не указан)'
            # арендатор — обычно тот же или пусто
            tenant = p.get('owner_name') or ''
            # реквизиты договора — обычно нет
            contract_num = p.get('conditions') or '(нет договора)'
            term = p.get('term_text') or '(нет)'
            contract_with = p.get('owner_name') or ''
            # соответствие схеме — нет (объект не входит в схему)
            scheme_match = 'нет (объект вне схемы)'
            # наличие специализации
            spec_present = 'да' if p.get('specialization') else 'нет данных'
            # ККТ — из базы или «не требуется» для мелких
            kkt = p.get('chk_kkt') or 'не требуется'
        # адрес — предпочтём address, иначе address_alt
        addr = p.get('address') or p.get('address_alt') or '(не указан)'
        ws.append([
            n,                          # № п/п
            tou,                        # ТОУ
            owner,                      # ФИО собственника
            tenant,                     # ФИО арендатора
            addr,                       # Адрес размещения
            contract_num,               # №, дата договора
            term,                       # срок договора
            contract_with,              # с кем заключен договор
            p.get('specialization') or '',  # специализация
            scheme_match,               # Соответствие специализации со схемой
            spec_present,               # Наличие специализации
            kkt                         # ККТ
        ])
    # ====== Стиль данных ======
    data_align = Alignment(horizontal='left', vertical='top', wrap_text=True)
    data_font = Font(size=10)
    # альтернирующая заливка для читаемости
    in_fill = PatternFill('solid', fgColor='EFF6FF')    # голубоватый — в схеме
    out_fill = PatternFill('solid', fgColor='FEF3C7')   # желтоватый — вне схемы
    last_row = ws.max_row
    for r_idx in range(3, last_row + 1):
        # определим, в схеме ли объект (по TOU в колонке B)
        tou_val = ws.cell(row=r_idx, column=2).value or ''
        is_in_scheme = 'Администрация' in tou_val
        for c_idx in range(1, 13):
            cell = ws.cell(row=r_idx, column=c_idx)
            cell.font = data_font
            cell.alignment = data_align
            cell.border = border
            if is_in_scheme:
                cell.fill = in_fill
            else:
                cell.fill = out_fill
    # закрепить шапку
    ws.freeze_panes = 'A3'
    # ширины колонок
    widths = [6, 28, 30, 30, 35, 30, 28, 30, 25, 28, 28, 22]
    for i, w in enumerate(widths, start=1):
        ws.column_dimensions[get_column_letter(i)].width = w
    # высота строк данных — авто (но не меньше 30)
    for r_idx in range(3, last_row + 1):
        ws.row_dimensions[r_idx].height = 45
    # ====== Второй лист — сводка ======
    ws2 = wb.create_sheet('Сводка')
    ws2.append(['Параметр', 'Значение'])
    ws2.append(['Формат', 'Ревизия НТО (официальный бланк)'])
    ws2.append(['Фильтр по схеме', {'all':'все','in':'в схеме','out':'вне схемы'}.get(scheme, scheme)])
    ws2.append(['Фильтр по договору', {'all':'все','active':'действующие','expiring':'истекают','expired':'истёкшие'}.get(state, state)])
    ws2.append(['Поиск', q or '(нет)'])
    ws2.append(['Всего объектов', len(all_rows)])
    ws2.append(['  в схеме (муниципальная земля, договор с управой)', in_scheme_count])
    ws2.append(['  вне схемы (частники на своей земле)', out_scheme_count])
    ws2.append(['Дата выгрузки', datetime.datetime.now().strftime('%d.%m.%Y %H:%M')])
    _style_xlsx_header(ws2, 2)
    # автоширина для сводки
    for col in ws2.columns:
        max_len = 0
        col_letter = col[0].column_letter
        for cell in col:
            v = str(cell.value) if cell.value is not None else ''
            if len(v) > max_len: max_len = len(v)
        ws2.column_dimensions[col_letter].width = min(max(max_len + 2, 15), 70)
    b = io.BytesIO(); wb.save(b); b.seek(0)
    name = 'Ревизия_НТО_%s.xlsx' % datetime.date.today().strftime('%d.%m.%Y')
    return send_file(b, as_attachment=True, download_name=name)

@app.route('/api/mkd/export.xlsx')
def export_mkd():
    """Выгрузка МКД в Excel с фильтрами.
       Параметры:
         uk=                 — id УК (или пусто = все УК)
         filter=all|emergency|resettled|auction|no_uk|undefined|demolished|active — фильтр по статусу
         q=                  — поиск по адресу/улице/УК
         include_hidden=0|1  — включать скрытые с карты (по умолчанию 0)
       По умолчанию — все видимые МКД."""
    import openpyxl
    if not mkd_has('House'):
        return jsonify({'error': 'В базе AvtodorDB нет таблицы House.'}), 400
    uk_filter = request.args.get('uk') or ''
    status_filter = (request.args.get('filter') or 'all').lower()
    q = (request.args.get('q') or '').strip().lower()
    include_hidden = request.args.get('include_hidden', '0') == '1'
    # соберём SQL — используем mkd_base_sql() для согласованности с API
    sql = mkd_base_sql() + " WHERE 1=1"
    params = []
    if not include_hidden:
        # если колонка IsHiddenFromMap существует — учтём
        if rows("SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID(N'AvtodorDB.dbo.House') AND name=N'IsHiddenFromMap'", db='mkd'):
            sql += " AND ISNULL(h.IsHiddenFromMap, 0) = 0"
    if uk_filter:
        sql += " AND h.UKID = ?"
        params.append(int(uk_filter))
    if status_filter == 'emergency':
        sql += " AND h.IsEmergency = 1"
    elif status_filter == 'resettled':
        if rows("SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID(N'AvtodorDB.dbo.House') AND name=N'IsResettled'", db='mkd'):
            sql += " AND h.IsResettled = 1"
    elif status_filter == 'auction':
        if rows("SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID(N'AvtodorDB.dbo.House') AND name=N'IsAuction'", db='mkd'):
            sql += " AND h.IsAuction = 1"
    elif status_filter == 'no_uk':
        sql += " AND (h.UKID IS NULL OR ISNULL(h.IsNoUk, 0) = 1)"
    elif status_filter == 'undefined':
        if rows("SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID(N'AvtodorDB.dbo.House') AND name=N'IsUndefined'", db='mkd'):
            sql += " AND h.IsUndefined = 1"
    elif status_filter == 'demolished':
        if rows("SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID(N'AvtodorDB.dbo.House') AND name=N'IsDemolished'", db='mkd'):
            sql += " AND h.IsDemolished = 1"
    elif status_filter == 'active':
        # действующие = не аварийные и не снесённые
        sql += " AND ISNULL(h.IsEmergency, 0) = 0"
        if rows("SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID(N'AvtodorDB.dbo.House') AND name=N'IsDemolished'", db='mkd'):
            sql += " AND ISNULL(h.IsDemolished, 0) = 0"
    if q:
        sql += " AND (LOWER(h.FullAddress) LIKE ? OR LOWER(h.Street) LIKE ? OR LOWER(h.HouseNo) LIKE ? OR LOWER(ISNULL(uk.Name,'')) LIKE ?)"
        like = '%' + q + '%'
        params.extend([like, like, like, like])
    sql += " ORDER BY h.Street, h.HouseNo"
    try:
        all_rows = rows(sql, params, db='mkd')
    except Exception as e:
        return jsonify({'error': 'Не удалось выполнить запрос: ' + str(e)}), 500
    wb = openpyxl.Workbook(); ws = wb.active; ws.title = 'МКД'
    head = ['ID', 'Адрес', 'Улица', 'Дом', 'УК', 'Тип дома', 'Отопление',
            'Год', 'Этажей', 'Квартир', 'Жильцов', 'Площадь, м²', 'Квартал',
            'Аварийный', 'Расселён', 'Снесён', 'Дата сноса', 'Распоряжение',
            'Программа переселения', 'Аукцион', 'Без УК', 'Неопределённый',
            'Запрос ЕГРН', 'Статус', 'Координаты (lat, lon)', 'Примечание']
    ws.append(head)
    for r in all_rows:
        r = {k: fmt(v) for k, v in r.items()}
        lat = r.get('lat'); lon = r.get('lon')
        coords = ''
        if lat and lon:
            coords = str(lat) + ', ' + str(lon)
        # дата сноса — обрежем до даты
        dd = r.get('demo_date')
        if dd and len(str(dd)) > 10:
            dd = str(dd)[:10]
        ws.append([
            r.get('id'), r.get('address'), r.get('street'), r.get('house_no'),
            r.get('uk') or r.get('uk_name') or '', r.get('house_type') or r.get('house_type_text') or '',
            r.get('heating') or r.get('heating_text') or '', r.get('year_built'),
            r.get('floors'), r.get('flats'), r.get('residents'), r.get('area'),
            r.get('quarter'),
            'да' if r.get('emergency') else 'нет',
            'да' if r.get('resettled') else 'нет',
            'да' if r.get('demolished') else 'нет',
            dd, r.get('act_number') or '', r.get('relocation_program') or '',
            'да' if r.get('auction') else 'нет',
            'да' if r.get('no_uk') else 'нет',
            'да' if r.get('undefined') else 'нет',
            'да' if r.get('egrn_query') else 'нет',
            r.get('status_text') or '', coords, r.get('note') or ''
        ])
    _style_xlsx_header(ws, len(head))
    # второй лист — сводка
    ws2 = wb.create_sheet('Сводка')
    # получим имя УК для отображения
    uk_name = '(все УК)'
    if uk_filter and mkd_has('UK'):
        u = rows("SELECT Name FROM dbo.UK WHERE UKID = ?", (int(uk_filter),), db='mkd')
        if u: uk_name = u[0]['Name']
    ws2.append(['Параметр', 'Значение'])
    ws2.append(['УК', uk_name])
    ws2.append(['Фильтр по статусу', {'all':'все','active':'действующие','emergency':'аварийные','resettled':'расселённые','auction':'на аукционе','no_uk':'без УК','undefined':'неопределённые','demolished':'снесённые'}.get(status_filter, status_filter)])
    ws2.append(['Поиск', q or '(нет)'])
    ws2.append(['Включая скрытые с карты', 'да' if include_hidden else 'нет'])
    ws2.append(['Всего домов', len(all_rows)])
    ws2.append(['Дата выгрузки', datetime.datetime.now().strftime('%d.%m.%Y %H:%M')])
    _style_xlsx_header(ws2, 2)
    b = io.BytesIO(); wb.save(b); b.seek(0)
    name = 'МКД_%s.xlsx' % datetime.date.today().strftime('%d.%m.%Y')
    return send_file(b, as_attachment=True, download_name=name)

# ============ Маршруты страниц ============
@app.route('/')
def index():
    return send_from_directory(os.path.join(BASE, 'static'), 'index.html')

# примечание: файлы статики (index.html, map_stub.jpg, okrug_boundary.geojson)
# раздаёт встроенная ститика Flask — см. static_folder выше. Отдельный маршрут не нужен.

# ============ Старт сервера ============
def run_server():
    port = CFG.get('port', 8080)
    print('=' * 60)
    print('Запуск сайта НТО+МКД на порту', port)
    print('База НТО:', CFG.get('database', '?'))
    print('База МКД:', CFG.get('database_mkd') or '(не настроена)')
    print('Пароль admin  :', CFG.get('admin_password', '(нет)'))
    print('Пароль editor :', CFG.get('editor_password', '(нет)'))
    print('Открой в браузере: http://localhost:' + str(port))
    print('=' * 60)
    try:
        from waitress import serve
        print('Сервер: waitress (production) на http://0.0.0.0:' + str(port))
        serve(app, host='0.0.0.0', port=port, threads=8)
    except ImportError:
        print('ВАЖНО: waitress не установлен. Использую Flask dev server.')
        print('Установите:  pip install waitress')
        app.run(host='0.0.0.0', port=port, threaded=True, use_reloader=False)

if __name__ == '__main__':
    run_server()
