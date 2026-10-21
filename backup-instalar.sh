#!/bin/bash
# =====================================================================
#  VidaPlena Backup — instalador do motor no Mac
#  Instalar ou atualizar (cole no Terminal):
#    curl -fsSL https://eneas-ena.github.io/vida_plena/backup-instalar.sh | bash
#  Remover:
#    curl -fsSL https://eneas-ena.github.io/vida_plena/backup-instalar.sh | bash -s -- remover
# =====================================================================
LABEL="com.vidaplena.backup"
BASE="$HOME/Library/Application Support/VidaPlenaBackup"
LOGDIR="$HOME/Library/Logs/VidaPlenaBackup"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UIDN="$(id -u)"

if [ "$(uname)" != "Darwin" ]; then echo "Este instalador é só para Mac."; exit 1; fi

if [ "$1" = "remover" ]; then
  launchctl bootout "gui/$UIDN/$LABEL" 2>/dev/null
  rm -f "$PLIST"; rm -rf "$BASE"
  echo ""
  echo "✅ Motor de backup do VidaPlena removido."
  echo "   (Os backups já feitos nos seus discos continuam lá. O histórico em $LOGDIR também.)"
  exit 0
fi

mkdir -p "$BASE" "$LOGDIR" "$HOME/Library/LaunchAgents" || { echo "Não consegui criar as pastas."; exit 1; }

# ---------- motor ----------
cat > "$BASE/vp-backup.sh" <<'__FIM_DO_MOTOR__'
#!/bin/bash
# =====================================================================
#  VidaPlena Backup — motor do Mac
#  Roda sozinho a cada 3 minutos (launchd). Lê as tarefas no Supabase,
#  copia o que estiver na hora e grava o resultado para o painel.
#  Compatível com o bash 3.2 que vem no macOS.
# =====================================================================
VERSAO="1.1.0"
SUPA_URL="${VP_SUPA_URL:-https://ghjbljypxksubmcsvaig.supabase.co}"
SUPA_KEY="sb_publishable_qXCYqg1WdmelY9D1mptZXg_U8NdoKby"
SCHEMA="vidaplena"
export LC_ALL="${VP_LOCALE:-en_US.UTF-8}" LANG="${VP_LOCALE:-en_US.UTF-8}"

BASE="${VP_BASE:-$HOME/Library/Application Support/VidaPlenaBackup}"
LOGDIR="${VP_LOGDIR:-$HOME/Library/Logs/VidaPlenaBackup}"
LOG="$LOGDIR/backup.log"
VOLUMES="${VP_VOLUMES:-/Volumes}"
RSYNC="${VP_RSYNC:-/usr/bin/rsync}"
CURL="${VP_CURL:-/usr/bin/curl}"
# O ajudante JSON: no Mac é o JavaScript nativo (osascript); nos testes pode ser o node
if [ -n "$VP_HELPER_CMD" ]; then HELPER_CMD="$VP_HELPER_CMD"; else HELPER_CMD="/usr/bin/osascript -l JavaScript"; fi
HELPER="$BASE/vp-helper.js"
MAQUINA="$(/usr/sbin/scutil --get ComputerName 2>/dev/null || hostname)"
EXCL_PADRAO=(".DS_Store" ".Trashes" ".Trash" ".Spotlight-V100" ".fseventsd" ".TemporaryItems" ".DocumentRevisions-V100" "._*" "*.tmp")

mkdir -p "$BASE" "$LOGDIR"

# ---------- utilidades ----------
log(){ printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
agora_iso(){ date -u '+%Y-%m-%dT%H:%M:%SZ'; }
helper(){ $HELPER_CMD "$HELPER" "$@"; }
j(){ helper str "$1"; }                 # texto -> JSON
expandir(){ case "$1" in "~") printf '%s' "$HOME";; "~/"*) printf '%s' "$HOME/${1#\~/}";; *) printf '%s' "$1";; esac; }

