#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
internet_start.py (v2) — «одна кнопка»: запуск сайта «НТО и МКД» в интернете.

Что делает:
  1) проверяет, что сайт поднят; если нет — сам запускает «python app.py»
     в отдельном окне (порт читается из config.json, по умолчанию 8080);
  2) при первом запуске скачивает утилиту cloudflared (~35 МБ) в папку tools/;
  3) открывает БЕСПЛАТНЫЙ защищённый туннель Cloudflare (без регистрации,
     без карты, без открытых портов) и печатает публичную ссылку вида
     https://какие-то-слова.trycloudflare.com.

Что нового в v2 (после первого «не работает»):
  - ПЕРВЫМ ДЕЛОМ используется надёжный режим http2/TCP: провайдеры в России
    часто режут UDP, на котором Cloudflare работает по умолчанию (QUIC), —
    из-за этого ссылка создаётся, но не открывается (ошибка 520).
  - Скрипт САМ ПРОВЕРЯЕТ полученную ссылку: идёт в интернет и возвращается
    через туннель. Открывается — печатает «ГОТОВО!». Не открывается — сам
    пробует другой режим соединения (http2/QUIC) по кругу, до 3 раз.
  - Если автопроверка не может открыть ссылку из-за прокси или антивируса
    на рабочем ПК (а с телефона ссылка работает) — запустите с параметром
    NTO_SELFCHECK=0:  set NTO_SELFCHECK=0 && Запуск_сайта_в_интернете.bat

Эту ссылку отправляете сотрудникам и жителям: сотрудники входят под
своими логинами (как обычно), обычные люди без входа видят карту и общую
информацию. Базы SQL Server остаются только на вашем ПК — наружу уходит
только сайт.

Запуск:
  - двойной клик по «Запуск_сайта_в_интернете.bat», или
  - в консоли:  python internet_start.py [путь\\к\\app.py]

Остановка: закрыть окна, или Ctrl+C. Ссылка живёт, пока открыт туннель;
при каждом новом запуске ссылка будет новой (бесплатный режим Cloudflare).
"""

import json
import os
import re
import sys
import time
import shutil
import socket
import urllib.request
import urllib.error
import subprocess

if hasattr(sys.stdout, "reconfigure"):      # кириллица в консоли Windows
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

HERE            = os.path.dirname(os.path.abspath(__file__))
TOOLS           = os.path.join(HERE, "tools")
IS_WIN          = os.name == "nt"
CLOUDFLARED     = os.environ.get("NTO_CLOUDFLARED") or os.path.join(
                    TOOLS, "cloudflared.exe" if IS_WIN else "cloudflared")
CLOUDFLARED_URL = ("https://github.com/cloudflare/cloudflared/releases/"
                   "latest/download/cloudflared-windows-amd64.exe")
URL_RE          = re.compile(r"https://[A-Za-z0-9-]+\.trycloudflare\.com")
ERR_RE          = re.compile(r"\bERR\b")          # строка уровня ERR в логе
LINK_FILE       = os.path.join(HERE, "ссылка_на_сайт.txt")

PORT      = 8080
LOCAL_URL = "http://127.0.0.1:8080"

# Порядок попыток: сначала надёжный http2/TCP (провайдеры в РФ режут UDP/QUIC),
# затем стандартный режим, затем http2 без доп. флагов.
TUNNEL_ATTEMPTS = [
    ["--protocol", "http2", "--edge-ip-version", "4"],
    [],
    ["--protocol", "http2"],
]


def banner():
    print()
    print("  +--------------------------------------------------------------+")
    print("  |   НТО и МКД — Автодорожный округ (г. Якутск)                 |")
    print("  |   Запуск сайта в интернете: туннель Cloudflare (бесплатно)  |")
    print("  |   v2: режим http2/TCP + автопроверка ссылки «из интернета»   |")
    print("  +--------------------------------------------------------------+")
    print()


def load_port():
    """Порт из окружения -> config.json -> 8080 (как в самом сайте)."""
    global PORT, LOCAL_URL
    env = os.environ.get("NTO_PORT")
    if env and env.isdigit():
        PORT = int(env)
    else:
        parent = os.path.dirname(HERE)
        for base in (HERE, os.path.join(HERE, "NTO"), parent,
                     os.path.join(parent, "NTO")):
            cj = os.path.join(base, "config.json")
            if os.path.isfile(cj):
                try:
                    with open(cj, encoding="utf-8") as f:
                        cfg = json.load(f)
                    p = int(cfg.get("port") or 0)
                    if 0 < p < 65536:
                        PORT = p
                        print("  Порт взят из config.json: %d" % PORT)
                        break
                except Exception:
                    pass
    LOCAL_URL = "http://127.0.0.1:%d" % PORT


def site_alive(timeout=2):
    """Любой HTTP-ответ (даже 404) означает: сайт жив и порт слушает."""
    try:
        with urllib.request.urlopen(LOCAL_URL, timeout=timeout) as r:
            return r.status < 500
    except urllib.error.HTTPError as e:
        return e.code < 500
    except Exception:
        return False


def find_app():
    """Найти app.py: аргумент командной строки -> рядом -> в NTO -> у родителя."""
    if len(sys.argv) > 1 and os.path.isfile(sys.argv[1]):
        return os.path.abspath(sys.argv[1])
    parent = os.path.dirname(HERE)
    cands = [
        os.path.join(HERE, "app.py"),
        os.path.join(HERE, "NTO", "app.py"),
        os.path.join(parent, "app.py"),
        os.path.join(parent, "NTO", "app.py"),
    ]
    for c in cands:
        if os.path.isfile(c):
            return c
    return None


def start_site(app_py):
    print("  Запускаю сайт: " + app_py)
    flags = subprocess.CREATE_NEW_CONSOLE if IS_WIN else 0
    subprocess.Popen([sys.executable, app_py],
                    cwd=os.path.dirname(app_py), creationflags=flags)
    print("  Жду, пока сайт поднимется (порт %d)..." % PORT)
    for _ in range(60):
        if site_alive():
            return True
        time.sleep(1)
    return site_alive()


def _progress(num, block, total):
    if total:
        done = min(num * block, total)
        pct = done * 100 // total
        bar = "#" * (pct // 4)
        sys.stdout.write("\r  Скачиваю: %5.1f/%.1f МБ  [%-25s] %3d%% "
                         % (done / 1048576.0, total / 1048576.0, bar, pct))
        sys.stdout.flush()


def ensure_cloudflared():
    """Утилита туннеля: найти или скачать (один раз, ~35 МБ)."""
    if os.path.isfile(CLOUDFLARED):
        return True
    found = shutil.which("cloudflared")
    if found:
        globals()["CLOUDFLARED"] = found
        return True
    print("  Первый запуск: скачиваю утилиту cloudflared (~35 МБ, один раз).")
    os.makedirs(TOOLS, exist_ok=True)
    try:
        urllib.request.urlretrieve(CLOUDFLARED_URL, CLOUDFLARED, _progress)
        print()
    except Exception as e:
        print()
        print("  Не получилось скачать: %s" % e)
        print("  Скачайте вручную: " + CLOUDFLARED_URL)
        print("  и сохраните как:   " + CLOUDFLARED)
        return False
    return os.path.isfile(CLOUDFLARED)


def lan_ip():
    """IP компьютера в офисной сети — для коллег без интернета."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return None
    finally:
        s.close()


