#!/bin/bash
set -e

# ============================================================
#  Honeypot generator v.0.4
#  Генерация случайного сайта-визитки + nginx + Let's Encrypt
#
#  Использование:
#    ./honeypot-generator.sh [домен]
#
#  Переменные окружения (необязательно):
#    HONEYPOT_SEED=12345     повторить ранее сгенерированный сайт
#    HONEYPOT_DRYRUN=1       только сгенерировать файлы сайта
#                            (без apt / nginx / certbot, root не нужен)
#    HONEYPOT_WEBROOT=/path  каталог сайта (по умолчанию /var/www/honeypot)
# ============================================================

WEBROOT=""
NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
DRY_RUN="${HONEYPOT_DRYRUN:-0}"
C_RESET="\\033[0m"; C_CYAN="\\033[36m"; C_GREEN="\\033[32m"; C_YELLOW="\\033[33m"; C_RED="\\033[31m"; C_BOLD="\\033[1m"
if [[ -t 1 ]]; then COLOR=1; else COLOR=0; fi
paint(){ if [ "$COLOR" -eq 1 ]; then printf '%b%s%b\n' "$1" "$2" "$C_RESET"; else printf '%s\n' "$2"; fi; }
line(){ printf '%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'; }
step(){ if [ "$COLOR" -eq 1 ]; then printf '\n%b▶ %s%b\n' "$C_CYAN$C_BOLD" "$1" "$C_RESET"; else printf '\n▶ %s\n' "$1"; fi; }

if [ "$DRY_RUN" != "1" ] && [ "$(id -u)" -ne 0 ]; then
    echo "Запустите скрипт от root (sudo)."
    exit 1
fi

DOMAIN="${1:-}"

if [ -z "$DOMAIN" ]; then
    [[ -t 1 ]] && clear
    paint "$C_CYAN$C_BOLD" "╭────────────────────────────────────────────────────────────╮"
    paint "$C_CYAN$C_BOLD" "│                 HONEYPOT GENERATOR v0.4                    │"
    paint "$C_CYAN$C_BOLD" "╰────────────────────────────────────────────────────────────╯"
    echo "  Генерация сайта • безопасная настройка nginx • HTTPS"
    echo
    read -rp "  Домен (например site.example.com): " DOMAIN
fi

DOMAIN="${DOMAIN,,}"
if [ -z "$DOMAIN" ]; then
    echo "Домен не может быть пустым."
    exit 1
fi
if ! [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]]; then
    echo "Некорректный домен: $DOMAIN"
    exit 1
fi