# Log com no máximo ~5 MB
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" | tr -d ' ')" -gt 5000000 ]; then mv -f "$LOG" "$LOG.1"; fi

# Chamada à API do Supabase. Resultado em RESP e CODE.
RESP=""; CODE=""
api(){ # metodo caminho [json] [prefer]
  local m="$1" p="$2" d="$3" pref="$4" out
  local args=(-sS --max-time 30 -X "$m" "$SUPA_URL/rest/v1/$p" -H "apikey: $SUPA_KEY"
    -H "Accept-Profile: $SCHEMA" -H "Content-Profile: $SCHEMA" -H "Content-Type: application/json")
  [ -n "$pref" ] && args+=(-H "Prefer: $pref")
  [ -n "$d" ] && args+=(--data-binary "$d")
  out=$("$CURL" "${args[@]}" -w $'\n%{http_code}' 2>&1)
  CODE="${out##*$'\n'}"; RESP="${out%$'\n'*}"
  case "$CODE" in 2??) return 0;; *) return 1;; esac
}

# ---------- trava: uma execução por vez ----------
LOCK="$BASE/.trava"
if ! mkdir "$LOCK" 2>/dev/null; then
  pid=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then exit 0; fi
  rm -rf "$LOCK"; mkdir "$LOCK" || exit 0
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

