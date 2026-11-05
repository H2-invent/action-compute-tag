#!/usr/bin/env bash
#
# compute-container-tag.sh
#
# Regeln:
#   S) Event steht in SKIP_EVENTS (Default: "push"):
#      -> KEIN Tag (skip=true).
#
#   0) PR mit upmerge/** als Base- ODER Head-Branch:
#      -> KEIN Tag (skip=true), egal welche PR-Aktion.
#
#   D) PR ist als Draft markiert (PR_DRAFT=true):
#      -> KEIN Tag (skip=true). Sobald der PR auf "Ready for review"
#         gestellt wird (Event-Typ ready_for_review), greifen wieder
#         die normalen Regeln (Preview, Fall 1/2/L).
#
#   1) PR gegen master/main (z.B. von hotfix/*):
#      Preview-Tag = <letzter_tag_auf_master>-<run_id>
#
#   2) PR gegen release/X.Y offen/aktualisiert ODER dorthin gemerged
#      (egal woher, auch von master abgezweigt):
#      Tag = X.Y.0-<run_id>
#      IMMER X.Y.0 - wird NIE hochgezählt, egal wie oft in den
#      Release-Branch gemerged wird. Merge und Preview sehen für
#      Release-Branches identisch aus, nur die run_id unterscheidet
#      sich je Lauf.
#
#   L) PR gegen lts/X.Y (Wartungsbranch einer abgelösten Version):
#      Version X.Y kommt aus dem Branch-Namen (wie bei release/X.Y),
#      Patch wird hochgezählt (wie bei master/main).
#      Basis = höchster Tag X.Y.Z, der auf lts/X.Y erreichbar ist.
#      a) offen/aktualisiert -> Preview = <basis>-<run_id>
#      b) gemerged           -> finaler Tag = bump_patch(<basis>)
#      Source-Branch release/* gegen lts/* ist nicht erlaubt (Fehler),
#      damit keine neue Minor-Version in einen LTS-Branch läuft.
#      Ein lts/X.Y-Branch wird vom letzten X.Y-Tag angelegt, z.B.
#        git branch lts/1.5 1.5.7 && git push origin lts/1.5
#
#   3) PR nach master gemerged (merged=true, base=master):
#      a) Source-Branch ist release/X.Y
#         -> finaler Tag = X.Y.0 (ohne Suffix) - das ist der
#            "offizielle" Release. Ab jetzt zählt master von hier
#            weiter (nächster Hotfix wird X.Y.1 usw.)
#      b) Source-Branch ist alles andere (hotfix/bugfix/...)
#         -> finaler Tag = bump_patch(letzter_tag_auf_master)
#      Tags aus lts/X.Y beeinflussen master nicht, da nur auf master
#      erreichbare Tags berücksichtigt werden (git tag --merged).
#
#   4) PR geschlossen ohne Merge (egal welches Ziel):
#      -> KEIN Tag.
#
#   5) Manueller Trigger (workflow_dispatch):
#      Wird IMMER wie Fall 1/2/La (Preview) behandelt, nie final -
#      unabhängig davon, welcher Branch gewählt wurde. BASE_REF ist
#      dabei der manuell gewählte Branch (z.B. per Workflow-Input).
#
# Erwartete Umgebungsvariablen:
#   GITHUB_EVENT_NAME  "pull_request", "workflow_dispatch" oder "push"
#   SKIP_EVENTS        kommagetrennte Liste von Events, bei denen immer
#                      skip=true ausgegeben wird. Default: "push".
#                      Explizit leer ("") = kein Event wird übersprungen;
#                      push wird dann wie workflow_dispatch behandelt.
#   GITHUB_RUN_ID      Actions Run-ID (für den Preview-Suffix)
#   PR_ACTION          bei pull_request: github.event.action
#                      (opened|synchronize|reopened|edited|closed|
#                       ready_for_review|...)
#                      bei workflow_dispatch: wird ignoriert/nicht
#                      benötigt, intern immer als Preview behandelt.
#   PR_MERGED          nur bei pull_request+closed relevant:
#                      github.event.pull_request.merged ("true"/"false")
#   PR_DRAFT           bei pull_request: github.event.pull_request.draft
#                      ("true"/"false"). Optional, Default "false".
#                      Bei anderen Events ignoriert.
#   BASE_REF           bei pull_request: github.event.pull_request.base.ref
#                      bei workflow_dispatch: der manuell gewählte
#                      Branch (z.B. github.event.inputs.branch oder
#                      github.ref_name)
#                      bei push: optional, Fallback ist GITHUB_REF_NAME
#   HEAD_REF           bei pull_request: github.event.pull_request.head.ref
#                      (bei ALLEN PR-Aktionen übergeben, sonst wird ein
#                       PR von upmerge/** nicht erkannt)
#
# Optionale Umgebungsvariablen für das Branch-Schema (leer oder nicht
# gesetzt = Default):
#   MAIN_BRANCHES      kommagetrennte Namen der Hauptbranches.
#                      Default: "main,master"
#   RELEASE_PREFIX     Präfix der Release-Branches vor "X.Y".
#                      Default: "release/"
#   LTS_PREFIX         Präfix der Wartungsbranches vor "X.Y".
#                      Default: "lts/"
#   Beispiel: RELEASE_PREFIX="dev/" LTS_PREFIX="support/"
#             -> dev/1.7 und support/1.5
#
# Voraussetzung im Workflow: actions/checkout mit fetch-depth: 0 UND
# fetch-tags: true, sonst sind Tags lokal nicht sichtbar.
#
# Ausgabe (nach $GITHUB_OUTPUT):
#   tag=<TAG>          nur gesetzt, wenn ein Tag berechnet wurde
#   skip=true|false    "true" wenn kein Tag erzeugt werden soll (Fall S/0/D/4)