WEBROOT="${HONEYPOT_WEBROOT:-/var/www/honeypot/$DOMAIN}"
step "1/6  Проверка окружения"
printf "  Домен:     %s\\n  Каталог:   %s\\n  Режим:     %s\\n" "$DOMAIN" "$WEBROOT" "$([ "$DRY_RUN" = "1" ] && echo "dry-run" || echo "установка")"
if [ "$DRY_RUN" != "1" ]; then
    if ! command -v apt-get >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
        paint "$C_RED" "✖ Ожидается Debian/Ubuntu с apt-get и systemd."
        exit 1
    fi
    # ---------- поиск следов ранее настроенного домена ----------
    NGINX_CONFD="/etc/nginx/conf.d"
    LE_DIR="/etc/letsencrypt"
    RENEW_SCRIPT="/usr/local/bin/renew-${DOMAIN}.sh"
    RENEW_LOG="/var/log/renew-${DOMAIN}.log"
    DEFAULT_WEBROOT="/var/www/honeypot/${DOMAIN}"
    DOMAIN_RE="${DOMAIN//./\\.}"
    NGINX_HITS=(); DEL_NGINX=(); BLOCKED=(); CERT_PATHS=(); CERT_NAMES=()
    HAS_WEBROOT=0; HAS_RENEW=0; HAS_CRON=0

    add_uniq() {
        local -n _arr="$1"
        local x
        for x in "${_arr[@]}"; do
            if [ "$x" = "$2" ]; then return 0; fi
        done
        _arr+=("$2")
    }
    # 0, если в server_name файла нет никаких доменов, кроме $2
    only_this_domain() {
        local other
        other="$(grep -hE '^[[:space:]]*server_name[[:space:]]' "$1" 2>/dev/null \
            | sed -E 's/#.*//; s/^[[:space:]]*server_name[[:space:]]+//; s/;.*//' \
            | tr -s ' \t' '\n\n' | grep -v '^$' | grep -vxF "$2" || true)"
        [ -z "$other" ]
    }

    # 1) nginx: конфиги с именем домена, симлинки на них и любые файлы с этим server_name
    for _f in "$NGINX_AVAILABLE/${DOMAIN}.conf" "$NGINX_ENABLED/${DOMAIN}.conf" "$NGINX_CONFD/${DOMAIN}.conf"; do
        if [ -e "$_f" ] || [ -L "$_f" ]; then add_uniq NGINX_HITS "$_f"; fi
    done
    if [ -d "$NGINX_ENABLED" ]; then
        _exact_real="$(readlink -f "$NGINX_AVAILABLE/${DOMAIN}.conf" 2>/dev/null || true)"
        for _f in "$NGINX_ENABLED"/*; do
            if [ -L "$_f" ] && [ "$(readlink -f "$_f" 2>/dev/null || true)" = "$_exact_real" ]; then
                add_uniq NGINX_HITS "$_f"
            fi
        done
    fi
    _dirs=()
    for _d in "$NGINX_AVAILABLE" "$NGINX_ENABLED" "$NGINX_CONFD"; do
        if [ -d "$_d" ]; then _dirs+=("$_d"); fi
    done
    if [ "${#_dirs[@]}" -gt 0 ]; then
        while IFS= read -r _f; do
            if [ -n "$_f" ]; then add_uniq NGINX_HITS "$_f"; fi
        done < <(grep -RIlE "^[[:space:]]*server_name[[:space:]]([^;]*[[:space:]])?${DOMAIN_RE}[[:space:];]" "${_dirs[@]}" 2>/dev/null || true)
    fi
    for _f in "${NGINX_HITS[@]}"; do
        if [ -L "$_f" ] && [ ! -e "$_f" ]; then
            add_uniq DEL_NGINX "$_f"                  # битая ссылка
        elif only_this_domain "$_f" "$DOMAIN"; then
            add_uniq DEL_NGINX "$_f"
        else
            add_uniq BLOCKED "$_f"                    # в файле есть другие домены
        fi
    done
    if [ "${#BLOCKED[@]}" -gt 0 ]; then
        paint "$C_RED" "✖ Домен указан в конфигурации nginx вместе с другими доменами:"
        printf '    %s\n' "${BLOCKED[@]}"
        echo "  Автоматическое удаление небезопасно. Уберите домен из server_name вручную и запустите скрипт снова."
        exit 1
    fi

    # 2) сертификаты Let's Encrypt (live / archive / renewal)
    for _p in "$LE_DIR/live/${DOMAIN}" "$LE_DIR"/live/"${DOMAIN}"-[0-9][0-9][0-9][0-9] \
              "$LE_DIR/archive/${DOMAIN}" "$LE_DIR"/archive/"${DOMAIN}"-[0-9][0-9][0-9][0-9] \
              "$LE_DIR/renewal/${DOMAIN}.conf" "$LE_DIR"/renewal/"${DOMAIN}"-[0-9][0-9][0-9][0-9].conf; do
        if [ -e "$_p" ] || [ -L "$_p" ]; then
            add_uniq CERT_PATHS "$_p"
            _n="$(basename "$_p")"
            case "$_p" in */renewal/*) _n="${_n%.conf}" ;; esac
            add_uniq CERT_NAMES "$_n"
        fi
    done

    # 3) каталог сайта, скрипт автообновления, cron
    if [ -d "$WEBROOT" ] && [ -n "$(find "$WEBROOT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then HAS_WEBROOT=1; fi
    if [ -e "$RENEW_SCRIPT" ]; then HAS_RENEW=1; fi
    if crontab -l 2>/dev/null | grep -qF "$RENEW_SCRIPT"; then HAS_CRON=1; fi

    if [ $(( ${#DEL_NGINX[@]} + ${#CERT_PATHS[@]} + HAS_WEBROOT + HAS_RENEW + HAS_CRON )) -gt 0 ]; then
        paint "$C_YELLOW" "⚠ Домен уже настраивался на этом сервере. Найдено:"
        for _f in "${DEL_NGINX[@]}"; do echo "    nginx:        $_f"; done
        for _p in "${CERT_PATHS[@]}"; do echo "    сертификат:   $_p"; done
        if [ "$HAS_WEBROOT" -eq 1 ]; then
            if [ "$WEBROOT" = "$DEFAULT_WEBROOT" ]; then
                echo "    каталог:      $WEBROOT"
            else
                echo "    каталог:      $WEBROOT (нестандартный путь — удалён не будет, файлы будут перезаписаны)"
            fi
        fi
        if [ "$HAS_RENEW" -eq 1 ]; then echo "    автообновление: $RENEW_SCRIPT"; fi
        if [ "$HAS_CRON" -eq 1 ]; then echo "    cron:         задание для $RENEW_SCRIPT"; fi
        echo

        while :; do
            if ! read -rp "  Удалить конфигурацию для этого домена и создать заново? [Y/n] (Enter = да): " ANSWER; then
                echo; echo "Отменено."; exit 1
            fi
            case "$ANSWER" in
                ""|y|Y|yes|YES|Yes|д|Д|да|Да|ДА) break ;;
                n|N|no|NO|No|н|Н|нет|Нет|НЕТ) echo "Отменено. Ничего не изменено."; exit 0 ;;
                *) echo "  Введите y или n (Enter = да)." ;;
            esac
        done

        # --- удаление: nginx (сначала ссылки, затем сами конфиги) ---
        for _f in "${DEL_NGINX[@]}"; do
            if [ -L "$_f" ]; then rm -f -- "$_f"; fi
        done
        for _f in "${DEL_NGINX[@]}"; do
            rm -f -- "$_f"
        done
        # --- сертификаты: штатно через certbot, запасной вариант — вручную ---
        for _n in "${CERT_NAMES[@]}"; do
            if command -v certbot >/dev/null 2>&1; then
                certbot delete --cert-name "$_n" --non-interactive >/dev/null 2>&1 || true
            fi
            rm -rf -- "$LE_DIR/live/$_n" "$LE_DIR/archive/$_n" "$LE_DIR/renewal/$_n.conf"
        done
        # --- автообновление и cron ---
        if [ "$HAS_CRON" -eq 1 ]; then
            ( crontab -l 2>/dev/null | grep -vF "$RENEW_SCRIPT" || true ) | crontab -
        fi
        rm -f -- "$RENEW_SCRIPT" "$RENEW_LOG"
        # --- каталог сайта: только стандартный путь /var/www/honeypot/<домен> ---
        if [ "$WEBROOT" = "$DEFAULT_WEBROOT" ] && [ -d "$WEBROOT" ]; then
            rm -rf -- "$WEBROOT"
        fi
        # --- применить удаление в работающем nginx ---
        if [ "${#DEL_NGINX[@]}" -gt 0 ] && command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
            systemctl reload nginx >/dev/null 2>&1 || true
        fi
        paint "$C_GREEN" "  ✓ Старая конфигурация удалена, создаю заново."
    fi
fi

# ------------------------------------------------------------
# Проверка и установка зависимостей
# ------------------------------------------------------------
if [ "$DRY_RUN" != "1" ]; then
    step "2/6  Проверка и установка зависимостей"

    export DEBIAN_FRONTEND=noninteractive
    APT_UPDATED=0

    install_if_missing() {
        local pkg="$1"
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            echo "  -> $pkg не найден, устанавливаю..."
            if [ "$APT_UPDATED" -eq 0 ]; then
                apt-get update -qq
                APT_UPDATED=1
            fi
            apt-get install -y "$pkg"
        else
            echo "  -> $pkg уже установлен"
        fi
    }

    install_if_missing nginx
    install_if_missing certbot
    install_if_missing python3-certbot-nginx
    mkdir -p /var/www/certbot
fi

mkdir -p "$WEBROOT"

# ============================================================
#  ГЕНЕРАТОР САЙТА
# ============================================================
step "3/6  Генерация сайта"

# ---------- сид (для воспроизводимости) ----------
SEED="${HONEYPOT_SEED:-$(( (RANDOM << 15) | RANDOM ))}"
RANDOM=$SEED

# ---------- помощники (без подоболочек, чтобы сид работал корректно) ----------
LETTERS=ABCDEFGHIJKLMNOPQRSTUVWXYZ
CA_LETTERS=ABCEGHJKLMNPRSTVWXYZ
R=""
rnd()    { R=$(( $1 + RANDOM % ($2 - $1 + 1) )); }
chance() { if (( RANDOM % 100 < $1 )); then R=1; else R=0; fi; }
pick()   { local -n _pa=$1; R="${_pa[RANDOM % ${#_pa[@]}]}"; }
shuffle() {
    local -n _sa=$1
    local i j t
    for (( i=${#_sa[@]}-1; i>0; i-- )); do
        j=$(( RANDOM % (i+1) ))
        t="${_sa[i]}"; _sa[i]="${_sa[j]}"; _sa[j]="$t"
    done
}
fmt_fill() {   # N цифра, L буква, P буква (CA), строчная буква = литерал, остальное как есть
    local f="$1" out="" c i
    for (( i=0; i<${#f}; i++ )); do
        c="${f:i:1}"
        case "$c" in
            N) out+=$(( RANDOM % 10 )) ;;
            L) out+="${LETTERS:RANDOM%26:1}" ;;
            P) out+="${CA_LETTERS:RANDOM%20:1}" ;;
            [[:lower:]]) out+="${c^^}" ;;
            *) out+="$c" ;;
        esac
    done
    R="$out"
}
html_esc() {
    local s="$1"
    s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"
    R="$s"
}
hsl2hex() {
    awk -v h="$1" -v s="$2" -v l="$3" '
    function mn(a,b){return a<b?a:b}
    function mx(a,b){return a>b?a:b}
    function f(n,  k,a,t){k=(n+h/30)%12; a=(s/100)*mn(l/100,1-l/100);
        t=mx(-1,mn(mn(k-3,9-k),1)); return int((l/100-a*t)*255+0.5)}
    BEGIN{printf "#%02x%02x%02x",f(0),f(8),f(4)}'
}

CUR_YEAR=$(date +%Y)

# ============================================================
#  ПУЛЫ ДАННЫХ И ГЕНЕРАТОРЫ
#  Готовых предложений в коде нет: тексты собираются из шаблонов
#  по токенам @NAME@ (см. expand), слова берутся из словарей P_NAME.
#  Словари содержат только слова и короткие фразы по тематике.
# ============================================================

# ---------- общие словари (не зависят от тематики) ----------
P_SIZE=("a small" "an independent" "a friendly" "a close-knit" "an experienced" "a dedicated")
P_QUAL=("with care" "on schedule" "in a clear, structured way" "step by step" "without surprises" "to a clear brief" "with attention to detail" "on time and on budget")
P_DELIV=(delivered handled provided managed)
P_TRAIT=(calm direct thorough responsive friendly reliable patient honest professional practical "well prepared" "easy to work with")
P_TRUST=(trust recommend)
P_REF=(recommendation referrals "word of mouth")
P_EXP=("a pleasure" "refreshingly straightforward" "easy from the first call" "a real relief" "far easier than we expected")
P_QRES=("better than we expected" "exactly what we needed" "delivered on time" "clear and easy to follow" "a real improvement for our team" "handled with great care")
P_RECO=(recommend "happily recommend" "gladly recommend" "highly recommend")
P_LEADIN=("You can count on us to" "Our team will" "Expect us to" "We are here to")
P_LISTEN=("learning about" "looking closely at" "getting to know" "reviewing" "asking about")
P_ST1=(Discover Listen Brief Introduction Scope)
P_ST2=(Plan Assess Review Propose)
P_ST3=(Deliver Implement Execute Produce)
P_ST4=(Support Follow-up Handover Aftercare)
P_SMALL=(small simple urgent routine)
P_LARGE=(large complex long-term ambitious)
P_PADJ=(simple clear transparent straightforward)
P_INFORMED=(informed "up to date" "on the same page" "in the loop")
P_FIRSTW=(call conversation meeting enquiry)
P_LASTW=(delivery handover review sign-off)
P_KIND=("A few words" "Some kind words" "Feedback" "Comments")
P_LUCKY=(lucky grateful fortunate)
P_GIVE=("are generous with their feedback" "share their experience openly" "tell us honestly what they think")
P_CVERB=("Call, write or drop by" "Tell us about your project" "Get in touch whenever it suits you" "Send us a message or give us a call")
P_REPLY=("We usually reply" "We aim to reply" "You will normally hear back")
P_DAYS=("one working day" "a day" "24 hours" "two working days")

# ---------- шаблоны текста ----------
HERO_TPL=("@HADJ@ @HNOUN@ for @WHO@" "@HNOUN@ that @HTAIL@" "@HNOUN@ you can @TRUST@")
TAG_TPL=("@HADJ@ @HNOUN@, @DELIV@ @QUAL@." "@HNOUN@ for @WHO@, @DELIV@ @QUAL@." "@SIZE@ @TEAM@ of @PRO@, focused on @CARE@.")
LEAD_TPL=(
 "We @ACT@, @ACT2@ and @ACT3@ for @WHO@."
 "@SIZE@ @TEAM@ of @PRO@ who @ACT@ and @ACT2@, @QUAL@."
 "We help @WHO@ @GOAL@ and @GOAL2@, @QUAL@."
 "From the first @FIRSTW@ to the final @LASTW@, we @ACT@ and @ACT2@ for @WHO@."
)
AS_ID=(
 "We are @SIZE@ @TEAM@ of @PRO@ who care about @CARE@, @CARE2@ and @CARE3@."
 "Our @TEAM@ of @PRO@ is focused on @CARE@, and we @ACT@ for @WHO@."
 "We are @SIZE@ @TEAM@ of @PRO@, and we @ACT@ for @WHO@."
)
AS_CL=(
 "Most of our clients come to us through @REF@, and many have stayed with us for years."
 "Our clients include @CLIENT@, @CLIENT2@ and @CLIENT3@."
 "We work with @CLIENT@ and @CLIENT2@, and most of them find us through @REF@."
)
AS_WORK=(
 "Each project starts with a conversation about your @OBJ@ and ends with @OUT@."
 "We keep our team deliberately small, so the people you meet first are the people who @ACT@ and @ACT2@."
 "Whatever the size of the job, you deal directly with the @PRO@ responsible for it."
 "We @ACT@, @ACT2@ and @ACT3@, always @QUAL@."
 "You can expect us to @ACT@ @QUAL@, and to @ACT2@ without fuss."
)
ABOUT_LOC_TPL=(
 "Founded in @YEAR@ and based in @CITY@, we work with @CLIENT@, @CLIENT2@ and @CLIENT3@ across @COUNTRYTHE@."
 "Since @YEAR@ we have been working from @CITY@, helping @CLIENT@ and @CLIENT2@ across @COUNTRYTHE@ and beyond."
 "Our office in @CITY@ has been home to the team since @YEAR@, and we work with clients locally and across @COUNTRYTHE@."
)
P_SVCTPL=(
 "We @ACT@ and @ACT2@, @QUAL@."
 "@LEADIN@ @ACT@ and @ACT2@."
 "A practical service for @WHO@: we @ACT@, then @ACT2@."
 "We help @WHO@ @GOAL@, and we @ACT@ @QUAL@."
 "Our @PRO@ @ACT@, @QUAL@, from the first @FIRSTW@ to the final @LASTW@."
 "We help @WHO@ @GOAL@ and @GOAL2@, @QUAL@."
)
PT_S1=("We start by @LISTEN@ your @OBJ@, so we understand what a good result looks like." "We begin with a conversation about your @OBJ@ and @OBJ2@.")
PT_S2=("We @ACT@ and share what we find, @QUAL@." "A specialist team will @ACT@ and @ACT2@.")
PT_S3=("You receive @OUT@, prepared @QUAL@." "We deliver @OUT@, ready for you to use.")
PT_S4=("We stay involved after delivery to @ACT@ as your needs change." "You keep the same contact, who will @ACT@ whenever you need us.")
QT_TPL=(
 "They @DONE@ and the result was @QRES@."
 "They were @TRAIT@, @TRAIT2@ and @TRAIT3@ from the first @FIRSTW@ to the final @LASTW@. We would @RECO@ them to anyone who needs help with their @OBJ@."
 "Working with them was @EXP@. They @DONE@ and @DONE2@."
 "We have worked with them more than once. Each time they @DONE@, and the invoice matched the quote."
)
SUBSVC_TPL=("Here is how we can help @WHO@." "Whether the need is @SMALL@ or @LARGE@, we shape the work around you." "A focused set of services for @WHO@, @DELIV@ @QUAL@.")
SUBPROC_TPL=("A @PADJ@ process that keeps everyone @INFORMED@." "No surprises, just clear steps from the first @FIRSTW@ to the final @LASTW@.")
SUBQ_TPL=("@KIND@ from people we have worked with." "We are @LUCKY@ to work with clients who @GIVE@.")
SUBC_TPL=("@CVERB@. @REPLY@ within @DAYS@." "@REPLY@ within @DAYS@. @CVERB@.")

# ---------- значения (название|варианты фраз после «We») ----------
VALUES=(
 "Plain language|explain things clearly|avoid jargon|write in plain English|keep every message easy to follow"
 "Honest estimates|quote fairly|agree prices in advance|flag changes before they cost you|keep invoices in line with quotes"
 "Direct access|put you in touch with the people doing the work|keep one named contact for every project|answer your calls ourselves"
 "Long-term thinking|aim for results that last|think beyond the first project|look after clients for years"
 "Careful delivery|respect deadlines|check the details twice|keep everyone informed along the way"
 "Fair pricing|keep our fees clear|agree costs in advance|avoid hidden extras"
 "Discretion|keep your information confidential|treat every project as private|share details only when needed"
 "Responsiveness|reply within one working day|answer messages promptly|keep you updated as work progresses"
)

H_ABOUT=("About us" "Who we are" "Our story" "A little about us")
H_SVC=("Services" "What we do" "How we can help" "Our expertise" "What we offer")
H_PROC=("How we work" "Our approach" "Working together" "The process")
H_QUOTES=("What clients say" "Client feedback" "Kind words" "In their words")
H_CONTACT=("Get in touch" "Contact us" "Let's talk" "Visit or write to us")
CTA_NAV=("Contact us" "Get in touch" "Talk to us" "Request a call")
CTA_HERO1=("Get in touch" "Start a conversation" "Request a quote" "Book an introductory call")
CTA_HERO2=("See our services" "What we do" "Explore services" "Learn more")

# ---------- словари для имён, адресов, часов ----------
FIRST=(Anna James Maria Daniel Sofia Liam Elena Marcus Priya Thomas Hannah Omar Claire Lucas Nina Peter Grace Samuel Julia Victor Amara Ethan Clara Felix Isla Noah Maya Oliver Leila Henry Zoe Adam Rosa Jonas Tessa Owen Mira Callum Freya Ravi Ingrid Joel Dana Hugo Esme Kai Lena Theo)
ROLES=("Managing Director" "Operations Manager" "Founder" "Head of Finance" "Project Lead" "Office Manager" "Product Owner" "Marketing Director" "Owner" "Head of Operations" "Partner")
ORG_NOUN=(Foods Dental Housing Retail Farms Clinic Energy Hotels Electronics Bakery Engineering Textiles Media Publishing Dairy Pharmacy Motors Interiors)
SN_STEM=(Hart Ash Whit Brook Cal Fen Kings Mar Ridge Stan Thorn Wood Ellis Har Lind Pres Sut Bren Del Hol Alder Fair Green Hill Long Mer Nor Oak Pen Rob Sand Strat Tay Wal Win Ember Cross Rowan)
SN_END=(ley ford ton well wick field more man worth son ham by den ward ridge)
BR_ON=(b d f g h k l m n p r s t v z br dr fl gr kr pr tr)
BR_VO=(a e i o u)
BR_CO=("" "" n r l s m x)
BR_EN=(a o is on ia um ar en ix el)
WORDS=(Nord Vela Lumen Aster Vero Arcus Solace Pelago Meridian Orbit Cobalt Juniper Beacon Quarry Tern Alba Kestrel Linden Marlow Corvus Tallis Halden Oriel Verity)
PRE=(North West Iron Clear Silver Fox Birch Cedar Elm Oak Lark Tide Bright Green Grey Red Pine Wren Ash Summer Harbor Mill)
POST=(field wood stone light well bridge gate path ridge brook point haven line vale)
ST_STEM=(Maple Harbor Mill Park King Queen Church Station Elm Victoria Bridge Orchard Cedar Market Lake Grove Albert Willow Meadow Hill River High)
ST_TYPE=(Street Road Avenue Lane Way Square Court)
NL_STEM=(Kerk Molen Linden Haven Markt Bloem Oranje Konings Zuider Noorder Dijk Beuk Wilgen Prins)
NL_SUF=(straat laan weg gracht)
UNIT_KIND=(Suite Unit)
EMAIL_LOCALS=(info hello contact office mail team enquiries)
HR_DAYS=("Mon–Fri" "Monday to Friday" "Weekdays")
HR_MIN=(00 30)

# ---------- темы: словари по отрасли ----------
# P_HADJ/P_HNOUN — заголовки; P_ACT — «we ...» (инфинитив с объектом);
# P_GOAL — «help X ...»; P_OBJ — «your ...»; P_OUT — результат с артиклем;
# P_TOPIC × P_FORM и P_SOLO — названия услуг; P_DONE — прошедшее время для отзывов.
theme_consulting() {
  T_KEY=consulting; T_INDUSTRY="management consultancy"; T_SCHEMA=ProfessionalService
  T_SUFFIX=(Consulting Advisory Partners Group)
  P_HADJ=(Clear Practical Independent Honest Careful); P_HNOUN=(advice thinking planning support analysis)
  P_HTAIL=("turns into results" "keeps projects on track" "your team can follow" "survives contact with reality")
  P_WHO=("growing businesses" "owners and managers" "small and mid-sized companies" "leadership teams" "ambitious organizations")
  P_PRO=(advisers consultants "business analysts"); P_TEAM=(team group)
  P_CARE=("practical results" "clear communication" "honest advice" "long-term relationships" "getting the details right" "plain language")
  P_ACT=("untangle complex decisions" "review how the business runs" "map your priorities and risks" "plan the next stage of growth" "tighten processes and reporting" "agree realistic goals and timelines" "bring leadership teams to a shared view" "identify where costs can come down" "turn strategy into a delivery plan" "support teams through change" "benchmark performance against the market" "prepare boards and investors for key decisions")
  P_GOAL=("make confident decisions" "focus on what matters most" "plan growth with fewer surprises" "run more efficiently" "bring teams together behind one plan" "manage change without disruption")
  P_OBJ=(priorities processes goals plans challenges costs)
  P_OUT=("a short, prioritized plan" "a clear set of recommendations" "a practical roadmap" "a candid written assessment" "a realistic budget and timeline")
  P_CLIENT=("family businesses" start-ups manufacturers "local charities" retailers schools "professional firms" "housing associations")
  P_TOPIC=(Strategy Operations Change Market Project Performance Growth Risk); P_FORM=(review planning support advisory workshops)
  P_SOLO=("Management coaching" "Executive workshops" "Due diligence support")
  P_DONE=("reviewed how our business runs" "untangled a difficult decision for us" "built a plan we could actually follow" "brought our leadership team onto the same page" "found savings we had missed" "guided us through a major change")
  T_STATS=("Projects delivered|80|420" "Clients advised|40|180")
}
theme_design() {
  T_KEY=design; T_INDUSTRY="design studio"; T_SCHEMA=ProfessionalService
  T_SUFFIX=(Studio Design "Design Studio" Creative)
  P_HADJ=(Thoughtful Considered Distinctive Clear Honest); P_HNOUN=(design branding "visual identity" "web design")
  P_HTAIL=("earns its place" "people remember" "lasts for years" "works as hard as you do")
  P_WHO=("ambitious brands" "small and mid-sized organizations" "founders and cultural organizations" "growing businesses" "independent companies")
  P_PRO=(designers "designers and developers" "designers and art directors"); P_TEAM=(studio team)
  P_CARE=(clarity craft "making things useful first" "getting every detail right" "work that lasts" "honest feedback")
  P_ACT=("design identities that grow with you" "shape brand guidelines your team can use" "design websites that are easy to maintain" "lay out reports and printed materials" "direct photography and campaigns" "develop clear visual systems" "turn rough ideas into finished work" "refine logos, type and color" "prepare final files for print and web" "design packaging that works on the shelf" "present ideas with clear reasoning" "test layouts with real content")
  P_GOAL=("look as good as they work" "stand out for the right reasons" "explain what they do more clearly" "present themselves consistently" "launch with confidence")
  P_OBJ=(audience goals content ideas "brand history" preferences)
  P_OUT=("a small number of well-developed directions" "a complete set of brand guidelines" "polished, production-ready files" "a clear visual direction" "a site design ready for build")
  P_CLIENT=(founders "cultural organizations" "local businesses" publishers restaurants charities "technology companies" architects)
  P_TOPIC=(Brand Website Packaging Editorial Print Campaign Product Identity); P_FORM=(design direction workshops)
  P_SOLO=("Design systems" "Art direction" "Logo and type design" "Photography direction")
  P_DONE=("turned a vague brief into an identity we are proud of" "redesigned our website from the ground up" "made our printed material look far better" "gave our brand a clear and consistent look" "rebuilt our packaging from scratch" "listened carefully and got the tone exactly right")
  T_STATS=("Brands launched|45|260" "Websites shipped|60|310")
}
theme_architecture() {
  T_KEY=architecture; T_INDUSTRY="architecture and interiors practice"; T_SCHEMA=ProfessionalService
  T_SUFFIX=(Architects "Architecture Studio" "Design Office" Interiors)
  P_HADJ=(Considered Thoughtful Sustainable Practical Careful); P_HNOUN=(architecture "interior design" "residential design" "building design")
  P_HTAIL=("fits the way you live" "is shaped by light and place" "stands up to daily use")
  P_WHO=("families and homeowners" "growing businesses" "private clients" "developers and landlords" "people who care about their space")
  P_PRO=(architects "architects and interior designers" "architects and designers"); P_TEAM=(practice studio)
  P_CARE=("light and proportion" "listening before drawing" "buildings that last" "getting the details right" "practical, buildable design")
  P_ACT=("design homes, extensions and renovations" "plan interiors around how you live" "prepare and submit planning applications" "advise on what a site can offer" "detail drawings so builders can price with confidence" "supervise construction on site" "select materials and lighting" "guide projects through planning and building control" "test ideas with sketches and models" "coordinate engineers and consultants" "check the work against the drawings" "keep the project on budget")
  P_GOAL=("make the most of their space" "build with confidence" "turn a site into a home" "get planning approval with fewer surprises" "stay on budget during construction")
  P_OBJ=(site brief budget timeline ideas "planning constraints")
  P_OUT=("concept sketches and models" "a full set of detailed drawings" "a clear planning submission" "an honest feasibility report" "a specification builders can price")
  P_CLIENT=(homeowners developers "local businesses" schools landlords "restaurants and shops" "housing associations" "cultural venues")
  P_TOPIC=(Residential Commercial Interior Heritage Extension Retail Workplace Landscape); P_FORM=(design consultancy planning supervision)
  P_SOLO=("Feasibility studies" "Planning applications" "Site supervision" "Building surveys")
  P_DONE=("turned a dark, awkward house into a bright home" "guided us through planning without any drama" "kept the build on budget" "designed a space that works for how we live" "explained every drawing patiently")
  T_STATS=("Buildings completed|30|140" "Planning approvals|40|190")
}
theme_accounting() {
  T_KEY=accounting; T_INDUSTRY="accounting and tax advisory firm"; T_SCHEMA=AccountingService
  T_SUFFIX=(Accountants "Tax Advisory" "Financial Services" "& Co.")
  P_HADJ=(Dependable Straightforward Accurate Personal Careful); P_HNOUN=(accounting "tax advice" bookkeeping "financial support" "business advice")
  P_HTAIL=("keeps you on top of deadlines" "explains the numbers clearly" "saves time every month" "grows with your business")
  P_WHO=("small businesses" "self-employed professionals" "families and owners" "start-ups and freelancers" "growing companies")
  P_PRO=(accountants "accountants and tax advisers" "bookkeepers and accountants"); P_TEAM=(practice team)
  P_CARE=(accuracy "meeting deadlines" "plain language" "long-term relationships" "keeping things simple")
  P_ACT=("prepare annual accounts and tax returns" "keep your records accurate and up to date" "plan tax sensibly and within the rules" "run payroll and pensions" "handle sales tax and VAT returns" "build budgets and forecasts" "answer questions promptly and clearly" "spot savings and deadlines early" "reconcile accounts every month" "prepare management reports" "advise on the right business structure" "deal with the tax authorities on your behalf")
  P_GOAL=("keep on top of their finances" "pay no more tax than they need to" "meet every filing deadline" "understand their numbers" "plan for the year ahead")
  P_OBJ=(records "tax position" deadlines "cash flow" "business goals" paperwork)
  P_OUT=("accurate, filed accounts" "a clear summary of your tax position" "a simple calendar of deadlines" "a budget you can work to" "regular management reports")
  P_CLIENT=("sole traders" "family businesses" landlords start-ups freelancers charities contractors "professional practices")
  P_TOPIC=(Business Personal Corporate Property Startup Contractor); P_FORM=("tax planning" accounts bookkeeping advisory compliance)
  P_SOLO=(Payroll "Annual accounts" "Sales tax and VAT" "Financial forecasting")
  P_DONE=("sorted out our accounts after years of stress" "saved us a considerable amount in tax" "explained our options in plain English" "kept every deadline without reminders" "set up a bookkeeping routine that works")
  T_STATS=("Clients served|120|650" "Returns filed each year|300|1900")
}
theme_software() {
  T_KEY=software; T_INDUSTRY="software development company"; T_SCHEMA=Organization
  T_SUFFIX=(Labs Software Systems Digital Works)
  P_HADJ=(Reliable Practical Maintainable Secure Clean); P_HNOUN=("software engineering" "web development" "app development" "custom software")
  P_HTAIL=("your team can maintain" "is built to last" "ships every few weeks" "stays out of your way")
  P_WHO=("growing teams" "startups and established companies" "ambitious organizations" "product teams" "small and mid-sized businesses")
  P_PRO=(engineers "engineers and designers" developers); P_TEAM=(team group)
  P_CARE=("clean code" "honest estimates" "regular releases" "software that lasts" "keeping things simple")
  P_ACT=("build web and mobile applications" "connect your existing tools and data" "modernize legacy systems carefully" "set up reliable deployment pipelines" "review architecture and code quality" "test thoroughly before every release" "ship working software every few weeks" "monitor and maintain what we build" "document the system for your own team" "estimate the work honestly before we start" "secure applications against common attacks" "hand over clean, readable code")
  P_GOAL=("ship with confidence" "retire fragile legacy systems" "automate repetitive work" "make their data work together" "release more often with fewer surprises")
  P_OBJ=(requirements "existing systems" "technical constraints" goals deadlines "release plans")
  P_OUT=("a working first release" "a clear technical proposal" "a tested and documented system" "a realistic delivery plan" "clean, well-documented code")
  P_CLIENT=(startups "retail companies" "logistics firms" clinics schools "financial firms" agencies manufacturers)
  P_TOPIC=(Web Mobile Cloud Data Backend Frontend Cross-platform); P_FORM=(development engineering architecture testing support integration)
  P_SOLO=("API integration" "Legacy modernization" "DevOps and deployment" "Technical audits")
  P_DONE=("delivered on time with clean code" "migrated our legacy system without downtime" "built an app our customers love" "connected our tools so data flows automatically" "made our releases uneventful")
  T_STATS=("Products launched|25|130" "Integrations built|40|220")
}
theme_logistics() {
  T_KEY=logistics; T_INDUSTRY="freight and logistics company"; T_SCHEMA=Organization
  T_SUFFIX=(Logistics Freight Transport "Supply Chain" Cargo)
  P_HADJ=(Reliable Dependable Efficient Flexible Careful); P_HNOUN=(freight transport logistics "door-to-door delivery" warehousing)
  P_HTAIL=("arrives when promised" "keeps your goods moving" "is tracked from door to door" "handles the paperwork for you")
  P_WHO=("growing businesses" "importers and exporters" "manufacturers and retailers" "small and mid-sized companies" "online sellers")
  P_PRO=("logistics specialists" "freight coordinators" "transport planners"); P_TEAM=(team group)
  P_CARE=("keeping promises" "answering the phone" "reliable delivery" "clear communication" "getting goods there on time")
  P_ACT=("arrange road, sea and air freight" "handle customs clearance and paperwork" "store and pick goods in secure warehouses" "plan routes and schedules" "track every shipment" "coordinate collection and delivery" "keep you updated if anything changes" "advise on costs and carriers" "pack and label goods correctly" "book the best carrier for each load" "confirm delivery at the door" "check documents before they reach the border")
  P_GOAL=("move goods across borders" "keep delivery promises" "cut transport costs" "clear customs without delays" "ship with fewer surprises")
  P_OBJ=("delivery needs" volumes routes deadlines "shipping requirements" destinations)
  P_OUT=("a clear price for the whole journey" "tracking for every shipment" "proof of delivery sent straight to you" "a collection schedule" "complete customs documentation")
  P_CLIENT=(importers retailers manufacturers wholesalers "online sellers" "food producers" "construction firms" "furniture makers")
  P_TOPIC=(Road Sea Air Rail International Cross-border Domestic Express); P_FORM=(freight transport shipping)
  P_SOLO=("Customs clearance" Warehousing "Last-mile delivery" "Supply chain planning")
  P_DONE=("delivered everything on time" "took the customs paperwork off our hands" "told us about delays before we had to ask" "found us a cheaper route" "handled a difficult shipment calmly")
  T_STATS=("Shipments handled|900|9500" "Countries served|12|48")
}
theme_language() {
  T_KEY=language; T_INDUSTRY="translation and localization agency"; T_SCHEMA=ProfessionalService
  T_SUFFIX=(Translations Languages Linguistics "Language Services" Localization)
  P_HADJ=(Accurate Natural Careful Reliable Clear); P_HNOUN=(translation localization interpreting "language services" "technical translation")
  P_HTAIL=("sounds natural in every language" "keeps your meaning intact" "reads as if written locally" "your customers understand")
  P_WHO=("global teams" "international businesses" "law firms and manufacturers" "software companies" "importers and exporters")
  P_PRO=(linguists translators "translators and editors"); P_TEAM=(team agency)
  P_CARE=("tone as well as grammar" "getting terminology right" accuracy "meeting deadlines" "natural-sounding language")
  P_ACT=("translate documents accurately" "adapt websites for local audiences" "provide interpreters for meetings and events" "review every translation with a second linguist" "follow your preferred terminology" "deliver files in the original format" "produce certified translations" "add subtitles to videos and training material" "keep a glossary for every client" "check numbers, names and dates twice" "match the tone of the original" "work with specialists in your field")
  P_GOAL=("speak to customers in their own language" "enter new markets with confidence" "keep terminology consistent" "publish in several languages at once" "make sure nothing is lost in translation")
  P_OBJ=("source texts" terminology audience deadlines "target languages" "style preferences")
  P_OUT=("finished files in the original format" "a consistent glossary of terms" "a translation reviewed by a second linguist" "certified documents ready to submit" "a localized version ready to publish")
  P_CLIENT=("law firms" manufacturers "software companies" charities hospitals "travel companies" universities "online retailers")
  P_TOPIC=(Legal Medical Technical Website Marketing Financial Software); P_FORM=(translation localization proofreading review)
  P_SOLO=(Interpreting Subtitling "Certified translation" Transcription)
  P_DONE=("caught an error in our source text that nobody else noticed" "made our manuals consistent across every market" "delivered fast without cutting corners" "adapted our website so it feels local" "handled our legal translations without a single query")
  T_STATS=("Projects completed|300|2600" "Linguists in our network|40|220")
}
THEMES=(consulting design architecture accounting software logistics language)
pick THEMES; "theme_$R"

# ---------- страны: ISO → Название|Формы|lang|og:locale|орфография|дата|стиль улиц ----------
declare -A CINFO=(
 [US]="United States|LLC,Inc.,Corp.|en-US|en_US|us|mdy|en"
 [CA]="Canada|Inc.,Ltd.,Corp.|en-CA|en_CA|us|mdy|en"
 [GB]="United Kingdom|Ltd,LLP|en-GB|en_GB|uk|dmy|en"
 [IE]="Ireland|Ltd,DAC|en-IE|en_IE|uk|dmy|en"
 [NL]="Netherlands|B.V.,V.O.F.|en|en_GB|uk|dmy|nl"
 [SG]="Singapore|Pte. Ltd.|en-SG|en_SG|uk|dmy|en"
 [AU]="Australia|Pty Ltd|en-AU|en_AU|uk|dmy|en"
 [NZ]="New Zealand|Ltd|en-NZ|en_NZ|uk|dmy|en"
)
COUNTRY_ISOS=(US CA GB IE NL SG AU NZ)

# ---------- города: Город|Регион|ISO|Телефон|Индекс ----------
# N — цифра, L — буква, P — буква для канадских индексов, строчная буква — как есть.
# Диапазоны номеров — вымышленные (555-01xx, Ofcom drama и т. п.).
CITIES=(
 "Austin|TX|US|+1 512 555 01NN|787NN"
 "Denver|CO|US|+1 303 555 01NN|802NN"
 "Seattle|WA|US|+1 206 555 01NN|981NN"
 "Boston|MA|US|+1 617 555 01NN|021NN"
 "Chicago|IL|US|+1 312 555 01NN|606NN"
 "Atlanta|GA|US|+1 404 555 01NN|303NN"
 "Portland|OR|US|+1 503 555 01NN|972NN"
 "Miami|FL|US|+1 305 555 01NN|331NN"
 "Raleigh|NC|US|+1 919 555 01NN|276NN"
 "Minneapolis|MN|US|+1 612 555 01NN|554NN"
 "Nashville|TN|US|+1 615 555 01NN|372NN"
 "Phoenix|AZ|US|+1 602 555 01NN|850NN"
 "Toronto|ON|CA|+1 416 555 01NN|mNP NPN"
 "Vancouver|BC|CA|+1 604 555 01NN|vNP NPN"
 "Montreal|QC|CA|+1 514 555 01NN|hNP NPN"
 "Calgary|AB|CA|+1 403 555 01NN|tNP NPN"
 "Ottawa|ON|CA|+1 613 555 01NN|kNP NPN"
 "Edmonton|AB|CA|+1 780 555 01NN|tNP NPN"
 "Winnipeg|MB|CA|+1 204 555 01NN|rNP NPN"
 "Halifax|NS|CA|+1 902 555 01NN|bNP NPN"
 "London||GB|+44 20 7946 0NNN|swN NLL"
 "Manchester||GB|+44 161 496 0NNN|mN NLL"
 "Birmingham||GB|+44 121 496 0NNN|bN NLL"
 "Leeds||GB|+44 113 496 0NNN|lsN NLL"
 "Glasgow||GB|+44 141 496 0NNN|gN NLL"
 "Edinburgh||GB|+44 131 496 0NNN|ehN NLL"
 "Bristol||GB|+44 117 496 0NNN|bsN NLL"
 "Cardiff||GB|+44 29 2018 0NNN|cfNN NLL"
 "Sheffield||GB|+44 114 496 0NNN|sN NLL"
 "Liverpool||GB|+44 151 496 0NNN|lN NLL"
 "Dublin||IE|+353 1 5NN NNNN|d0N LNNN"
 "Cork||IE|+353 21 5NN NNNN|t12 LNNN"
 "Galway||IE|+353 91 5NN NNNN|h91 LNNN"
 "Limerick||IE|+353 61 5NN NNNN|v94 LNNN"
 "Waterford||IE|+353 51 5NN NNNN|x91 LNNN"
 "Amsterdam||NL|+31 20 5NN NNNN|10NN LL"
 "Rotterdam||NL|+31 10 5NN NNNN|30NN LL"
 "Utrecht||NL|+31 30 5NN NNNN|35NN LL"
 "The Hague||NL|+31 70 5NN NNNN|25NN LL"
 "Eindhoven||NL|+31 40 5NN NNNN|56NN LL"
 "Groningen||NL|+31 50 5NN NNNN|97NN LL"
 "Singapore||SG|+65 6NNN NNNN|0NNNNN"
 "Melbourne|VIC|AU|+61 3 5550 NNNN|30NN"
 "Sydney|NSW|AU|+61 2 5550 NNNN|20NN"
 "Brisbane|QLD|AU|+61 7 5550 NNNN|40NN"
 "Perth|WA|AU|+61 8 5550 NNNN|60NN"
 "Adelaide|SA|AU|+61 8 5550 NNNN|50NN"
 "Canberra|ACT|AU|+61 2 5550 NNNN|26NN"
 "Auckland||NZ|+64 9 5NN NNNN|1NNN"
 "Wellington||NZ|+64 4 5NN NNNN|6NNN"
 "Christchurch||NZ|+64 3 5NN NNNN|8NNN"
)

# ---------- страна → город → телефон/индекс/орфография ----------
pick COUNTRY_ISOS; ISO="$R"
CITY_ROWS=()
for _row in "${CITIES[@]}"; do
    case "$_row" in *"|$ISO|"*) CITY_ROWS+=("$_row") ;; esac
done
pick CITY_ROWS
IFS='|' read -r CITY REGION _iso PHONE_FMT POST_FMT <<< "$R"
IFS='|' read -r COUNTRY LEGALS LANG_CODE OG_LOCALE SPELL DATE_STYLE STREET_STYLE <<< "${CINFO[$ISO]}"
IFS=',' read -ra LEGAL_LIST <<< "$LEGALS"
pick LEGAL_LIST; LEGAL="$R"
if [ "${LEGAL: -1}" = "." ]; then LEGAL_DOT=""; else LEGAL_DOT="."; fi
case "$ISO" in GB|US|NL) COUNTRY_THE="the $COUNTRY" ;; *) COUNTRY_THE="$COUNTRY" ;; esac
fmt_fill "$PHONE_FMT"; PHONE="$R"
fmt_fill "$POST_FMT";  POST="$R"

# ---------- движок текста ----------
declare -A QI=()
# Берёт слово из словаря P_<имя> «колодой»: повторов нет, пока колода не кончится
pick_q() {
    local n="$1" i
    declare -ga "Q_$n"
    local -n _qs="P_$n" _qq="Q_$n"
    if [ "${#_qs[@]}" -eq 0 ]; then R=""; return 0; fi
    i="${QI[$n]:-}"
    if [ -z "$i" ] || [ "$i" -ge "${#_qq[@]}" ]; then
        _qq=("${_qs[@]}"); shuffle _qq; i=0
    fi
    R="${_qq[$i]}"
    QI[$n]=$(( i + 1 ))
}
# a/an по первой букве следующего слова
fix_art() {
    local -a w; local i nx
    read -ra w <<< "$1"
    for (( i=0; i<${#w[@]}-1; i++ )); do
        case "${w[i]}" in
            a|A)
                nx="${w[i+1],,}"
                case "$nx" in
                    one*|use*|uni*|eu*) ;;
                    hour*|honest*|honour*) w[i]="${w[i]}n" ;;
                    [aeiou]*) w[i]="${w[i]}n" ;;
                esac ;;
        esac
    done
    R="${w[*]}"
}
UK_MAP=("organization:organisation" "organized:organised" "organize:organise" "color:colour" "Localization:Localisation" "localization:localisation" "localized:localised" "modernization:modernisation" "modernize:modernise" "prioritized:prioritised" "specialized:specialised" "customized:customised" "analyze:analyse" "Harbor:Harbour")
spell_str() {
    local s="$1" p
    if [ "$SPELL" = uk ]; then
        for p in "${UK_MAP[@]}"; do s="${s//${p%%:*}/${p##*:}}"; done
    fi
    R="$s"
}
# Подставляет @TOKEN@ (и @TOKEN2@, @TOKEN3@) словами из P_TOKEN, затем чинит a/an и орфографию
expand() {
    local t="$1" tok base
    while [[ "$t" =~ @([A-Z]+)([0-9]*)@ ]]; do
        tok="${BASH_REMATCH[0]}"; base="${BASH_REMATCH[1]}"
        pick_q "$base"
        t="${t/"$tok"/"$R"}"
    done
    fix_art "$t"; spell_str "$R"
}
gen() { pick "$1"; expand "$R"; R="${R^}"; }   # случайный шаблон из массива → текст

# ---------- имена ----------
gen_surname() {
    local a
    pick SN_STEM; a="$R"; pick SN_END
    if [ "${a: -1}" = "${R:0:1}" ]; then R="${R:1}"; fi
    R="${a}${R}"
}
gen_brand() {
    local s v
    pick BR_ON; s="$R"; pick BR_VO; s+="$R"
    pick BR_ON; s+="$R"; pick BR_VO; s+="$R"
    chance 55
    if [ "$R" -eq 1 ]; then pick BR_EN; else pick BR_CO; fi
    s+="$R"
    R="${s^}"
}
gen_org() {
    local a
    rnd 0 2
    case "$R" in
        0) gen_brand; a="$R" ;;
        1) pick PRE; a="$R"; pick POST; a="${a}${R}" ;;
        *) gen_surname; a="$R" ;;
    esac
    pick ORG_NOUN; R="$a $R"
}

# ---------- адрес и часы ----------
gen_address() {
    local num stem typ unit="" k
    rnd 3 240; num="$R"
    if [ "$STREET_STYLE" = nl ]; then
        pick NL_STEM; stem="$R"; pick NL_SUF
        ADDR1="${stem}${R} ${num}"
        return 0
    fi
    chance 55
    if [ "$R" -eq 1 ]; then pick ST_STEM; else gen_surname; fi
    stem="$R"; pick ST_TYPE; typ="$R"
    chance 45
    if [ "$R" -eq 1 ]; then
        if [ "$ISO" = SG ]; then
            fmt_fill "#NN-NN"; unit="$R"
        else
            rnd 0 2
            if [ "$R" -eq 0 ]; then
                rnd 1 4; k="$R"
                case "$k" in 1) unit="1st Floor" ;; 2) unit="2nd Floor" ;; 3) unit="3rd Floor" ;; *) unit="4th Floor" ;; esac
            else
                pick UNIT_KIND; rnd 1 9; unit="$R"
                pick UNIT_KIND; unit="$R $unit"
            fi
        fi
    fi
    if [ -n "$unit" ]; then ADDR1="${unit}, ${num} ${stem} ${typ}"; else ADDR1="${num} ${stem} ${typ}"; fi
}
gen_hours() {
    local d oh om ch cm
    pick HR_DAYS; d="$R"
    rnd 8 9; oh="$R"; pick HR_MIN; om="$R"
    rnd 16 18; ch="$R"; pick HR_MIN; cm="$R"
    case "$ISO" in
        US|CA|AU|NZ) OPEN_HOURS="${d}, ${oh}:${om} AM – $((ch - 12)):${cm} PM" ;;
        *)           OPEN_HOURS="${d}, ${oh}:${om}–${ch}:${cm}" ;;
    esac
}

# ---------- орфография для тематических полей ----------
spell_str "$T_INDUSTRY"; T_INDUSTRY="$R"
for _i in "${!T_SUFFIX[@]}"; do spell_str "${T_SUFFIX[_i]}"; T_SUFFIX[_i]="$R"; done

# ---------- название компании ----------
pick T_SUFFIX; SUF="$R"
gen_surname; S1="$R"; gen_surname; S2="$R"
while [ "$S2" = "$S1" ]; do gen_surname; S2="$R"; done
chance 60
if [ "$R" -eq 1 ]; then pick WORDS; else gen_brand; fi
W1="$R"
pick PRE; P1="$R"; pick POST; P2="$R"
# Основа названия — левая «значимая» метка домена (rescorp.norest.art → Rescorp);
# варианты: «Rescorp Consulting» (суффикс темы), «Rescorp Group», «Rescorp & Co.», «Rescorp».
# HONEYPOT_RANDOM_NAME=1 — вернуть полностью случайные названия.
BRAND_GENERIC=(www mail smtp imap pop ftp vpn panel admin app api web cdn static portal login secure sub new old test dev stage)
BRAND_TAILS=(Group Partners Holdings Associates Collective Works)
domain_brand() {   # → R = «Rescorp» (или пусто, если подходящей метки нет)
    local -a labels; local i n l w out=""
    IFS='.' read -ra labels <<< "$DOMAIN"
    n=$(( ${#labels[@]} - 1 ))          # последняя метка — TLD
    for (( i=0; i<n; i++ )); do
        l="${labels[i]}"
        if [ "${#l}" -lt 3 ]; then continue; fi
        case " ${BRAND_GENERIC[*]} " in *" $l "*) continue ;; esac
        for w in ${l//-/ }; do out+="${out:+ }${w^}"; done
        break
    done
    R="$out"
}
BRAND=""
if [ "${HONEYPOT_RANDOM_NAME:-0}" != "1" ]; then domain_brand; BRAND="$R"; fi
pick BRAND_TAILS; TAIL="$R"
if [ -n "$BRAND" ]; then
    rnd 0 4
    case "$R" in
        0|1) COMPANY="$BRAND $SUF" ;;
        2|4) COMPANY="$BRAND $TAIL" ;;
        *)   COMPANY="$BRAND" ;;
    esac
else
rnd 0 4
case "$R" in
    0) COMPANY="$S1 & $S2"
       chance 50
       if [ "$R" -eq 1 ] && [ "${SUF:0:1}" != "&" ]; then COMPANY="$COMPANY $SUF"; fi ;;
    1) COMPANY="$W1 $SUF" ;;
    2) COMPANY="$S1 $SUF" ;;
    3) COMPANY="${P1}${P2}"
       chance 70
       if [ "$R" -eq 1 ]; then COMPANY="$COMPANY $SUF"; fi ;;
    4) COMPANY="$W1"
       chance 80
       if [ "$R" -eq 1 ]; then COMPANY="$COMPANY $SUF"; fi ;;
esac
fi
html_esc "$COMPANY"; COMPANY_H="$R"
INITIAL="${COMPANY:0:1}"

# ---------- прочие случайные значения ----------
rnd 2004 $((CUR_YEAR - 3)); YEAR="$R"
pick EMAIL_LOCALS; EMAIL="${R}@${DOMAIN}"
gen_hours
gen_address
if [ "$STREET_STYLE" = nl ]; then
    ADDR2="${POST} ${CITY}"
elif [ -n "$REGION" ]; then
    ADDR2="${CITY}, ${REGION} ${POST}"
else
    ADDR2="${CITY} ${POST}"
fi
REGION_JSON=""
if [ -n "$REGION" ]; then REGION_JSON="\"addressRegion\":\"${REGION}\","; fi

# ---------- тексты из шаблонов ----------
P_YEAR=("$YEAR"); P_CITY=("$CITY"); P_COUNTRYTHE=("$COUNTRY_THE")

gen HERO_TPL; HERO="$R"
HERO_HEAD="${HERO% *}"; HERO_LAST="${HERO##* }"
gen TAG_TPL;  TAGLINE="$R"
gen LEAD_TPL; LEAD="$R"

# услуги: «тема + форма» или самостоятельное название, описание по шаблону
gen_services() {
    local n="$1" i tries title t d used="|"
    SV=()
    for (( i=0; i<n; i++ )); do
        tries=0
        while :; do
            chance 28
            if [ "$R" -eq 1 ]; then
                pick P_SOLO; title="$R"; t="$R"
            else
                pick P_TOPIC; t="$R"; pick P_FORM; title="$t $R"
            fi
            tries=$(( tries + 1 ))
            case "$used" in
                *"|$title|"*|*"|t:$t|"*) if [ "$tries" -lt 15 ]; then continue; fi ;;
            esac
            break
        done
        used+="$title|t:$t|"
        spell_str "$title"; title="$R"
        pick_q SVCTPL; expand "$R"; d="${R^}"
        SV+=("$title|$d")
    done
}
rnd 0 2
case "$R" in 0) NSV=3 ;; 1) NSV=4 ;; 2) NSV=6 ;; esac
gen_services "$NSV"
SVC1="${SV[0]%%|*}"; SVC2="${SV[1]%%|*}"; SVC3="${SV[2]%%|*}"

# «о нас»
gen AS_ID; A1="$R"
pick AS_WORK; W_A="$R"; expand "$W_A"; A1+=" ${R^}"
gen AS_CL; A2="$R"
pick AS_WORK; while [ "$R" = "$W_A" ]; do pick AS_WORK; done
expand "$R"; A2+=" ${R^}"
T_ABOUT=("$A1" "$A2")
gen ABOUT_LOC_TPL; ABOUT3="$R"

# процесс из четырёх этапов
T_PROC=()
for _k in 1 2 3 4; do
    pick "P_ST$_k"; _nm="$R"
    gen "PT_S$_k"
    T_PROC+=("$_nm|$R")
done

# ценности
VU=("${VALUES[@]}"); shuffle VU
VS=()
for _u in "${VU[@]:0:3}"; do
    IFS='|' read -ra _vp <<< "$_u"
    _vt="${_vp[0]}"; _vp=("${_vp[@]:1}"); shuffle _vp
    VS+=("$_vt|We ${_vp[0]} and ${_vp[1]}.")
done

# отзывы (имена и организации добавляются при сборке секции)
T_QUOTES=()
for _qt in "${QT_TPL[@]}"; do expand "$_qt"; T_QUOTES+=("${R^}"); done

# заголовки и подписи
pick H_ABOUT; HT_ABOUT="$R"
pick H_SVC; HT_SVC="$R"
pick H_PROC; HT_PROC="$R"
pick H_QUOTES; HT_QUOTES="$R"
pick H_CONTACT; HT_CONTACT="$R"
gen SUBSVC_TPL;  ST_SVC="$R"
gen SUBPROC_TPL; ST_PROC="$R"
gen SUBQ_TPL;    ST_QUOTES="$R"
gen SUBC_TPL;    ST_CONTACT="$R"
pick CTA_NAV; BTN_NAV="$R"
pick CTA_HERO1; BTN_HERO1="$R"
pick CTA_HERO2; BTN_HERO2="$R"

case "${T_INDUSTRY:0:1}" in a|e|i|o|u) ARTICLE="an" ;; *) ARTICLE="a" ;; esac
EYEBROWS=("${CITY}, ${COUNTRY}" "${T_INDUSTRY^}" "Est. ${YEAR}" "Independent since ${YEAR}" "${T_INDUSTRY^} in ${CITY}")
pick EYEBROWS; EYEBROW="$R"

# ---------- метаданные ----------
rnd 0 4
case "$R" in
    0) TITLE="${COMPANY} | ${T_INDUSTRY^} in ${CITY}" ;;
    1) TITLE="${COMPANY} — ${SVC1}, ${SVC2}" ;;
    2) TITLE="${COMPANY} · ${T_INDUSTRY^}" ;;
    3) TITLE="${SVC1} in ${CITY} | ${COMPANY}" ;;
    4) TITLE="${COMPANY} — ${TAGLINE%.}" ;;
esac
rnd 0 2
case "$R" in
    0) META_DESC="${COMPANY} — ${T_INDUSTRY} in ${CITY}. ${TAGLINE}" ;;
    1) META_DESC="${COMPANY} is ${ARTICLE} ${T_INDUSTRY} based in ${CITY}. We offer ${SVC1,,}, ${SVC2,,} and ${SVC3,,}." ;;
    2) META_DESC="${TAGLINE} ${COMPANY} offers ${SVC1,,} and ${SVC2,,} for clients in ${CITY} and beyond." ;;
esac
html_esc "$TITLE"; TITLE_H="$R"
html_esc "$META_DESC"; META_DESC_H="$R"

KW_TAG=""
chance 40
if [ "$R" -eq 1 ]; then
    KW_TAG="<meta name=\"keywords\" content=\"${T_INDUSTRY}, ${SVC1,,}, ${SVC2,,}, ${SVC3,,}, ${CITY}\">"
fi
TW_TAG=""
chance 65
if [ "$R" -eq 1 ]; then TW_TAG="1"; fi

JSONLD="<script type=\"application/ld+json\">
{\"@context\":\"https://schema.org\",\"@type\":\"${T_SCHEMA}\",\"name\":\"${COMPANY}\",\"url\":\"https://${DOMAIN}/\",\"description\":\"${META_DESC}\",\"email\":\"${EMAIL}\",\"telephone\":\"${PHONE}\",\"foundingDate\":\"${YEAR}\",\"address\":{\"@type\":\"PostalAddress\",\"streetAddress\":\"${ADDR1}\",${REGION_JSON}\"addressLocality\":\"${CITY}\",\"postalCode\":\"${POST}\",\"addressCountry\":\"${ISO}\"}}
</script>"

# ============================================================
#  ДИЗАЙН
# ============================================================
LAYOUTS=(a b c d);           pick LAYOUTS;  LAYOUT="$R"
BGS=(grad mesh grid dots noise stripes solid anim); pick BGS; BG_KIND="$R"
CARDS=(flat outline shadow glass accent);           pick CARDS; CARD="$R"
SVCS=(grid list cols);       pick SVCS; SVC_STYLE="$R"

rnd 0 359; H="$R"
rnd 0 3
case "$R" in
    0) H2=$(( (H + 30) % 360 )) ;;
    1) H2=$(( (H + 150) % 360 )) ;;
    2) H2=$(( (H + 180) % 360 )) ;;
    3) H2=$(( (H + 210) % 360 )) ;;
esac
rnd 55 85; SAT="$R"
chance 55
if [ "$R" -eq 1 ]; then MODE=dark; else MODE=light; fi

if [ "$MODE" = dark ]; then
    rnd 8 14; BGL="$R"; rnd 18 40; BGS_="$R"; rnd 58 68; AL="$R"
    BG="hsl($H,${BGS_}%,${BGL}%)"; BG2="hsl($H,${BGS_}%,$((BGL + 6))%)"
    SURFACE="hsla(0,0%,100%,.05)"; GLASS="hsla(0,0%,100%,.07)"
    TEXT="hsl($H,15%,93%)"; MUTED="hsl($H,10%,70%)"
    ACCENT="hsl($H,${SAT}%,${AL}%)"; ACCENT2="hsl($H2,${SAT}%,${AL}%)"
    ON_ACC="hsl($H,40%,10%)"; ON_HEX="$(hsl2hex "$H" 40 10)"
    GLOW="hsla($H,${SAT}%,${AL}%,.22)"; GLOW2="hsla($H2,${SAT}%,${AL}%,.2)"
    BORDER="hsla(0,0%,100%,.1)"; BORDER_S="hsla(0,0%,100%,.22)"
    LINE="hsla(0,0%,100%,.045)"; LINE2="hsla(0,0%,100%,.12)"
    HDR="hsla($H,${BGS_}%,${BGL}%,.8)"
    SHADOW="0 10px 30px rgba(0,0,0,.35)"; SHADOW_C="rgba(0,0,0,.4)"
else
    rnd 95 98; BGL="$R"; rnd 20 45; BGS_="$R"; rnd 34 44; AL="$R"
    BG="hsl($H,${BGS_}%,${BGL}%)"; BG2="hsl($H,${BGS_}%,$((BGL - 5))%)"
    SURFACE="hsla(0,0%,100%,.85)"; GLASS="hsla(0,0%,100%,.6)"
    TEXT="hsl($H,30%,13%)"; MUTED="hsl($H,12%,38%)"
    ACCENT="hsl($H,${SAT}%,${AL}%)"; ACCENT2="hsl($H2,${SAT}%,${AL}%)"
    ON_ACC="#ffffff"; ON_HEX="#ffffff"
    GLOW="hsla($H,${SAT}%,${AL}%,.18)"; GLOW2="hsla($H2,${SAT}%,${AL}%,.16)"
    BORDER="hsla($H,30%,20%,.12)"; BORDER_S="hsla($H,30%,20%,.28)"
    LINE="hsla($H,30%,30%,.07)"; LINE2="hsla($H,30%,30%,.16)"
    HDR="hsla(0,0%,100%,.82)"
    SHADOW="0 10px 30px hsla($H,40%,20%,.12)"; SHADOW_C="hsla($H,40%,20%,.2)"
fi
THEME_HEX="$(hsl2hex "$H" "$BGS_" "$BGL")"
ACC_HEX="$(hsl2hex "$H" "$SAT" "$AL")"

RADII=(0px 4px 8px 12px 18px 24px);  pick RADII; RADIUS="$R"
BTN_RADII=(0px 6px 12px 999px);      pick BTN_RADII; BTN_RADIUS="$R"
MAXWS=(980 1040 1120 1200);          pick MAXWS; MAXW="$R"
SPACES=(72 88 104 120);              pick SPACES; SPACE="$R"
FSS=(16 17 18);                      pick FSS; FS="$R"
HWS=(400 500 600 700 800);           pick HWS; HW="$R"
HSPS=("-0.02em" "-0.01em" "0" "0.01em"); pick HSPS; HSP="$R"
chance 12
if [ "$R" -eq 1 ]; then HTR="uppercase"; HSP="0.06em"; else HTR="none"; fi

FONT_PAIRS=(
 "Georgia, 'Times New Roman', serif|-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"
 "'Palatino Linotype', Palatino, 'Book Antiqua', Georgia, serif|Georgia, 'Times New Roman', serif"
 "'Trebuchet MS', 'Lucida Grande', 'Segoe UI', sans-serif|'Segoe UI', Tahoma, Geneva, Verdana, sans-serif"
 "'Helvetica Neue', Helvetica, Arial, sans-serif|'Helvetica Neue', Helvetica, Arial, sans-serif"
 "Verdana, Geneva, sans-serif|Verdana, Geneva, sans-serif"
 "'Courier New', Courier, monospace|-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Arial, sans-serif"
 "'Gill Sans', 'Gill Sans MT', Calibri, 'Trebuchet MS', sans-serif|'Gill Sans', 'Gill Sans MT', Calibri, sans-serif"
 "ui-serif, Georgia, Cambria, serif|ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif"
)
while :; do
    pick FONT_PAIRS; FP="$R"
    case "$FP" in
        "'Courier New'"*) if [ "$T_KEY" != software ]; then continue; fi ;;
    esac
    break
done
FONT_H="${FP%%|*}"; FONT_B="${FP##*|}"

FX=""
chance 55; if [ "$R" -eq 1 ]; then FX+=" fx-lift"; fi
chance 50; if [ "$R" -eq 1 ]; then FX+=" fx-grad"; fi
chance 45; if [ "$R" -eq 1 ]; then FX+=" fx-glow"; fi
chance 60; if [ "$R" -eq 1 ]; then REV=" reveal"; else REV=""; fi
BODY_CLASS="l-${LAYOUT} bg-${BG_KIND} card-${CARD} svc-${SVC_STYLE}${FX}"

# ---------- логотип / favicon ----------
rnd 0 4; MARK_SHAPE="$R"
mark_svg() {    # $1 = заливка фигуры, $2 = цвет буквы  ->  MARK_INNER
    local shape
    case "$MARK_SHAPE" in
        0) shape="<circle cx=\"16\" cy=\"16\" r=\"16\" fill=\"$1\"/>" ;;
        1) shape="<rect width=\"32\" height=\"32\" rx=\"7\" fill=\"$1\"/>" ;;
        2) shape="<path d=\"M16 0 32 16 16 32 0 16Z\" fill=\"$1\"/>" ;;
        3) shape="<rect width=\"32\" height=\"32\" fill=\"$1\"/>" ;;
        4) shape="<path d=\"M8 2h16l8 14-8 14H8L0 16z\" fill=\"$1\"/>" ;;
    esac
    MARK_INNER="${shape}<text x=\"16\" y=\"21.5\" text-anchor=\"middle\" font-family=\"Georgia, serif\" font-size=\"16\" font-weight=\"700\" fill=\"$2\">${INITIAL}</text>"
}
mark_svg "var(--accent)" "var(--on-accent)"
MARK_HTML="<svg class=\"mark\" viewBox=\"0 0 32 32\" aria-hidden=\"true\">${MARK_INNER}</svg>"
mark_svg "$ACC_HEX" "$ON_HEX"
FAVICON_SVG="<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 32 32\">${MARK_INNER}</svg>"

# ---------- абстрактная иллюстрация для hero (layout b) ----------
make_art() {
    local n i t cx cy r op rot col x2 y2 o
    ART="<svg viewBox=\"0 0 400 400\" xmlns=\"http://www.w3.org/2000/svg\" role=\"presentation\">"
    rnd 6 9; n="$R"
    for (( i=0; i<n; i++ )); do
        rnd 0 3; t="$R"
        rnd 40 360; cx="$R"; rnd 40 360; cy="$R"; rnd 24 90; r="$R"; rnd 12 70; op="$R"
        if (( RANDOM % 2 )); then col="var(--accent)"; else col="var(--accent2)"; fi
        printf -v o '%02d' "$op"
        case "$t" in
            0) ART+="<circle cx=\"$cx\" cy=\"$cy\" r=\"$r\" fill=\"$col\" opacity=\"0.$o\"/>" ;;
            1) rnd 0 90; rot="$R"
               ART+="<rect x=\"$((cx - r))\" y=\"$((cy - r))\" width=\"$((r * 2))\" height=\"$((r * 2))\" rx=\"$((r / 4))\" fill=\"$col\" opacity=\"0.$o\" transform=\"rotate($rot $cx $cy)\"/>" ;;
            2) printf -v o '%02d' "$((op + 25))"
               ART+="<circle cx=\"$cx\" cy=\"$cy\" r=\"$r\" fill=\"none\" stroke=\"$col\" stroke-width=\"3\" opacity=\"0.$o\"/>" ;;
            3) x2=$(( cx - 120 + RANDOM % 241 )); y2=$(( cy - 120 + RANDOM % 241 ))
               printf -v o '%02d' "$((op + 25))"
               ART+="<line x1=\"$cx\" y1=\"$cy\" x2=\"$x2\" y2=\"$y2\" stroke=\"$col\" stroke-width=\"4\" stroke-linecap=\"round\" opacity=\"0.$o\"/>" ;;
        esac
    done
    ART+="</svg>"
}
HERO_ART_HTML=""
if [ "$LAYOUT" = "b" ]; then
    make_art
    HERO_ART_HTML="<div class=\"hero-art\" aria-hidden=\"true\">${ART}</div>"
fi

# ---------- порядок секций и навигация ----------
MID=(process quotes stats); shuffle MID
chance 50
if [ "$R" -eq 1 ]; then ORDER=(about services); else ORDER=(services about); fi
for s in "${MID[@]}"; do
    chance 65
    if [ "$R" -eq 1 ]; then ORDER+=("$s"); fi
done
if [ "${#ORDER[@]}" -eq 2 ]; then ORDER+=("${MID[0]}"); fi
ORDER+=(contact)

NAV_HTML=""
for s in "${ORDER[@]}"; do
    case "$s" in
        about)    NAV_HTML+="<a href=\"/#about\">About</a>"$'\n' ;;
        services) NAV_HTML+="<a href=\"/#services\">Services</a>"$'\n' ;;
        process)  NAV_HTML+="<a href=\"/#process\">Process</a>"$'\n' ;;
        quotes)   NAV_HTML+="<a href=\"/#clients\">Clients</a>"$'\n' ;;
        contact)  NAV_HTML+="<a href=\"/#contact\">Contact</a>"$'\n' ;;
    esac
done
NAV_HTML+="<a class=\"btn btn-sm\" href=\"/#contact\">${BTN_NAV}</a>"

# ---------- даты ----------
rnd 10 60; LASTMOD_AGO="$R"
LASTMOD="$(date -d "${LASTMOD_AGO} days ago" +%Y-%m-%d)"
case "$DATE_STYLE" in
    mdy) UPD_DATE="$(date -d "${LASTMOD_AGO} days ago" +"%B %-d, %Y")" ;;
    *)     UPD_DATE="$(date -d "${LASTMOD_AGO} days ago" +"%-d %B %Y")" ;;
esac
rnd 0 1
if [ "$R" -eq 0 ]; then FOOT_YEARS="${YEAR}–${CUR_YEAR}"; else FOOT_YEARS="${CUR_YEAR}"; fi
chance 40; if [ "$R" -eq 1 ]; then FOOT_EXTRA=" Registered in ${COUNTRY_THE}."; else FOOT_EXTRA=""; fi

# ---------- имена файлов ----------
ASSET_DIRS=(assets static res); pick ASSET_DIRS; ASSETS="$R"
CSS_NAMES=(style.css main.css site.css); pick CSS_NAMES; CSS_NAME="$R"
JS_NAMES=(main.js site.js app.js); pick JS_NAMES; JS_NAME="$R"

# ============================================================
#  ФУНКЦИИ РАЗМЕТКИ
# ============================================================
emit_head() {   # $1 title  $2 description  $3 path  $4 robots  $5 extra-head
    local og_tw=""
    if [ -n "$TW_TAG" ]; then
        og_tw="<meta name=\"twitter:card\" content=\"summary\">
<meta name=\"twitter:title\" content=\"$1\">
<meta name=\"twitter:description\" content=\"$2\">"
    fi
    local kw=""
    if [ "$3" = "/" ]; then kw="$KW_TAG"; fi
    cat <<HEAD
<!DOCTYPE html>
<html lang="${LANG_CODE}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$1</title>
<meta name="description" content="$2">
${kw}
<meta name="robots" content="$4">
<meta name="theme-color" content="${THEME_HEX}">
<link rel="canonical" href="https://${DOMAIN}$3">
<meta property="og:type" content="website">
<meta property="og:site_name" content="${COMPANY_H}">
<meta property="og:title" content="$1">
<meta property="og:description" content="$2">
<meta property="og:url" content="https://${DOMAIN}$3">
<meta property="og:locale" content="${OG_LOCALE}">
${og_tw}
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<link rel="stylesheet" href="/${ASSETS}/${CSS_NAME}">
<script src="/${ASSETS}/${JS_NAME}"></script>
$5
</head>
HEAD
}

emit_header() {
    cat <<HDR
<body class="${BODY_CLASS}">
<a class="skip" href="#main">Skip to content</a>
<header class="site-header">
<div class="wrap bar">
<a class="brand" href="/">${MARK_HTML}<span>${COMPANY_H}</span></a>
<button class="nav-toggle" type="button" aria-label="Menu" aria-expanded="false"><span></span></button>
<nav class="nav" aria-label="Main">
${NAV_HTML}
</nav>
</div>
</header>
<main id="main">
HDR
}

emit_footer() {
    cat <<FTR
</main>
<footer class="site-footer">
<div class="wrap foot">
<span>&copy; ${FOOT_YEARS} ${COMPANY_H} ${LEGAL}${LEGAL_DOT} All rights reserved.${FOOT_EXTRA}</span>
<span><a href="/privacy.html">Privacy policy</a></span>
</div>
</footer>
</body>
</html>
FTR
}

sec_hero() {
    cat <<SEC
<section class="hero">
<div class="wrap hero-grid">
<div class="hero-copy">
<span class="eyebrow">${EYEBROW}</span>
<h1>${HERO_HEAD} <span class="g">${HERO_LAST}</span></h1>
<p class="lead">${LEAD}</p>
<div class="actions">
<a class="btn" href="/#contact">${BTN_HERO1}</a>
<a class="btn btn-ghost" href="/#services">${BTN_HERO2}</a>
</div>
</div>
${HERO_ART_HTML}
</div>
</section>
SEC
}

sec_about() {
    local v li=""
    for v in "${VS[@]}"; do
        li+="<li><strong>${v%%|*}</strong><span>${v##*|}</span></li>"$'\n'
    done
    cat <<SEC
<section id="about" class="section${REV}">
<div class="wrap">
<div class="section-head"><h2>${HT_ABOUT}</h2></div>
<div class="about-grid">
<div class="about-text">
<p>${T_ABOUT[0]}</p>
<p>${T_ABOUT[1]}</p>
<p>${ABOUT3}</p>
</div>
<ul class="values">
${li}</ul>
</div>
</div>
</section>
SEC
}

sec_services() {
    local i=0 s cards=""
    for s in "${SV[@]}"; do
        i=$((i + 1))
        cards+="<article class=\"card\"><span class=\"num\">$(printf '%02d' "$i")</span><h3>${s%%|*}</h3><p>${s##*|}</p></article>"$'\n'
    done
    cat <<SEC
<section id="services" class="section${REV}">
<div class="wrap">
<div class="section-head"><h2>${HT_SVC}</h2><p class="sub">${ST_SVC}</p></div>
<div class="cards">
${cards}</div>
</div>
</section>
SEC
}

sec_stats() {
    local a b lab1 min1 max1 lab2 min2 max2 n1 n2 plus="" yl
    IFS='|' read -r lab1 min1 max1 <<< "${T_STATS[0]}"
    IFS='|' read -r lab2 min2 max2 <<< "${T_STATS[1]}"
    rnd "$min1" "$max1"; n1="$R"
    rnd "$min2" "$max2"; n2="$R"
    chance 60; if [ "$R" -eq 1 ]; then plus="+"; fi
    rnd 0 1; if [ "$R" -eq 0 ]; then yl="Years in business"; else yl="Years of experience"; fi
    cat <<SEC
<section class="section band${REV}">
<div class="wrap">
<div class="stats">
<div class="stat"><b>$((CUR_YEAR - YEAR))${plus}</b><span>${yl}</span></div>
<div class="stat"><b>${n1}${plus}</b><span>${lab1}</span></div>
<div class="stat"><b>${n2}${plus}</b><span>${lab2}</span></div>
</div>
</div>
</section>
SEC
}

sec_process() {
    local p items=""
    for p in "${T_PROC[@]}"; do
        items+="<li class=\"step\"><h3>${p%%|*}</h3><p>${p##*|}</p></li>"$'\n'
    done
    cat <<SEC
<section id="process" class="section${REV}">
<div class="wrap">
<div class="section-head"><h2>${HT_PROC}</h2><p class="sub">${ST_PROC}</p></div>
<ol class="steps">
${items}</ol>
</div>
</section>
SEC
}

sec_quotes() {
    local QS=("${T_QUOTES[@]}") q out="" f l o r n
    shuffle QS
    n=3; chance 40; if [ "$R" -eq 1 ]; then n=2; fi
    QS=("${QS[@]:0:n}")
    for q in "${QS[@]}"; do
        pick FIRST; f="$R"; gen_surname; l="$R"; gen_org; o="$R"; pick ROLES; r="$R"
        out+="<blockquote><p>${q}</p><cite><b>${f} ${l}</b>, ${r}, ${o}</cite></blockquote>"$'\n'
    done
    cat <<SEC
<section id="clients" class="section${REV}">
<div class="wrap">
<div class="section-head"><h2>${HT_QUOTES}</h2><p class="sub">${ST_QUOTES}</p></div>
<div class="quotes">
${out}</div>
</div>
</section>
SEC
}

sec_contact() {
    cat <<SEC
<section id="contact" class="section${REV}">
<div class="wrap">
<div class="section-head"><h2>${HT_CONTACT}</h2><p class="sub">${ST_CONTACT}</p></div>
<div class="contact-grid">
<div><h3>Visit</h3><p>${ADDR1}<br>${ADDR2}<br>${COUNTRY}</p></div>
<div><h3>Call</h3><p><a href="tel:${PHONE// /}">${PHONE}</a></p></div>
<div><h3>Write</h3><p><a href="mailto:${EMAIL}">${EMAIL}</a></p></div>
<div><h3>Hours</h3><p>${OPEN_HOURS}</p></div>
</div>
</div>
</section>
SEC
}

# ============================================================
#  ЗАПИСЬ ФАЙЛОВ
# ============================================================
# Не очищаем WEBROOT целиком: существующие пользовательские файлы сохраняются.
mkdir -p "${WEBROOT}/${ASSETS}"

# ---------- index.html ----------
{
    emit_head "$TITLE_H" "$META_DESC_H" "/" "index, follow, max-image-preview:large" "$JSONLD"
    emit_header
    sec_hero
    for s in "${ORDER[@]}"; do "sec_$s"; done
    emit_footer
} > "${WEBROOT}/index.html"

# ---------- privacy.html ----------
{
    emit_head "Privacy policy | ${COMPANY_H}" "How ${COMPANY_H} handles personal information collected through this website." "/privacy.html" "index, follow" ""
    emit_header
    cat <<PRIV
<article class="prose">
<h1>Privacy policy</h1>
<p>Last updated: ${UPD_DATE}</p>
<h2>Who we are</h2>
<p>${COMPANY_H} ${LEGAL} (&ldquo;we&rdquo;, &ldquo;us&rdquo;) is based in ${CITY}, ${COUNTRY}. This policy explains how we handle personal information when you visit this website or contact us.</p>
<h2>Information we collect</h2>
<p>If you contact us by email or telephone, we keep the details you provide, such as your name, contact information and the content of your message, so that we can respond. Our web server also records standard technical information, including IP address, browser type and the pages requested, for security and troubleshooting.</p>
<h2>How we use it</h2>
<p>We use this information to answer questions, provide our services, keep this site secure and meet legal obligations. We do not sell personal information and we do not use it for automated decision-making.</p>
<h2>Cookies</h2>
<p>This website does not use advertising or tracking cookies. Any cookies that are set are strictly necessary for the site to work.</p>
<h2>Retention</h2>
<p>Server logs are kept for up to ninety days. Correspondence is kept for as long as it is needed to deal with your request and any follow-up, and for the period required by law.</p>
<h2>Your rights</h2>
<p>Depending on where you live, you may have the right to access, correct or delete the personal information we hold about you, or to object to how we use it. To exercise these rights, please contact us using the details below.</p>
<h2>Contact</h2>
<p>Email <a href="mailto:${EMAIL}">${EMAIL}</a> or write to us at ${ADDR1}, ${ADDR2}, ${COUNTRY}.</p>
</article>
PRIV
    emit_footer
} > "${WEBROOT}/privacy.html"

# ---------- 404.html ----------
{
    emit_head "Page not found | ${COMPANY_H}" "The page you are looking for could not be found." "/404.html" "noindex" ""
    emit_header
    cat <<ERR
<section class="err">
<p class="code">404</p>
<h1>Page not found</h1>
<p class="sub">The page you are looking for may have been moved or no longer exists.</p>
<p><a class="btn" href="/">Back to the home page</a></p>
</section>
ERR
    emit_footer
} > "${WEBROOT}/404.html"

# ---------- favicon ----------
echo "$FAVICON_SVG" > "${WEBROOT}/favicon.svg"

# ---------- robots.txt / sitemap.xml ----------
chance 50
if [ "$R" -eq 1 ]; then ROBOTS_RULE="Allow: /"; else ROBOTS_RULE="Disallow:"; fi
cat > "${WEBROOT}/robots.txt" <<ROBOTS
User-agent: *
${ROBOTS_RULE}

Sitemap: https://${DOMAIN}/sitemap.xml
ROBOTS

CHANGEFREQS=(monthly yearly); pick CHANGEFREQS; CF="$R"
cat > "${WEBROOT}/sitemap.xml" <<SITEMAP
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>https://${DOMAIN}/</loc>
    <lastmod>${LASTMOD}</lastmod>
    <changefreq>${CF}</changefreq>
    <priority>1.0</priority>
  </url>
  <url>
    <loc>https://${DOMAIN}/privacy.html</loc>
    <lastmod>${LASTMOD}</lastmod>
    <changefreq>yearly</changefreq>
    <priority>0.3</priority>
  </url>
</urlset>
SITEMAP

# ---------- CSS ----------
{
cat <<ROOT
/* ${COMPANY_H} — main stylesheet */
:root{
color-scheme:${MODE};
--bg:${BG};--bg2:${BG2};--surface:${SURFACE};--glass:${GLASS};--text:${TEXT};--muted:${MUTED};
--accent:${ACCENT};--accent2:${ACCENT2};--on-accent:${ON_ACC};--glow:${GLOW};--glow2:${GLOW2};
--border:${BORDER};--border-strong:${BORDER_S};--line:${LINE};--line2:${LINE2};--hdr:${HDR};
--shadow:${SHADOW};--shadow-c:${SHADOW_C};
--radius:${RADIUS};--btn-radius:${BTN_RADIUS};--maxw:${MAXW}px;--space:${SPACE}px;--fs:${FS}px;
--font-h:${FONT_H};--font-b:${FONT_B};
--h-weight:${HW};--h-spacing:${HSP};--h-transform:${HTR};
}
ROOT
cat <<'CSS'
*,*::before,*::after{box-sizing:border-box}
html{scroll-behavior:smooth;scroll-padding-top:84px;-webkit-text-size-adjust:100%}
body{margin:0;font-family:var(--font-b);font-size:var(--fs);line-height:1.65;color:var(--text);background:var(--bg);min-height:100vh;position:relative;overflow-x:hidden}
img,svg{max-width:100%}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
h1,h2,h3{font-family:var(--font-h);font-weight:var(--h-weight);letter-spacing:var(--h-spacing);line-height:1.15;margin:0 0 .5em}
h2,h3{text-transform:var(--h-transform)}
h1{font-size:clamp(2.2rem,5vw,3.8rem)}
h2{font-size:clamp(1.6rem,3vw,2.2rem)}
h3{font-size:1.15rem}
p{margin:0 0 1em}
.wrap{width:100%;max-width:var(--maxw);margin:0 auto;padding:0 24px}
.skip{position:absolute;left:-999px;top:0}
.skip:focus{left:12px;top:12px;background:var(--accent);color:var(--on-accent);padding:8px 12px;z-index:100}