# ---------- 1. sinal de vida + destinos que o Mac enxerga ----------
SUG=()
for v in "$VOLUMES"/*; do
  [ -d "$v" ] || continue
  case "$(basename "$v")" in "Macintosh HD"|"Macintosh HD - Data"|"Recovery"|"Preboot"|"VM"|"Update"|com.apple.*|.*) continue;; esac
  [ -L "$v" ] && continue
  # instaladores (.dmg) e discos só de leitura não servem como destino
  if [ -z "$VP_TESTE" ] && /sbin/mount | grep -F " on $v (" | grep -q "read-only"; then continue; fi
  SUG+=("$v")
done
for g in "$HOME/Library/CloudStorage/"GoogleDrive-*; do
  [ -d "$g" ] || continue
  if [ -d "$g/Meu Drive" ]; then SUG+=("$g/Meu Drive"); elif [ -d "$g/My Drive" ]; then SUG+=("$g/My Drive"); else SUG+=("$g"); fi
done
SUGJ=$(helper arr "${SUG[@]}")
[ -z "$SUGJ" ] && SUGJ='[]'
if ! api POST "backup_motor?on_conflict=id" "{\"id\":1,\"ultimo_contato\":$(j "$(agora_iso)"),\"versao\":$(j "$VERSAO"),\"maquina\":$(j "$MAQUINA"),\"usuario_home\":$(j "$HOME"),\"destinos_sugeridos\":$SUGJ}" "resolution=merge-duplicates,return=minimal"; then
  log "Sem conexão com o Supabase (HTTP $CODE). Tento de novo no próximo ciclo. $RESP"
  exit 0
fi

# ---------- 1b. lista de pastas para o botão "Procurar" do painel ----------
# Refaz no máximo a cada 30 min, ou na hora quando o painel pede ("Atualizar lista").
indexar_pastas(){
  local tmp="$BASE/.pastas.txt" corpo="$BASE/.pastas.json" p
  : > "$tmp"
  find "$HOME" -maxdepth 4 \( -name '.*' -o -name Library -o -name '*.app' -o -name '*.photoslibrary' -o -name '*.bundle' \
       -o -name node_modules -o -name Applications \) -prune -o -type d -print 2>/dev/null | head -n 4000 >> "$tmp"
  for p in "${SUG[@]}"; do
    find "$p" -maxdepth 3 \( -name '.*' -o -name '$RECYCLE.BIN' -o -name 'System Volume Information' -o -name 'Backups.backupdb' \
         -o -name '*.app' -o -name '*.photoslibrary' -o -name node_modules \) -prune -o -type d -print 2>/dev/null | head -n 1500 >> "$tmp"
  done
  { printf '{"id":1,"atualizado_em":%s,"pastas":' "$(j "$(agora_iso)")"; helper arqarr "$tmp"; printf '}'; } > "$corpo"
  api POST "backup_pastas?on_conflict=id" "@$corpo" "resolution=merge-duplicates,return=minimal"
  local rc=$?; rm -f "$tmp" "$corpo"; return $rc
}
if api GET "backup_pastas?select=atualizado_em,pedido_em&id=eq.1"; then
  RE_A='"atualizado_em":"([^"]*)"'; RE_P='"pedido_em":"([^"]*)"'
  P_EM=""; P_PED=""; [[ $RESP =~ $RE_A ]] && P_EM="${BASH_REMATCH[1]}"; [[ $RESP =~ $RE_P ]] && P_PED="${BASH_REMATCH[1]}"
  ULT=$(cat "$BASE/.pastas-ts" 2>/dev/null || echo 0); AGORA_S=$(date +%s)
  if [ -z "$P_EM" ] || [ $((AGORA_S - ULT)) -ge 1800 ] || [[ -n "$P_PED" && "$P_PED" > "$P_EM" ]]; then
    if indexar_pastas; then echo "$AGORA_S" > "$BASE/.pastas-ts"; else log "Não consegui enviar a lista de pastas (HTTP $CODE)"; fi
  fi
fi

# ---------- 2. execuções que ficaram pela metade (Mac desligou no meio) ----------
api PATCH "backup_execucoes?status=eq.rodando" "{\"status\":\"interrompido\",\"fim\":$(j "$(agora_iso)"),\"mensagem\":\"O backup foi interrompido (o Mac desligou ou dormiu). Vai rodar de novo.\"}" "return=minimal" >/dev/null

# ---------- 3. o que precisa rodar agora ----------
api GET "backup_tarefas?select=*&ativo=eq.true" || { log "Erro ao ler tarefas (HTTP $CODE): $RESP"; exit 0; }
TAREFAS="$RESP"
api GET "backup_execucoes?select=id,tarefa_id,inicio,status&order=inicio.desc&limit=500" || { log "Erro ao ler execuções (HTTP $CODE): $RESP"; exit 0; }
EXECS="$RESP"
DEVIDAS=$(helper devidas "$TAREFAS" "$EXECS" $VP_AGORA)
[ -z "$DEVIDAS" ] && exit 0

# ---------- 4. disco de destino conectado? ----------
destino_ok(){ # caminho -> 0 se pode gravar
  local d="$1" vol nome
  case "$d" in
    "$VOLUMES"/*)
      nome="${d#$VOLUMES/}"; nome="${nome%%/*}"; vol="$VOLUMES/$nome"
      [ -d "$vol" ] || return 1
      # precisa ser um disco montado de verdade (evita encher o disco interno numa pasta "fantasma")
      if [ -z "$VP_TESTE" ]; then /sbin/mount | grep -qF " on $vol (" || return 1; fi ;;
  esac
  [ -d "$d" ] || [ -d "$(dirname "$d")" ]
}

# ---------- 5. roda cada tarefa ----------
while IFS=$'\t' read -r TID NOME DEST SOBRE MOTIVO PULADO ORIGS EXCLS <&3; do
  [ -z "$TID" ] && continue
  DEST="$(expandir "$DEST")"; DEST="${DEST%/}"
  IFS=$'\x1f' read -r -a ORIGENS <<< "$ORIGS"
  EXCL=(); [ "$EXCLS" != "-" ] && IFS=$'\x1f' read -r -a EXCL <<< "$EXCLS"

  if ! destino_ok "$DEST"; then
    case "$DEST" in "$VOLUMES"/*) n="${DEST#$VOLUMES/}"; MSG="Aguardando o disco “${n%%/*}” ser conectado. Assim que ele aparecer, o backup roda sozinho.";;
      *) MSG="A pasta de destino não está disponível: $DEST";; esac
    if [ "$PULADO" != "-" ]; then
      api PATCH "backup_execucoes?id=eq.$PULADO" "{\"fim\":$(j "$(agora_iso)"),\"mensagem\":$(j "$MSG")}" "return=minimal"
    else
      api POST "backup_execucoes" "{\"tarefa_id\":$(j "$TID"),\"tarefa_nome\":$(j "$NOME"),\"status\":\"pulado\",\"fim\":$(j "$(agora_iso)"),\"mensagem\":$(j "$MSG"),\"maquina\":$(j "$MAQUINA")}" "return=minimal"
      log "[$NOME] pulado: $MSG"
    fi
    continue
  fi

  api POST "backup_execucoes?select=id" "{\"tarefa_id\":$(j "$TID"),\"tarefa_nome\":$(j "$NOME"),\"status\":\"rodando\",\"maquina\":$(j "$MAQUINA")}" "return=representation" || { log "[$NOME] não consegui registrar o início (HTTP $CODE)"; continue; }
  EID=""; RE='"id":"([0-9a-fA-F-]+)"'; [[ $RESP =~ $RE ]] && EID="${BASH_REMATCH[1]}"
  log "[$NOME] início ($MOTIVO) -> $DEST"
  T0=$(date +%s)

  mkdir -p "$DEST" 2>/dev/null
  TOTAL=0; FALTANDO=""; ERROS=""; PIOR=0
  ERRF="$BASE/.rsync-erro"
  for o in "${ORIGENS[@]}"; do
    [ "$o" = "-" ] && continue
    o="$(expandir "$o")"; [ "$o" != "/" ] && o="${o%/}"
    if [ ! -e "$o" ]; then FALTANDO="$FALTANDO$o; "; continue; fi
    args=(-rt --modify-window=2 -v)
    [ "$SOBRE" = "0" ] && args+=(--ignore-existing)
    for x in "${EXCL_PADRAO[@]}"; do args+=(--exclude "$x"); done
    for x in "${EXCL[@]}"; do [ -n "$x" ] && args+=(--exclude "$x"); done
    SAIDA=$("$RSYNC" "${args[@]}" "$o" "$DEST/" 2>"$ERRF"); RC=$?
    N=$(printf '%s\n' "$SAIDA" | grep -v -e '/$' -e '^[[:space:]]*$' -e '^sending incremental' -e '^building file list' \
          -e '^sent ' -e '^total size' -e '^Transfer ' -e '^created directory' -e 'speedup is' | wc -l | tr -d ' ')
    TOTAL=$((TOTAL + N))
    case "$RC" in
      0|24) ;;
      23) [ $PIOR -lt 1 ] && PIOR=1; ERROS="$ERROS$(basename "$o"): $(tail -n 3 "$ERRF" | tr '\n' ' ') " ;;
      *)  PIOR=2; ERROS="$ERROS$(basename "$o"): $(tail -n 3 "$ERRF" | tr '\n' ' ') " ;;
    esac
    printf '%s\n' "$SAIDA" | sed "s|^|    |" >> "$LOG"
    cat "$ERRF" >> "$LOG" 2>/dev/null
  done
  rm -f "$ERRF"

  DUR=$(( $(date +%s) - T0 )); if [ $DUR -ge 60 ]; then DURT="$((DUR/60)) min"; else DURT="${DUR}s"; fi
  [ -n "$FALTANDO" ] && [ $PIOR -lt 1 ] && PIOR=1
  case $PIOR in
    0) ST="ok";      MSG="$TOTAL arquivo(s) copiado(s) ou atualizado(s) em $DURT." ;;
    1) ST="parcial"; MSG="$TOTAL arquivo(s) copiado(s) em $DURT, mas houve problemas." ;;
    *) ST="erro";    MSG="O backup falhou." ;;
  esac
  [ -n "$FALTANDO" ] && MSG="$MSG Origem não encontrada: $FALTANDO"
  [ -n "$ERROS" ] && MSG="$MSG Detalhe: $ERROS"
  case "$ERROS" in *"not permitted"*|*"Operation not permitted"*) MSG="$MSG (Dica: confira o Acesso Total ao Disco para o bash nos Ajustes do Sistema.)";; esac
  MSG="${MSG:0:1500}"

  if [ -n "$EID" ]; then
    api PATCH "backup_execucoes?id=eq.$EID" "{\"status\":$(j "$ST"),\"fim\":$(j "$(agora_iso)"),\"arquivos\":$TOTAL,\"mensagem\":$(j "$MSG")}" "return=minimal" || log "[$NOME] não consegui gravar o resultado (HTTP $CODE)"
  fi
  [ "$MOTIVO" = "manual" ] && api PATCH "backup_tarefas?id=eq.$TID" '{"rodar_agora":null}' "return=minimal"
  log "[$NOME] $ST: $MSG"
done 3<<< "$DEVIDAS"
exit 0
__FIM_DO_MOTOR__

# ---------- ajudante JSON (JavaScript nativo do macOS) ----------
cat > "$BASE/vp-helper.js" <<'__FIM_DO_AJUDANTE__'
/* VidaPlena Backup — ajudante (JavaScript for Automation, já vem no macOS)
   Chamado pelo motor:  osascript -l JavaScript vp-helper.js <modo> <args...>
   Modos:
     str  <texto>                       -> texto em JSON ("...")
     arqarr <arquivo>                   -> linhas do arquivo como lista JSON
     arr  <a> <b> ...                   -> lista em JSON (["a","b"])
     devidas <tarefas.json> <execs.json> [agoraISO]
          -> uma linha por tarefa que deve rodar agora, campos separados por TAB:
             id  nome  destino  sobrescrever(1/0)  motivo  idPulado  origens  excluir
             (origens e excluir separados pelo caractere 0x1F; campo vazio = "-")       */

