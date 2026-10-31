# Helpers for the run-directory question inbox. Questions are untrusted: validate
# every path before reading, and never follow a link supplied by a session.
question_id_valid() { # <question id>
    case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 15 ]
}

question_file_safe() { # <path> <max bytes>
    [ ! -L "$1" ] && [ -f "$1" ] || return 1
    bytes=$(wc -c <"$1") || return 1
    [ "$bytes" -le "$2" ]
}

question_dir_safe() { # <workspace-dir>
    [ ! -L "$1/questions" ] && [ -d "$1/questions" ]
}

# Print unanswered questions belonging to currently running sessions as
# <question-id><TAB><sanitized first line>. Errors never cause unsafe reads.
waiting_questions() { # <workspace-dir> <workspace-id>
    qrun=$1 qid=$2
    [ -e "$qrun/questions" ] || return 0
    if ! question_dir_safe "$qrun"; then
        echo "agent-status > refusing unsafe questions directory: $qrun/questions" >&2
        return 0
    fi
    for qfile in "$qrun"/questions/*.md; do
        [ -e "$qfile" ] || [ -L "$qfile" ] || continue
        qname=${qfile##*/}
        q=${qname%.md}
        if ! question_id_valid "$q" || ! question_file_safe "$qfile" 65536; then
            echo "agent-status > refusing unsafe question: $qfile" >&2
            continue
        fi
        session_file="$qrun/questions/$q.session"
        if ! question_file_safe "$session_file" 32; then
            echo "agent-status > refusing unsafe question session record: $session_file" >&2
            continue
        fi
        session=$(cat "$session_file") || continue
        question_id_valid "$session" || continue
        record="$qrun/sessions/$session.json"
        [ ! -L "$record" ] && [ -f "$record" ] || continue
        jq -e --argjson n "$session" 'select(.state == "running" and .n == $n)' "$record" >/dev/null 2>&1 || continue
        agent_unit_active "$qid" || continue
        answer="$qrun/questions/$q.answer"
        if [ -e "$answer" ] || [ -L "$answer" ]; then
            if [ -L "$answer" ] || [ ! -f "$answer" ]; then
                echo "agent-status > refusing unsafe answer: $answer" >&2
            fi
            continue
        fi
        title=$(head -n 1 "$qfile" | tr -cd '\11\12\15\40-\176' | tr '\t\r' '  ' | cut -c1-200)
        printf '%s\t%s\n' "$q" "$title"
    done
}