/* background layer */
body::before{content:"";position:fixed;inset:0;z-index:-1;pointer-events:none}
.bg-grad::before{background:linear-gradient(135deg,var(--bg),var(--bg2))}
.bg-mesh::before{background:radial-gradient(circle at 15% 10%,var(--glow),transparent 45%),radial-gradient(circle at 85% 30%,var(--glow2),transparent 40%),radial-gradient(circle at 40% 95%,var(--glow),transparent 45%),var(--bg)}
.bg-grid::before{background-color:var(--bg);background-image:linear-gradient(var(--line) 1px,transparent 1px),linear-gradient(90deg,var(--line) 1px,transparent 1px);background-size:44px 44px}
.bg-dots::before{background-color:var(--bg);background-image:radial-gradient(var(--line2) 1.2px,transparent 1.2px);background-size:22px 22px}
.bg-noise::before{background-color:var(--bg);background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.8' numOctaves='2' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' opacity='.07'/%3E%3C/svg%3E")}
.bg-stripes::before{background:repeating-linear-gradient(135deg,transparent 0 22px,var(--line) 22px 23px),linear-gradient(var(--bg),var(--bg2))}
.bg-solid::before{background:var(--bg)}
.bg-anim::before{background:linear-gradient(120deg,var(--bg),var(--bg2),var(--glow),var(--bg));background-size:300% 300%;animation:drift 24s ease infinite}
@keyframes drift{0%{background-position:0 50%}50%{background-position:100% 50%}100%{background-position:0 50%}}

/* header */
.site-header{position:sticky;top:0;z-index:20;background:var(--hdr);-webkit-backdrop-filter:blur(10px);backdrop-filter:blur(10px);border-bottom:1px solid var(--border)}
.bar{display:flex;align-items:center;justify-content:space-between;gap:20px;min-height:68px}
.brand{display:flex;align-items:center;gap:10px;color:var(--text);font-family:var(--font-h);font-weight:700;font-size:1.15rem}
.brand:hover{text-decoration:none}
.mark{width:32px;height:32px;flex:none}
.nav{display:flex;align-items:center;gap:26px}
.nav a{color:var(--text);font-size:.95rem;opacity:.85}
.nav a:hover{opacity:1;text-decoration:none;color:var(--accent)}
.nav .btn{opacity:1;color:var(--on-accent)}
.nav .btn:hover{color:var(--on-accent)}
.nav-toggle{display:none;background:none;border:1px solid var(--border);border-radius:8px;width:42px;height:38px;cursor:pointer;color:var(--text)}
.nav-toggle span,.nav-toggle span::before,.nav-toggle span::after{display:block;width:18px;height:2px;background:currentColor;margin:0 auto;position:relative;content:""}
.nav-toggle span::before{position:absolute;top:-6px;left:0}
.nav-toggle span::after{position:absolute;top:6px;left:0}

/* buttons */
.btn{display:inline-block;padding:.75em 1.5em;border-radius:var(--btn-radius);background:var(--accent);color:var(--on-accent);font-weight:600;font-size:.95rem;border:2px solid var(--accent);transition:transform .2s,box-shadow .2s,border-color .2s,color .2s}
.btn:hover{text-decoration:none;transform:translateY(-2px);box-shadow:0 8px 20px var(--glow)}
.btn-ghost{background:transparent;color:var(--text);border-color:var(--border-strong)}
.btn-ghost:hover{border-color:var(--accent);color:var(--accent);box-shadow:none}
.btn-sm{padding:.5em 1.1em;font-size:.88rem}

/* hero */
.hero{padding:calc(var(--space) * 1.1) 0 var(--space);position:relative}
.hero-grid{display:grid;gap:48px;align-items:center}
.eyebrow{display:inline-block;font-size:.8rem;letter-spacing:.14em;text-transform:uppercase;color:var(--accent);margin-bottom:18px;font-weight:600}
.lead{font-size:1.2rem;color:var(--muted);max-width:620px}
.actions{display:flex;flex-wrap:wrap;gap:14px;margin-top:28px}
.hero-art{display:none}
.hero-art svg{width:100%;height:auto;max-width:420px;margin:0 auto;display:block}
.fx-grad h1 .g{background:linear-gradient(90deg,var(--accent),var(--accent2));-webkit-background-clip:text;background-clip:text;color:transparent}
.fx-glow .hero::before{content:"";position:absolute;width:420px;height:420px;border-radius:50%;background:var(--glow);filter:blur(90px);top:-60px;right:8%;z-index:-1;animation:float 14s ease-in-out infinite}
@keyframes float{50%{transform:translate(-40px,50px)}}

/* layout variants */
.l-a .hero{text-align:center}
.l-a .lead{margin-left:auto;margin-right:auto}
.l-a .actions{justify-content:center}
.l-a .section-head{margin-left:auto;margin-right:auto;text-align:center}
.l-b .hero-grid{grid-template-columns:1.2fr .8fr}
.l-b .hero-art{display:block}
.l-c .bar{flex-direction:column;padding-top:18px;padding-bottom:12px;gap:12px}
.l-c .brand{font-size:1.5rem}
.l-c .hero h1{font-size:clamp(2.4rem,6vw,4.6rem);border-top:3px solid var(--accent);padding-top:24px}
.l-d h1{font-size:clamp(2rem,4vw,3.2rem)}
@media(min-width:900px){
.l-d{display:grid;grid-template-columns:270px minmax(0,1fr);grid-template-rows:1fr auto}
.l-d .site-header{grid-column:1;grid-row:1/3;position:sticky;top:0;height:100vh;align-self:start;border-bottom:0;border-right:1px solid var(--border)}
.l-d .bar{flex-direction:column;align-items:flex-start;justify-content:flex-start;padding-top:36px;gap:40px;min-height:0}
.l-d .nav{flex-direction:column;align-items:flex-start;gap:14px}
.l-d main{grid-column:2;grid-row:1}
.l-d .site-footer{grid-column:2;grid-row:2}
}

/* sections */
.section{padding:var(--space) 0}
.section-head{max-width:640px;margin-bottom:40px}
.sub{color:var(--muted)}
.about-grid{display:grid;gap:48px;grid-template-columns:1.4fr 1fr}
.about-text p{color:var(--muted)}
.values{list-style:none;margin:0;padding:0;display:grid;gap:18px;align-content:start}
.values li{padding-left:18px;border-left:2px solid var(--accent)}
.values strong{display:block;font-family:var(--font-h)}
.values span{color:var(--muted);font-size:.95rem}
.band{background:var(--surface);border-top:1px solid var(--border);border-bottom:1px solid var(--border);padding:calc(var(--space) * .6) 0}

/* cards */
.cards{display:grid;gap:22px;grid-template-columns:repeat(auto-fit,minmax(250px,1fr))}
.card{padding:28px;border-radius:var(--radius);background:var(--surface);border:1px solid var(--border);transition:transform .25s,box-shadow .25s,border-color .25s}
.card h3{margin-bottom:.4em}
.card p{margin:0;color:var(--muted);font-size:.97rem}
.num{display:block;font-family:var(--font-h);color:var(--accent);font-size:.85rem;letter-spacing:.1em;margin-bottom:14px}
.card-flat .card{border-color:transparent}
.card-outline .card{background:transparent;border-color:var(--border-strong)}
.card-shadow .card{border-color:transparent;box-shadow:var(--shadow)}
.card-glass .card{background:var(--glass);-webkit-backdrop-filter:blur(12px);backdrop-filter:blur(12px)}
.card-accent .card{border:0;border-left:4px solid var(--accent);border-radius:calc(var(--radius) / 2)}
.fx-lift .card:hover{transform:translateY(-6px);box-shadow:0 16px 36px var(--shadow-c)}
.svc-list .cards{grid-template-columns:1fr;gap:14px}
.svc-list .card{display:grid;grid-template-columns:60px 1fr 1.5fr;gap:20px;align-items:baseline}
.svc-list .card h3,.svc-list .card p,.svc-list .num{margin:0}
.svc-cols .cards{grid-template-columns:repeat(2,1fr)}

/* stats / steps / quotes / contact */
.stats{display:grid;gap:24px;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));text-align:center}
.stat b{display:block;font-family:var(--font-h);font-size:clamp(2rem,4vw,3rem);color:var(--accent);line-height:1.1}
.stat span{color:var(--muted);font-size:.92rem}
.steps{list-style:none;margin:0;padding:0;display:grid;gap:28px;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));counter-reset:s}
.step{position:relative;padding-top:52px;counter-increment:s}
.step::before{content:counter(s,decimal-leading-zero);position:absolute;top:0;left:0;font-family:var(--font-h);font-size:1.6rem;color:var(--accent);line-height:1}
.step::after{content:"";position:absolute;top:14px;left:52px;right:0;height:1px;background:var(--border-strong)}
.step p{color:var(--muted);font-size:.97rem}
.quotes{display:grid;gap:22px;grid-template-columns:repeat(auto-fit,minmax(280px,1fr))}
blockquote{margin:0;padding:28px;border-radius:var(--radius);background:var(--surface);border:1px solid var(--border)}
blockquote p{font-size:1.02rem;font-style:italic}
blockquote p::before{content:"\201C"}
blockquote p::after{content:"\201D"}
cite{display:block;font-style:normal;font-size:.9rem;color:var(--muted)}
cite b{color:var(--text)}
.contact-grid{display:grid;gap:26px;grid-template-columns:repeat(auto-fit,minmax(200px,1fr))}
.contact-grid h3{font-size:.8rem;text-transform:uppercase;letter-spacing:.12em;color:var(--accent);margin-bottom:.5em}
.contact-grid p{margin:0}