set -euo pipefail

MAIN_BRANCHES="${MAIN_BRANCHES:-main,master}"
RELEASE_PREFIX="${RELEASE_PREFIX:-release/}"
LTS_PREFIX="${LTS_PREFIX:-lts/}"

# Maskiert Regex-Sonderzeichen, damit Präfixe wörtlich verglichen werden.
regex_escape() {
  printf '%s' "$1" | sed -e 's/[][\.*^$+?(){}|/]/\\&/g'
}

_main_alternatives=""
IFS=',' read -r -a _main_list <<< "${MAIN_BRANCHES// /}"
for _b in "${_main_list[@]}"; do
  [ -z "$_b" ] && continue
  _main_alternatives="${_main_alternatives:+${_main_alternatives}|}$(regex_escape "$_b")"
done
if [ -z "$_main_alternatives" ]; then
  echo "::error::MAIN_BRANCHES enthält keinen Branch-Namen." >&2
  exit 1
fi

if [ "$RELEASE_PREFIX" = "$LTS_PREFIX" ]; then
  echo "::error::RELEASE_PREFIX und LTS_PREFIX dürfen nicht gleich sein ('${RELEASE_PREFIX}')." >&2
  exit 1
fi

MAIN_BRANCH_REGEX="^(${_main_alternatives})$"
RELEASE_BRANCH_REGEX="^$(regex_escape "$RELEASE_PREFIX")([0-9]+)\.([0-9]+)$"
LTS_BRANCH_REGEX="^$(regex_escape "$LTS_PREFIX")([0-9]+)\.([0-9]+)$"
UPMERGE_BRANCH_REGEX='^upmerge/'
SEMVER_TAG_REGEX='^[0-9]+\.[0-9]+\.[0-9]+$'

: "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME muss gesetzt sein}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID muss gesetzt sein}"

# "-" statt ":-": explizit leer gesetzt bleibt leer (= nichts überspringen)
SKIP_EVENTS="${SKIP_EVENTS-push}"

# Optional: fehlt die Variable (ältere Workflows), gilt der PR als kein Draft
PR_DRAFT="${PR_DRAFT:-false}"

# Bei push gibt es keinen PR-Base-Branch -> Fallback auf den gepushten Branch
BASE_REF="${BASE_REF:-${GITHUB_REF_NAME:-}}"
: "${BASE_REF:?BASE_REF muss gesetzt sein}"

