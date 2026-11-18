# Разовая загрузка data/seed.json в базу. Если в таблице уже есть записи — останавливается.
import json, sys
from app import rows, run, insert
if rows("SELECT COUNT(*) AS n FROM nto_object")[0]['n'] > 0:
    sys.exit("ОСТАНОВКА: в базе уже есть НТО, повторная загрузка не выполняется.")
data = json.load(open('data/seed.json', encoding='utf-8'))
for o in data:
    insert('nto_object', o)
n = rows("SELECT COUNT(*) AS n FROM nto_object")[0]['n']
print('Загружено объектов:', n, 'из', len(data))
if n != len(data): sys.exit("ВНИМАНИЕ: числа не совпали!")