/* footer, text pages */
.site-footer{border-top:1px solid var(--border);padding:34px 0;color:var(--muted);font-size:.9rem}
.foot{display:flex;flex-wrap:wrap;gap:12px 28px;justify-content:space-between}
.foot a{color:var(--muted)}
.foot a:hover{color:var(--accent)}
.prose{max-width:760px;margin:0 auto;padding:64px 24px}
.prose h1{font-size:2.2rem}
.prose h2{font-size:1.2rem;margin-top:1.8em}
.prose p{color:var(--muted)}
.err{text-align:center;padding:110px 24px}
.err .code{font-family:var(--font-h);font-size:clamp(5rem,16vw,9rem);color:var(--accent);line-height:1;margin:0}

/* reveal */
.js .reveal{opacity:0;transform:translateY(22px);transition:opacity .7s ease,transform .7s ease}
.js .reveal.in{opacity:1;transform:none}
@media(prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}.js .reveal{opacity:1;transform:none}}

/* mobile */
@media(max-width:899px){
.nav-toggle{display:block}
.nav{display:none;position:absolute;top:100%;left:0;right:0;flex-direction:column;align-items:flex-start;gap:14px;padding:20px 24px;background:var(--bg);border-bottom:1px solid var(--border)}
.nav.open{display:flex}
.l-b .hero-grid,.about-grid{grid-template-columns:1fr}
.l-c .bar{flex-direction:row;padding-top:0;padding-bottom:0}
.l-c .brand{font-size:1.15rem}
.svc-list .card{grid-template-columns:1fr;gap:6px}
.svc-cols .cards{grid-template-columns:1fr}
.hero{padding-top:var(--space)}
}
CSS
} > "${WEBROOT}/${ASSETS}/${CSS_NAME}"