def check_url(url, tries=3, timeout=10):
    """Автопроверка: открыть ссылку «снаружи» (в интернет и обратно в туннель).

    NTO_SELFCHECK=0 — не проверять (для прокси/антивируса, ссылка при этом
    с телефона работает). NTO_SELFCHECK=1 — всегда «не открывается» (отладка).
    """
    env = os.environ.get("NTO_SELFCHECK", "")
    if env == "0":
        return True
    if env == "1":
        return False
    for i in range(tries):
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": "Mozilla/5.0 (nto-check)"})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                if r.status < 500:
                    return True
        except urllib.error.HTTPError as e:
            if e.code < 500:
                return True
            # 52x — туннель не жив, подождём и повторим
        except Exception:
            pass
        if i < tries - 1:
            time.sleep(4)
    return False


def announce(url, verified=True):
    line = "-" * 62
    print()
    print("  " + line)
    if verified:
        print("  ГОТОВО! Сайт в интернете. Публичная ссылка:")
    else:
        print("  Ссылка получена. Автопроверка с этого ПК её открыть не")
        print("  смогла — чаще всему виной антивирус или прокси (проверьте")
        print("  ссылку с телефона). Дальше просто смотрим на это окно:")
    print()
    print("        " + url)
    print()
    print("  " + line)
    if verified:
        print("  Отправьте эту ссылку сотрудникам и жителям.")
        print("  Пока это окно открыто и ПК включён — сайт доступен.")
        print("  При следующем запуске ссылка будет ДРУГОЙ (бесплатный режим).")
        print("  Тишина в этом окне = ХОРОШО: ошибок нет, туннель работает.")
    else:
        print("  Если окно ниже МОЛЧИТ — ссылка работает, отправляйте её людям")
        print("  (автопроверке помешал антивирус/прокси, это бывает).")
        print("  Если ниже ПОСЫПАЛИСЬ ОШИБКИ — не отправляйте: скрипт сам")
        print("  сменит режим соединения и даст новую ссылку.")
    try:
        with open(LINK_FILE, "w", encoding="utf-8") as f:
            f.write(url + "\n")
        print("  Ссылка записана в файл «ссылка_на_сайт.txt».")
    except Exception:
        pass
    if IS_WIN:                       # копия в буфер обмена (Windows)
        try:
            subprocess.run(["powershell", "-NoProfile", "-Command",
                            "Set-Clipboard -Value '%s'" % url],
                           capture_output=True, timeout=15)
            if verified:
                print("  Ссылка скопирована в буфер обмена (Ctrl+V).")
        except Exception:
            pass
    if verified:                     # браузер открываем только для рабочей ссылки
        try:
            import webbrowser
            webbrowser.open(url)
        except Exception:
            pass