var FEITO = ['ok', 'parcial', 'erro'];
var SEP = String.fromCharCode(31);

function limpo(s) { return String(s == null ? '' : s).replace(/[\t\r\n\x1f]/g, ' ').trim() || '-'; }

/* Último horário agendado que já passou (até 7 dias para trás), no fuso do Mac */
function ultimoHorario(t, agora) {
  var hm = String(t.hora || '22:00').split(':'), h = +hm[0] || 0, m = +hm[1] || 0;
  var dias = (t.dias_semana && t.dias_semana.length) ? t.dias_semana : [0, 1, 2, 3, 4, 5, 6];
  for (var k = 0; k <= 7; k++) {
    var d = new Date(agora.getFullYear(), agora.getMonth(), agora.getDate() - k, h, m, 0, 0);
    if (d <= agora && dias.indexOf(d.getDay()) >= 0) return d;
  }
  return null;
}

function devidas(tarefas, execs, agora) {
  var out = [];
  tarefas.forEach(function (t) {
    if (t.ativo === false || !t.destino || !(t.origens && t.origens.length)) return;
    var ex = execs.filter(function (e) { return e.tarefa_id === t.id; });
    var feitoDesde = function (d) { return ex.some(function (e) { return FEITO.indexOf(e.status) >= 0 && new Date(e.inicio) >= d; }); };
    var motivo = null, desde = null;
    var slot = ultimoHorario(t, agora), criado = new Date(t.criado_em || 0);
    if (slot && slot >= criado && !feitoDesde(slot)) { motivo = 'agendado'; desde = slot; }
    if (t.rodar_agora) {
      var ra = new Date(t.rodar_agora);
      if (agora - ra < 864e5 && ra <= agora && !feitoDesde(ra)) { motivo = 'manual'; desde = ra; }
    }
    if (!motivo) return;
    var pul = ex.filter(function (e) { return e.status === 'pulado' && new Date(e.inicio) >= desde; })[0];
    out.push([t.id, limpo(t.nome), limpo(t.destino), t.sobrescrever === false ? '0' : '1', motivo, pul ? pul.id : '-',
      (t.origens || []).map(limpo).join(SEP) || '-', (t.excluir || []).map(limpo).filter(function (x) { return x !== '-'; }).join(SEP) || '-'].join('\t'));
  });
  return out.join('\n');
}