# ---------- JS ----------
cat > "${WEBROOT}/${ASSETS}/${JS_NAME}" <<'JS'
(function () {
  var d = document;
  d.documentElement.classList.add('js');
  d.addEventListener('DOMContentLoaded', function () {
    var t = d.querySelector('.nav-toggle'), n = d.querySelector('.nav');
    if (t && n) {
      t.addEventListener('click', function () {
        var o = n.classList.toggle('open');
        t.setAttribute('aria-expanded', o ? 'true' : 'false');
      });
      n.addEventListener('click', function (e) {
        if (e.target.tagName === 'A') {
          n.classList.remove('open');
          t.setAttribute('aria-expanded', 'false');
        }
      });
    }
    var els = d.querySelectorAll('.reveal');
    if ('IntersectionObserver' in window) {
      var io = new IntersectionObserver(function (es) {
        es.forEach(function (e) {
          if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
        });
      }, { threshold: 0.12 });
      els.forEach(function (el) { io.observe(el); });
    } else {
      els.forEach(function (el) { el.classList.add('in'); });
    }
  });
})();
JS

# ---------- «возраст» файлов: правдоподобные даты изменения ----------
# Не меняем timestamps и права уже существовавших файлов в каталоге сайта.
# Новые файлы создаются с системной umask пользователя root.

