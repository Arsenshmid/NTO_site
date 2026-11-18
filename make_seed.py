# -*- coding: utf-8 -*-
"""
Сборка data/seed.json из исходников НТО (ФИКС версия):
  В схеме (49 объектов) — из «здесь ИНН по НТО.xlsx» (пронумерованные строки 1..49
    с ИНН/ОГРНИП).
  Вне схемы (43 объекта) — из «Лист Microsoft Excel.xlsx» (фактически это
    «НТО вне схемы по автодорожному.xlsx» — колонки ревизии: специализация,
    договор, идентификация собственников, проверка ККТ, соответствие вида,
    сличение, купавы, телефон, комментарий, адрес, соседний адрес).

Использование:
  python make_seed.py "ПУТЬ_К_ЗДЕСЬ_ИНН_ПО_НТО.xlsx" "ПУТЬ_К_ЛИСТ_MICROSOFT_EXCEL.xlsx"
Если аргументов нет — берёт файлы из соседней папки (как в песочнице).

ВНИМАНИЕ: Word-файл «Схема последняя версия — копия.docx» СОДЕРЖИТ таблицу
Автодорожного округа, но с ДРУГИМ списком адресов (включает мкр. Марха и с. Табага),
поэтому основным источником схемы является «здесь ИНН по НТО.xlsx» (ровно 49 объектов).
Word-файл остаётся как официальный документ-постановление на будущее.
"""
import os, sys, re, json
import openpyxl

# пути по умолчанию (для пересборки в песочнице; на Windows укажите свои)
DEFAULT_INN = "/home/z/my-project/work/nto/здесь ИНН по НТО.xlsx"
DEFAULT_OUT = "/home/z/my-project/work/nto/Лист Microsoft Excel.xlsx"

INN_PATH = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_INN
OUT_PATH = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_OUT
OUT_JSON = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "seed.json")

FIELDS = [
    "in_scheme","scheme_num","address","address_alt","map_url","lat","lon","area","authority","owner_name","inn","ogrn",
    "fns_status","fns_date","obj_kind","trade_type","specialization","trade_area","term_text","term_start","term_end",
    "conditions","notes","contract_state","chk_contract","chk_kkt","chk_match","chk_compare","chk_kupavy","phone","comment","src"
]

def norm(s):
    if s is None: return None
    s = str(s).strip()
    if not s: return None
    s = s.replace('\xa0', ' ').replace('\u00a0', ' ')
    s = re.sub(r'\s+', ' ', s)
    return s

def to_int_str(v):
    if v is None: return None
    if isinstance(v, float) and v.is_integer(): v = int(v)
    return str(v).strip() or None

def clean_inn(v):
    """ИНН/ОГРН: оставить только цифры, отбросить пояснения в скобках."""
    if v is None: return None
    s = str(v).strip()
    if not s: return None
    # если внутри есть пояснение в скобках — берём то, что до скобки
    s = s.split('(', 1)[0].split('[', 1)[0].strip()
    # оставляем только цифры
    s = re.sub(r'\D', '', s)
    return s or None

def parse_dates(term):
    if not term: return (None, None)
    m = re.search(r'(\d{2})\.(\d{2})\.(\d{4})\s*[–\-—]\s*(\d{2})\.(\d{2})\.(\d{4})', term)
    if m:
        d1,m1,y1,d2,m2,y2 = m.groups()
        return (f"{y1}-{m1}-{d1}", f"{y2}-{m2}-{d2}")
    m = re.search(r'(\d{2})\.(\d{2})\.(\d{4})', term)
    if m:
        d1,m1,y1 = m.groups()
        return (f"{y1}-{m1}-{d1}", None)
    return (None, None)

