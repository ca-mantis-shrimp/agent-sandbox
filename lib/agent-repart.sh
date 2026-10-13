# Shared mkosi repart definitions lookup. Override for hosts and fixture tests.
repart_definitions() {
    if [ -n "${AGENT_REPART_DEFINITIONS:-}" ]; then
        printf '%s\n' "$AGENT_REPART_DEFINITIONS"
    else
        python3 -c 'import mkosi, os; print(os.path.dirname(mkosi.__file__) + "/resources/repart/definitions")'
    fi
}