echo "  -> Сид:        ${SEED}   (повтор: HONEYPOT_SEED=${SEED} ./honeypot-generator.sh ${DOMAIN})"
echo "  -> Компания:   ${COMPANY} (${T_INDUSTRY}, ${CITY})"
echo "  -> Дизайн:     layout=${LAYOUT}, фон=${BG_KIND}, карточки=${CARD}, услуги=${SVC_STYLE}, тема=${MODE}, hue=${H}${FX}"
echo "  -> Файлы:      ${WEBROOT} (index, privacy, 404, robots, sitemap, favicon, ${ASSETS}/)"

if [ "$DRY_RUN" = "1" ]; then
    paint "$C_GREEN" "✓ Генерация завершена. Режим dry-run: nginx и сертификат не затрагивались."
    exit 0
fi

# ------------------------------------------------------------
# nginx: сначала HTTP-конфиг для получения сертификата
# ------------------------------------------------------------
step "4/6  Настройка nginx (HTTP для ACME)"

cat > "${NGINX_AVAILABLE}/${DOMAIN}.conf" <<NGINXHTTP
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${WEBROOT};
    index index.html;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINXHTTP

ln -sf "${NGINX_AVAILABLE}/${DOMAIN}.conf" "${NGINX_ENABLED}/${DOMAIN}.conf"