# ===== A) в схеме: из «здесь ИНН по НТО.xlsx», строки 1..49 =====
print("Чтение «здесь ИНН по НТО.xlsx»...")
wb = openpyxl.load_workbook(INN_PATH, data_only=True)
ws = wb["Лист1"]
in_scheme = []
last_num = 0
for ri in range(4, ws.max_row + 1):
    num_raw = ws.cell(ri, 1).value
    num = to_int_str(num_raw)
    if not num or not re.fullmatch(r'\d+', num):
        continue
    # если нумерация началась заново — это другой округ, выходим
    if int(num) < last_num and last_num > 0:
        break
    last_num = int(num)

    o = {
        "in_scheme": 1,
        "scheme_num": num,
        "address": norm(ws.cell(ri, 2).value),
        "address_alt": None,
        "map_url": None,
        "lat": None, "lon": None,
        "area": to_int_str(ws.cell(ri, 3).value),
        "authority": norm(ws.cell(ri, 4).value),
        "owner_name": norm(ws.cell(ri, 5).value),
        "inn": clean_inn(ws.cell(ri, 13).value),
        "ogrn": clean_inn(ws.cell(ri, 14).value),
        "fns_status": None, "fns_date": None,
        "obj_kind": norm(ws.cell(ri, 6).value),
        "trade_type": norm(ws.cell(ri, 7).value),
        "specialization": norm(ws.cell(ri, 8).value),
        "trade_area": to_int_str(ws.cell(ri, 9).value),
        "term_text": norm(ws.cell(ri, 10).value),
        "conditions": norm(ws.cell(ri, 11).value),
        "notes": norm(ws.cell(ri, 12).value),
        "contract_state": None,
        "chk_contract": None, "chk_kkt": None, "chk_match": None, "chk_compare": None, "chk_kupavy": None,
        "phone": None,
        "comment": None,
        "src": "здесь ИНН по НТО.xlsx, строка " + num,
    }
    ts, te = parse_dates(o["term_text"])
    o["term_start"] = ts
    o["term_end"] = te
    in_scheme.append(o)
wb.close()
print(f"  в схеме: {len(in_scheme)} объектов (№ 1..{last_num})")

# ===== B) вне схемы: из «Лист Microsoft Excel.xlsx», 43 строки =====
print("Чтение «Лист Microsoft Excel.xlsx» (вне схемы, ревизия)...")
wb = openpyxl.load_workbook(OUT_PATH, data_only=True)
ws = wb.active
out_scheme = []
for ri in range(2, ws.max_row + 1):
    spec = norm(ws.cell(ri, 1).value)
    dogovor = norm(ws.cell(ri, 2).value)
    fio = norm(ws.cell(ri, 3).value)
    kkt = norm(ws.cell(ri, 4).value)
    match = norm(ws.cell(ri, 5).value)
    slichen = norm(ws.cell(ri, 6).value)
    kupavy = norm(ws.cell(ri, 7).value)
    phone = norm(ws.cell(ri, 8).value)
    comment = norm(ws.cell(ri, 9).value)
    addr = norm(ws.cell(ri, 10).value)
    alt_addr = norm(ws.cell(ri, 11).value)
    if not any([spec, dogovor, fio, kkt, match, slichen, kupavy, phone, comment, addr, alt_addr]):
        continue
    map_url = None
    if addr and (addr.startswith("http://") or addr.startswith("https://")):
        map_url = addr
        addr = None
    term_text = None; ts = None; te = None
    if dogovor:
        ts, te = parse_dates(dogovor)
        if ts or te:
            term_text = dogovor
    o = {
        "in_scheme": 0,
        "scheme_num": None,
        "address": addr,
        "address_alt": alt_addr,
        "map_url": map_url,
        "lat": None, "lon": None,
        "area": None,
        "authority": None,
        "owner_name": fio,
        "inn": None, "ogrn": None,
        "fns_status": None, "fns_date": None,
        "obj_kind": None,
        "trade_type": None,
        "specialization": spec,
        "trade_area": None,
        "term_text": term_text,
        "term_start": ts, "term_end": te,
        "conditions": dogovor,
        "notes": None,
        "contract_state": None,
        "chk_contract": dogovor,
        "chk_kkt": kkt,
        "chk_match": match,
        "chk_compare": slichen,
        "chk_kupavy": kupavy,
        "phone": phone,
        "comment": comment,
        "src": "Лист Microsoft Excel.xlsx, строка " + str(ri),
    }
    out_scheme.append(o)
wb.close()
print(f"  вне схемы: {len(out_scheme)} объектов")

# ===== Сборка и сохранение =====
final = in_scheme + out_scheme
for o in final:
    for k in FIELDS:
        if k not in o: o[k] = None
        if o[k] == "": o[k] = None

os.makedirs(os.path.dirname(OUT_JSON), exist_ok=True)
with open(OUT_JSON, "w", encoding="utf-8") as f:
    json.dump(final, f, ensure_ascii=False, indent=1)

print()
print(f"Сохранено: {OUT_JSON}")
print(f"Всего: {len(final)} объектов (в схеме: {len(in_scheme)}, вне схемы: {len(out_scheme)})")