function lerArquivo(p) {
  if (typeof ObjC !== 'undefined') {   // Mac (JavaScript for Automation)
    ObjC.import('Foundation');
    var s = $.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, $());
    return s && !s.isNil() ? s.js : '';
  }
  return require('fs').readFileSync(p, 'utf8');   // testes com Node
}

function run(argv) {
  var modo = argv[0];
  if (modo === 'str') return JSON.stringify(String(argv[1] == null ? '' : argv[1]));
  if (modo === 'arr') return JSON.stringify(argv.slice(1).filter(function (x) { return x !== ''; }));
  if (modo === 'arqarr') {   // arquivo com um caminho por linha -> lista JSON
    var txt = lerArquivo(argv[1]) || '';
    var vistos = {}, lista = [];
    txt.split('\n').forEach(function (l) { if (l && !vistos[l]) { vistos[l] = 1; lista.push(l); } });
    return JSON.stringify(lista);
  }
  if (modo === 'devidas') {
    var tarefas = JSON.parse(argv[1] || '[]'), execs = JSON.parse(argv[2] || '[]');
    if (!Array.isArray(tarefas) || !Array.isArray(execs)) return '';
    return devidas(tarefas, execs, argv[3] ? new Date(argv[3]) : new Date());
  }
  return '';
}