if ! nginx -t; then
    paint "$C_RED" "✖ Проверка nginx не прошла. Перезагрузка не выполнялась."
    exit 1
fi
if ! systemctl reload nginx; then
    paint "$C_RED" "✖ Не удалось перезагрузить nginx. Проверьте systemctl status nginx."
    exit 1
fi
echo "  ✓ HTTP-конфиг применён; конфиги других сайтов не переписывались."

# ------------------------------------------------------------
# Получение сертификата Let's Encrypt
# ------------------------------------------------------------
step "5/6  Получение сертификата Let's Encrypt"

CERT_EMAIL="admin@${DOMAIN}"
if ! certbot certonly --webroot -w /var/www/certbot \
    -d "${DOMAIN}" \
    --non-interactive --agree-tos -m "${CERT_EMAIL}"; then
    exit 1
fi

if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
    exit 1
fi

echo "  -> Сертификат получен: /etc/letsencrypt/live/${DOMAIN}/"

# ------------------------------------------------------------
# Обновление nginx-конфига под HTTPS
# (синтаксис http2 зависит от версии nginx)
# ------------------------------------------------------------
step "6/6  Включение HTTPS и автообновления сертификата"

NGINX_VER="$(nginx -v 2>&1 | sed 's/.*nginx\///; s/[^0-9.].*//')"
if [ "$(printf '%s\n1.25.1\n' "$NGINX_VER" | sort -V | head -n1)" = "1.25.1" ]; then
    LISTEN_SSL="listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;"
