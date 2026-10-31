# Helpers for the run-directory question inbox. Questions are untrusted: validate
# every path before reading, and never follow a link supplied by a session.
question_id_valid() { # <question id>
    case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 15 ]
}

question_file_read() { # <path> <max bytes>; bounded content on stdout
    (
        path=$1 max=$2
        [ ! -L "$path" ] && [ -f "$path" ] || exit 1
        tmp=$(mktemp) || exit 1
        trap 'rm -f "$tmp"' 0
        trap 'exit 1' HUP INT TERM
        # Open once, refuse links at open time, and avoid blocking on a swapped FIFO.
        # Read one byte past the limit so oversized files are rejected, not truncated.
        dd if="$path" of="$tmp" iflag=nofollow,nonblock,count_bytes \
            count=$((max + 1)) status=none 2>/dev/null || exit 1
        bytes=$(wc -c <"$tmp") || exit 1
        [ "$bytes" -le "$max" ] || exit 1
        cat "$tmp"
    )
}

question_dir_safe() { # <workspace-dir>
    [ ! -L "$1/questions" ] && [ -d "$1/questions" ]
}

# Print unanswered questions belonging to currently running sessions as
# <question-id><TAB><sanitized first line>. Errors never cause unsafe reads.
waiting_questions() ( # <workspace-dir> <workspace-id>
    qrun=$1 qid=$2
    [ -e "$qrun/questions" ] || exit 0
    if ! question_dir_safe "$qrun"; then
        echo "agent-status > refusing unsafe questions directory: $qrun/questions" >&2
        exit 0
    fi
    run_real=$(CDPATH= cd -- "$qrun" && pwd -P) || exit 0
    expected_questions=$run_real/questions
    cd -P "$qrun/questions" || {
        echo "agent-status > refusing unsafe questions directory: $qrun/questions" >&2
        exit 0
    }
    if [ "$(pwd -P)" != "$expected_questions" ]; then
        echo "agent-status > refusing unsafe questions directory: $qrun/questions" >&2
        exit 0
    fi
    for qfile in ./*.md; do
        [ -e "$qfile" ] || [ -L "$qfile" ] || continue
        qname=${qfile#./}
        q=${qname%.md}
        display_question=$qrun/questions/$qname
        if ! question_id_valid "$q"; then
            echo "agent-status > refusing unsafe question: $display_question" >&2
            continue
        fi
        [ ! -e "$q.timeout" ] && [ ! -L "$q.timeout" ] || continue
        question_contents=$(question_file_read "$qfile" 65536) || {
            echo "agent-status > refusing unsafe question: $display_question" >&2
            continue
        }
        session_file=$q.session
        session_contents=$(question_file_read "$session_file" 32) || {
            echo "agent-status > refusing unsafe question session record: $qrun/questions/$session_file" >&2
            continue
        }
        session=$session_contents
        question_id_valid "$session" || continue
        expected_sessions=$run_real/sessions
        record_contents=$(
            [ ! -L "$expected_sessions" ] && [ -d "$expected_sessions" ] || exit 1
            cd -P "$expected_sessions" || exit 1
            [ "$(pwd -P)" = "$expected_sessions" ] || exit 1
            question_file_read "$session.json" 65536
        ) || {
            echo "agent-status > refusing unsafe session record: $run_real/sessions/$session.json" >&2
            continue
        }
        printf '%s\n' "$record_contents" | jq -e --argjson n "$session" \
            'select(.state == "running" and .n == $n)' >/dev/null 2>&1 || continue
        agent_unit_active "$qid" || continue
        answer=$q.answer
        if [ -e "$answer" ] || [ -L "$answer" ]; then
            if [ -L "$answer" ] || [ ! -f "$answer" ]; then
                echo "agent-status > refusing unsafe answer: $qrun/questions/$answer" >&2
            fi
            continue
        fi
        title=$(printf '%s\n' "$question_contents" | head -n 1 | tr -cd '\11\12\15\40-\176' | tr '\t\r' '  ' | cut -c1-200)
        printf '%s\t%s\n' "$q" "$title"
    done
)
