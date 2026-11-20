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
app.config['MAX_CONTENT_LENGTH'] = 30 * 1024 * 1024
app.config.update(SESSION_COOKIE_SAMESITE="Lax", PERMANENT_SESSION_LIFETIME=datetime.timedelta(hours=12))

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
    if not rows('SELECT id FROM nto_object WHERE id=? AND is_deleted=0', (i,)): abort(404)
    f = request.files.get('file')
    if not f or not f.filename: return jsonify(error='Файл не выбран.'), 400
    ext = f.filename.rsplit('.', 1)[-1].lower() if '.' in f.filename else ''
    if ext in BAD_EXT or not ext: return jsonify(error='Этот тип файла загружать нельзя.'), 400
    stored = uuid.uuid4().hex + '.' + ext
    folder = os.path.join(UPLOAD, 'nto_%d' % i)
    if not os.path.isdir(folder): os.makedirs(folder)
    f.save(os.path.join(folder, stored))
    photo = 1 if ext in ('jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic') else 0
    fid = insert('nto_file', dict(object_id=i, file_name=f.filename[:300], stored_name=stored, caption=(request.form.get('caption') or '')[:300],
                 is_photo=photo, size_bytes=os.path.getsize(os.path.join(folder, stored)), uploaded_by=session.get('name')))
    log_nto('файл добавлен', i, None, {'file': f.filename})
    return jsonify(id=fid)

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
       Возвращает маркеры с lat/lon из нескольких источников:
       1) Кастомные точки из nto_map_point (где заполнены lat/lon), в т.ч. точки МКД (object_type='mkd')
       2) НТО-объекты, у которых заполнены lat и lon (кроме тех, что уже покрыты кастомной точкой)
       Для точек МКД подтягиваются данные дома (УК, этажность) из AvtodorDB.House.
       Карта зеркалит базы SQL Server: точки, привязанные к удалённым НТО, не отдаются,
       а точки МКД, для которых дом отсутствует в AvtodorDB.House, скрываются.
    """
    kind = (request.args.get('kind') or 'nto').strip().lower()
    if kind not in ('nto', 'mkd', 'all'):
        kind = 'nto'
    out = []
    covered_object_ids = set()
    # 1) Кастомные точки (в т.ч. МКД)
    try:
        where = 'WHERE lat IS NOT NULL AND lon IS NOT NULL'
        if kind == 'nto':
            # карта зеркалит базу: точки МКД не показываем, а точки, привязанные
            # к удалённым/несуществующим НТО, скрываем (НТО мог быть удалён позже)
            where += (" AND ISNULL(object_type, 'nto') <> 'mkd'"
                      " AND (object_id IS NULL OR EXISTS (SELECT 1 FROM nto_object o"
                      " WHERE o.id = nto_map_point.object_id AND o.is_deleted = 0))")
        elif kind == 'mkd':
            where += " AND object_type = 'mkd'"
        pts = rows('SELECT id, object_id, object_type, lat, lon, label, color, is_test, description, updated_at '
                   'FROM nto_map_point ' + where + ' ORDER BY id')
        for r in pts:
            out.append({
                'source': 'custom' if (r.get('object_type') or 'nto') != 'mkd' else 'mkd',
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
            if r.get('object_id') and (r.get('object_type') or 'nto') != 'mkd':
                covered_object_ids.add(r['object_id'])
    except Exception as e:
        print('map_markers custom error:', e)
    # 1а) Обогащение точек МКД данными домов из AvtodorDB (УК, адрес, этажность...)
    mkd_markers = [m for m in out if m['source'] == 'mkd' and m.get('object_id')]
    if mkd_markers:
        try:
            ids = sorted({str(m['object_id']) for m in mkd_markers})
            id_list = ','.join(ids)
            houses = rows(
                'SELECT h.HouseID AS hid, h.Street, h.HouseNo, h.FullAddress, h.Floors, h.FlatsCount, '
                'h.YearBuilt, h.IsEmergency, uk.Name AS uk_name '
                'FROM dbo.House h LEFT JOIN dbo.UK uk ON uk.UKID = h.UKID '
                'WHERE h.HouseID IN (' + id_list + ')', db='mkd')
            by_id = {h['hid']: h for h in houses}
            orphan_pts = set()   # точки МКД, для которых дома нет в базе AvtodorDB
            for m in mkd_markers:
                h = by_id.get(m['object_id'])
                if not h:
                    orphan_pts.add(id(m))
                    continue
                if h.get('FullAddress'):
                    m['label'] = h['FullAddress']
                desc = []
                if h.get('uk_name'):
                    desc.append('УК: ' + str(h['uk_name']))
                if h.get('Floors'):
                    desc.append('этажей: ' + str(h['Floors']))
                if h.get('FlatsCount'):
                    desc.append('квартир: ' + str(h['FlatsCount']))
                if h.get('YearBuilt'):
                    desc.append('год: ' + str(h['YearBuilt']))
                if h.get('IsEmergency'):
                    desc.append('АВАРИЙНЫЙ')
                if desc:
                    m['description'] = ('\n'.join(desc) + ('\n' + m['description'] if m.get('description') else '')).strip()
                m['emergency'] = 1 if h.get('IsEmergency') else 0
            # карта зеркалит базу МКД: точки, для которых дома нет в AvtodorDB,
            # из ответа убираем (показывать нечего — дома в базе нет)
            if orphan_pts:
                out = [m for m in out if id(m) not in orphan_pts]
                print('map_markers: скрыто точек МКД без дома в AvtodorDB:', len(orphan_pts))
        except Exception as e:
            print('map_markers mkd enrich error (AvtodorDB недоступна?):', e)
    # 2) НТО-объекты с координатами (пропускаем те, что уже показаны кастомной точкой)
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
            if k == 'object_id': v = int(v) if v else None
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
       0 AS no_uk
FROM dbo.House h
LEFT JOIN dbo.UK uk ON uk.UKID = h.UKID
LEFT JOIN dbo.HouseType ht ON ht.HouseTypeID = h.HouseTypeID
LEFT JOIN dbo.HeatingType he ON he.HeatingTypeID = h.HeatingTypeID
"""

def mkd_base_sql():
    """Вернуть SQL с LEFT JOIN HouseNoUK если таблица существует, иначе без него."""
    if mkd_has('HouseNoUK'):
        return BASE_MKD_SQL_CORE.replace('0 AS no_uk', 'CASE WHEN n.HouseID IS NULL THEN 0 ELSE 1 END AS no_uk') + \
               'LEFT JOIN dbo.HouseNoUK n ON n.HouseID = h.HouseID\n'
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
        for t in ("HouseRegistryInfo", "HouseEmergency", "HouseNoUK"):
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
@app.route('/api/export.xlsx')
def export():
    import openpyxl
    from openpyxl.styles import Font
    wb = openpyxl.Workbook(); ws = wb.active; ws.title = 'НТО'
    head = ['ID', 'В схеме', '№'] + FIELDS[2:] + ['Договор (расчёт)']
    ws.append(head)
    for c in ws[1]: c.font = Font(bold=True)
    for r in rows('SELECT * FROM nto_object WHERE is_deleted=0 ORDER BY in_scheme DESC, id'):
        p = prep(r); ws.append([p['id'], 'да' if p['in_scheme'] else 'нет', p['scheme_num']] + [p.get(k) for k in FIELDS[2:]] + [p['state']])
    b = io.BytesIO(); wb.save(b); b.seek(0)
    return send_file(b, as_attachment=True, download_name='НТО_%s.xlsx' % datetime.date.today().strftime('%d.%m.%Y'))

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