else
    LISTEN_SSL="listen 443 ssl http2;
    listen [::]:443 ssl http2;"
fi

cat > "${NGINX_AVAILABLE}/${DOMAIN}.conf" <<NGINXHTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    ${LISTEN_SSL}
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    server_tokens off;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    charset utf-8;
    gzip on;
    gzip_types text/css application/javascript image/svg+xml application/xml text/plain;

    root ${WEBROOT};
    index index.html;

    error_page 404 /404.html;
    location = /404.html { internal; }

    location ~* \.(css|js|svg)\$ {
        expires 30d;
        try_files \$uri =404;
    }

    location ~ /\.(?!well-known) {
        return 404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINXHTTPS

nginx -t
systemctl reload nginx

echo "  -> HTTPS включён"

# ------------------------------------------------------------
# Скрипт автообновления сертификата
# ------------------------------------------------------------
RENEW_SCRIPT="/usr/local/bin/renew-${DOMAIN}.sh"
cat > "${RENEW_SCRIPT}" <<RENEW
#!/bin/bash
certbot renew --webroot -w /var/www/certbot --quiet --deploy-hook "systemctl reload nginx"
RENEW
chmod +x "${RENEW_SCRIPT}"

CRON_LINE="0 3 * * * ${RENEW_SCRIPT} >> /var/log/renew-${DOMAIN}.log 2>&1"
( crontab -l 2>/dev/null | grep -v "${RENEW_SCRIPT}" ; echo "${CRON_LINE}" ) | crontab -

echo "  -> Автообновление сертификата настроено (cron, 03:00 ежедневно)"
echo "  -> Скрипт обновления: ${RENEW_SCRIPT}"

# ------------------------------------------------------------
# Итог
# ------------------------------------------------------------
echo
line
paint "$C_GREEN$C_BOLD" "✓ ГОТОВО"
line
echo " Домен:        https://${DOMAIN}/"
echo " Компания:     ${COMPANY}"
echo " Сид:          ${SEED}"
echo " Файлы сайта:  ${WEBROOT}"
echo " nginx конфиг: ${NGINX_AVAILABLE}/${DOMAIN}.conf"
echo " Сертификат:   /etc/letsencrypt/live/${DOMAIN}/"
echo " Автообновление серта: ${RENEW_SCRIPT} (cron, ежедневно 03:00)"
echo "================================================"