def kill_proc(proc):
    try:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
    except Exception:
        pass


def tunnel_session(extra_args, attempt_no, total):
    """Один запуск cloudflared. Живёт, пока туннель жив и здоров.

    Возвращает (url, ok): ok=True — туннель работал и оборвался сам,
    ok=False — туннель сломался/не прошёл проверку (надо пробовать иначе).
    """
    cmd = [CLOUDFLARED, "tunnel", "--url", "http://localhost:%d" % PORT] + \
        list(extra_args)
    mode = ("надёжный режим http2/TCP (для сетей, где режут UDP)"
            if "--protocol" in cmd else "стандартный режим QUIC/UDP")
    print()
    print("  Попытка %d из %d — %s." % (attempt_no, total, mode))
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True,
                             encoding="utf-8", errors="replace", bufsize=1)
    url, errs, verified, broken = None, 0, False, False
    try:
        for raw in proc.stdout:
            t = raw.strip()
            if not t:
                continue
            m = URL_RE.search(t)
            if m and not url:
                url = m.group(0)
                print("  Ссылка получена: " + url)
                print("  Автопроверка: открываю её через интернет (10-20 сек)...")
                if check_url(url):
                    verified = True
                    announce(url, verified=True)
                    print("  Автопроверка: сайт ОТВЕЧАЕТ — ссылка рабочая.")
                else:
                    announce(url, verified=False)
                    print("  Жду: вдруг ошибки покажут, что туннель не жив...")
            if ERR_RE.search(t):
                errs += 1
                print("  | " + t[:110])
            elif url is None and any(
                    k in t.lower() for k in ("err", "fail", "warn")):
                print("  | " + t[:110])
            if url and errs >= 5:            # поток ошибок = туннель болен
                print("  Много ошибок соединения — туннель нестабилен.")
                if verified:
                    print("  Перепроверяю ссылку...")
                    if check_url(url):
                        errs = 0
                        print("  Ссылка всё ещё отвечает — продолжаем.")
                    else:
                        broken = True
                else:
                    broken = True
                if broken:
                    break
        if not broken and url:
            if proc.poll() is not None:
                print("  cloudflared сам завершился (попытка %d)." % attempt_no)
    finally:
        kill_proc(proc)
    return url, broken


def run_tunnel():
    print()
    print("  Открываю туннель Cloudflare (бесплатно, без регистрации)...")
    total = len(TUNNEL_ATTEMPTS)
    for i, extra in enumerate(TUNNEL_ATTEMPTS, 1):
        try:
            url, broken = tunnel_session(extra, i, total)
        except KeyboardInterrupt:
            print("\n  Туннель остановлен вами. До встречи!")
            return None
        if url:
            print("  Эта попытка закончилась. Пробую другой режим соединения...")
        time.sleep(3)
    print()
    print("  " + "-" * 60)
    print("  Автоматические попытки закончились. Что делать:")
    print("   1) просто запустите bat ещё раз — иногда проходит со 2-го раза;")
    print("   2) если ссылка с телефона открывается, а автопроверка на ПК")
    print("      ругается — это прокси/антивирус: запустите в консоли")
    print("          set NTO_SELFCHECK=0")
    print("          Запуск_сайта_в_интернете.bat")
    print("   3) вариант Б из «Инструкция.txt» — ngrok (постоянная ссылка);")
    print("   4) проверьте, что обычные сайты в браузере на этом ПК открываются.")
    return None


def main():
    banner()
    load_port()
    if site_alive():
        print("  Сайт уже работает: " + LOCAL_URL)
    else:
        app_py = find_app()
        if not app_py:
            print("  Не нашёл app.py рядом с этим скриптом.")
            print("  Запустите так:  python internet_start.py C:\\NTO\\NTO\\app.py")
            sys.exit(1)
        if not start_site(app_py):
            print("  Сайт не поднялся за 60 секунд. Запустите «python app.py»")
            print("  в отдельном окне, посмотрите ошибку и попробуйте снова.")
            sys.exit(1)
        print("  Сайт поднялся: " + LOCAL_URL)
    ip = lan_ip()
    if ip:
        print("  Коллегам в офисе (без интернета):  http://%s:%d" % (ip, PORT))
    if not ensure_cloudflared():
        sys.exit(1)
    try:
        run_tunnel()
    except KeyboardInterrupt:
        print("\n  Остановлено. До встречи!")


if __name__ == "__main__":
    main()