case "${GITHUB_EVENT_NAME}" in
  pull_request)
    : "${PR_ACTION:?PR_ACTION muss gesetzt sein}"
    ;;
  workflow_dispatch)
    # Manueller Trigger verhält sich immer wie ein offener/aktualisierter
    # PR (Preview) - nie "closed", also einfach fest auf "manual" setzen,
    # damit die weiter unten stehende "PR_ACTION != closed"-Weiche greift.
    PR_ACTION="manual"
    ;;
  push)
    # Standardmäßig über SKIP_EVENTS übersprungen. Ist push nicht in
    # SKIP_EVENTS, wird es wie workflow_dispatch als Preview behandelt.
    PR_ACTION="push"
    ;;
  *)
    echo "::error::Nur GITHUB_EVENT_NAME=pull_request, workflow_dispatch oder push wird unterstützt." >&2
    exit 1
    ;;
esac

SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

write_output() {
  local tag="$1"
  local skip="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "tag=${tag}"
      echo "skip=${skip}"
    } >> "${GITHUB_OUTPUT}"
  fi
}

# Schreibt Tag, Ziel-/Source-Branch und Begründung in den Step Summary
# und in $GITHUB_OUTPUT, und beendet das Skript.
write_result() {
  local tag="$1"
  local skip="$2"
  local reason="$3"

  write_output "$tag" "$skip"

  {
    echo "## Container-Tag"
    echo ""
    echo "| Feld | Wert |"
    echo "|---|---|"
    if [ "$skip" = "true" ]; then
      echo "| Tag | _kein Tag erzeugt_ |"
    else
      echo "| Tag | \`${tag}\` |"
    fi
    echo "| Ziel-Branch | \`${BASE_REF}\` |"
    echo "| Source-Branch | $( [ -n "${HEAD_REF:-}" ] && echo "\`${HEAD_REF}\`" || echo "—" ) |"
    echo "| Event | \`${GITHUB_EVENT_NAME}\` / \`${PR_ACTION}\` |"
    echo "| Begründung | ${reason} |"
  } >> "$SUMMARY"

  if [ "$skip" != "true" ]; then
    echo "$tag"
  fi
  exit 0
}

# --- Fall S: Event steht in SKIP_EVENTS -> nie ein Tag ---
if [[ ",${SKIP_EVENTS// /}," == *",${GITHUB_EVENT_NAME},"* ]]; then
  echo "Event '${GITHUB_EVENT_NAME}' steht in SKIP_EVENTS - kein Tag." >&2
  write_result "" "true" "Event \`${GITHUB_EVENT_NAME}\` steht in SKIP_EVENTS (\`${SKIP_EVENTS}\`)."
fi

# --- Fall 0: upmerge/** als Base oder Head -> nie ein Tag ---
if [[ "${BASE_REF}" =~ $UPMERGE_BRANCH_REGEX ]] || [[ "${HEAD_REF:-}" =~ $UPMERGE_BRANCH_REGEX ]]; then
  echo "upmerge-Branch beteiligt - kein Tag." >&2
  write_result "" "true" "upmerge-Branch beteiligt (Base: \`${BASE_REF}\`, Head: \`${HEAD_REF:-—}\`)."
fi

# --- Fall D: Draft-PR -> nie ein Tag ---
if [ "${GITHUB_EVENT_NAME}" = "pull_request" ] && [ "${PR_DRAFT}" = "true" ]; then
  echo "PR ist als Draft markiert - kein Tag." >&2
  write_result "" "true" "PR ist als Draft markiert. Build startet nach \"Ready for review\"."
fi

git fetch --tags --force --quiet || true

# Liefert den höchsten reinen Semver-Tag (X.Y.Z, kein "+..."), der auf
# $1 (Branch/Ref) erreichbar ist. Optional $2 = "X.Y": nur Tags dieser
# Minor-Version berücksichtigen.
latest_semver_tag_on() {
  local ref="$1"
  local minor_prefix="${2:-}"
  local resolved_ref="$ref"
  if ! git rev-parse --verify --quiet "$ref" >/dev/null; then
    resolved_ref="origin/${ref}"
  fi
  local filter="$SEMVER_TAG_REGEX"
  if [ -n "$minor_prefix" ]; then
    filter="^${minor_prefix//./\\.}\\.[0-9]+$"
  fi
  git tag --merged "$resolved_ref" 2>/dev/null \
    | grep -E "$filter" \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -n1 || true
}

bump_patch() {
  local v="$1"
  local major minor patch
  IFS='.' read -r major minor patch <<< "$v"
  echo "${major}.${minor}.$((patch + 1))"
}

# --- Fall 4: PR geschlossen ohne Merge -> nie ein Tag, egal welches Ziel ---
if [ "${PR_ACTION}" = "closed" ]; then
  : "${PR_MERGED:?Bei PR_ACTION=closed muss PR_MERGED gesetzt sein}"
  if [ "${PR_MERGED}" != "true" ]; then
    echo "PR wurde geschlossen, aber nicht gemerged - kein Tag." >&2
    write_result "" "true" "PR wurde geschlossen, aber nicht gemerged."
  fi
fi

# Ab hier: entweder PR offen/aktualisiert, oder PR gemerged.

if [[ "$BASE_REF" =~ $RELEASE_BRANCH_REGEX ]]; then
  # Fall 2: sowohl Preview (offen/aktualisiert) als auch Merge in
  # release/X.Y erzeugen denselben Tag X.Y.0-<run_id>. Bewusst
  # unabhängig von jeglicher Tag-Historie, damit ein von master
  # abgezweigter Branch (z.B. mit Tag 1.5.6) nicht fälschlich die
  # master-Version übernimmt und damit dieser Tag nie hochgezählt wird.
  MAJOR="${BASH_REMATCH[1]}"
  MINOR="${BASH_REMATCH[2]}"
  TAG="${MAJOR}.${MINOR}.0-${GITHUB_RUN_ID}"
  echo "Tag für release-Branch '${BASE_REF}': ${TAG}" >&2
  write_result "$TAG" "false" "Ziel-Branch ist ein release-Branch - Version kommt fest aus dem Branch-Namen (\`${MAJOR}.${MINOR}.0\`), unabhängig von der Tag-Historie; wird nie hochgezählt."
fi

if [[ "$BASE_REF" =~ $LTS_BRANCH_REGEX ]]; then
  # Fall L: Wartungsbranch einer abgelösten Version.
  MAJOR="${BASH_REMATCH[1]}"
  MINOR="${BASH_REMATCH[2]}"

  if [ -n "${HEAD_REF:-}" ] && [[ "$HEAD_REF" =~ $RELEASE_BRANCH_REGEX ]]; then
    echo "::error::release-Branch '${HEAD_REF}' darf nicht nach '${BASE_REF}' gemerged werden. Fixes per Cherry-Pick übernehmen." >&2
    exit 1
  fi

  BASE_TAG="$(latest_semver_tag_on "$BASE_REF" "${MAJOR}.${MINOR}")"
  if [ -z "$BASE_TAG" ]; then
    echo "::error::Kein Tag ${MAJOR}.${MINOR}.Z auf '${BASE_REF}' gefunden. Wartungsbranch vom letzten ${MAJOR}.${MINOR}-Tag anlegen, z.B. git branch ${BASE_REF} ${MAJOR}.${MINOR}.0" >&2
    exit 1
  fi

  if [ "${PR_ACTION}" != "closed" ]; then
    # Fall La: Preview
    TAG="${BASE_TAG}-${GITHUB_RUN_ID}"
    echo "Preview-Tag für lts-Branch '${BASE_REF}': ${TAG}" >&2
    write_result "$TAG" "false" "Ziel-Branch ist ein lts-Branch - Preview: letzter Tag \`${BASE_TAG}\` + Run-ID."
  fi

  # Fall Lb: Merge -> Patch-Bump innerhalb X.Y
  TAG="$(bump_patch "$BASE_TAG")"
  echo "'${HEAD_REF:-}' wurde nach '${BASE_REF}' gemerged -> Patch-Bump auf ${TAG}" >&2
  write_result "$TAG" "false" "\`${HEAD_REF:-}\` wurde nach lts-Branch \`${BASE_REF}\` gemerged - Patch-Bump von \`${BASE_TAG}\` auf \`${TAG}\`."
fi

if [[ ! "$BASE_REF" =~ $MAIN_BRANCH_REGEX ]]; then
  echo "::error::Ziel-Branch '${BASE_REF}' passt weder auf ${MAIN_BRANCHES}, ${RELEASE_PREFIX}X.Y noch ${LTS_PREFIX}X.Y." >&2
  exit 1
fi

# Ziel ist master/main:
if [ "${PR_ACTION}" != "closed" ]; then
  # Fall 1: Preview-Tag für einen offenen/aktualisierten PR gegen master.
  #
  # Sonderfall: kommt der PR von einem release/X.Y Branch (z.B. wird
  # release/1.5 gegen master geöffnet), soll die Preview schon die
  # neue Version zeigen (1.5.0-<run_id>) statt des alten master-Tags
  # - schließlich wird daraus beim Merge ohnehin 1.5.0.
  if [ -n "${HEAD_REF:-}" ] && [[ "$HEAD_REF" =~ $RELEASE_BRANCH_REGEX ]]; then
    MAJOR="${BASH_REMATCH[1]}"
    MINOR="${BASH_REMATCH[2]}"
    TAG="${MAJOR}.${MINOR}.0-${GITHUB_RUN_ID}"
    echo "PR von release-Branch '${HEAD_REF}' gegen '${BASE_REF}' -> Preview: ${TAG}" >&2
    write_result "$TAG" "false" "Source-Branch ist ein release-Branch - Preview zeigt schon dessen Version (\`${MAJOR}.${MINOR}.0\`) statt des alten master-Tags."
  else
    BASE_TAG="$(latest_semver_tag_on "$BASE_REF")"
    if [ -z "$BASE_TAG" ]; then
      echo "::error::Kein Semver-Tag (X.Y.Z) auf '${BASE_REF}' gefunden. Initialen Tag setzen, z.B. 0.1.0." >&2
      exit 1
    fi
    TAG="${BASE_TAG}-${GITHUB_RUN_ID}"
    echo "Preview-Tag: ${TAG}" >&2
    write_result "$TAG" "false" "Preview-Tag: letzter Tag auf \`${BASE_REF}\` (\`${BASE_TAG}\`) + Run-ID."
  fi
fi

# Fall 3: Merge nach master/main.
: "${HEAD_REF:?Bei einem Merge muss HEAD_REF gesetzt sein}"

if [[ "$HEAD_REF" =~ $RELEASE_BRANCH_REGEX ]]; then
  # Fall 3a: Release-Branch wird final in master gemerged.
  MAJOR="${BASH_REMATCH[1]}"
  MINOR="${BASH_REMATCH[2]}"
  TAG="${MAJOR}.${MINOR}.0"
  echo "Release-Branch '${HEAD_REF}' wurde nach '${BASE_REF}' gemerged -> finaler Tag ${TAG}" >&2
  write_result "$TAG" "false" "Release-Branch \`${HEAD_REF}\` wurde final nach \`${BASE_REF}\` gemerged - finaler Tag ohne Suffix. \`${BASE_REF}\` zählt ab jetzt von \`${MAJOR}.${MINOR}.x\` weiter."
else
  # Fall 3b: hotfix/bugfix/... direkt in master gemerged.
  BASE_TAG="$(latest_semver_tag_on "$BASE_REF")"
  if [ -z "$BASE_TAG" ]; then
    echo "::error::Kein Semver-Tag (X.Y.Z) auf '${BASE_REF}' gefunden. Initialen Tag setzen, z.B. 0.1.0." >&2
    exit 1
  fi
  TAG="$(bump_patch "$BASE_TAG")"
  echo "'${HEAD_REF}' wurde nach '${BASE_REF}' gemerged -> Patch-Bump auf ${TAG}" >&2
  write_result "$TAG" "false" "\`${HEAD_REF}\` wurde nach \`${BASE_REF}\` gemerged - Patch-Bump von \`${BASE_TAG}\` auf \`${TAG}\`."
fi