/* Permite testar fora do Mac com Node (no Mac este bloco é ignorado) */
if (typeof process !== 'undefined' && process.argv && typeof module !== 'undefined') {
  if (require.main === module) { var r = run(process.argv.slice(2)); process.stdout.write(r + '\n'); }
  module.exports = { run: run, devidas: devidas, ultimoHorario: ultimoHorario };
}
__FIM_DO_AJUDANTE__

chmod 755 "$BASE/vp-backup.sh"

# ---------- agendador do macOS (launchd): roda a cada 3 minutos e ao ligar o Mac ----------
cat > "$PLIST" <<__PLIST__
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$BASE/vp-backup.sh</string></array>
  <key>StartInterval</key><integer>180</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOGDIR/motor-saida.log</string>
  <key>StandardErrorPath</key><string>$LOGDIR/motor-saida.log</string>
</dict>
</plist>
__PLIST__

launchctl bootout "gui/$UIDN/$LABEL" 2>/dev/null
if ! launchctl bootstrap "gui/$UIDN" "$PLIST"; then
  echo "⚠️  Não consegui ativar o agendador. Tente rodar o comando de novo."
  exit 1
fi

echo ""
echo "✅ Motor de backup do VidaPlena instalado (versão $(grep -m1 '^VERSAO=' "$BASE/vp-backup.sh" | cut -d'"' -f2))."
echo ""
echo "FALTA SÓ UM PASSO (uma vez só): dar ao motor permissão para ler e gravar nos seus discos."
echo "  1. Vou abrir agora: Ajustes do Sistema → Privacidade e Segurança → Acesso Total ao Disco."
echo "  2. Clique no  +  (pode pedir sua senha do Mac)."
echo "  3. Na janela que abrir, aperte  Command + Shift + G , digite  /bin/bash  e tecle Enter."
echo "  4. Clique em Abrir e confira se a chave ao lado de “bash” ficou ligada."
echo ""
echo "Depois volte ao VidaPlena, aba Backup: o motor deve aparecer como “Ligado” em até 3 minutos."
sleep 2
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null
exit 0
