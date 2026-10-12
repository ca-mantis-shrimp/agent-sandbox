# Completed-session token accounting from a session record and its transcript.
# Pure reduction: no host, credential or run.env access. Counters are never
# inferred: a counter the transcript does not state is null, and a stated zero
# stays 0. Output keys use Claude's names for all harnesses:
# input_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens.

def fields: ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"];
def num: if type == "number" then . else null end;
def nulls: [fields[] | {key: ., value: null}] | from_entries;

# Parse JSONL lines tolerantly: objects only; anything else is counted malformed.
def parse_lines:
  [.[] | select(test("\\S"))
   | . as $l | (try ($l | fromjson) catch null)
   | if type == "object" then {ok: .} else {bad: true} end] as $p
  | {events: [$p[] | .ok // empty], malformed: ([$p[] | select(.bad)] | length)};

def uniq_strings: [.[] | select(type == "string" and length > 0)] | unique;

def claude_usage($ev; $malformed):
  [$ev[] | select(.type == "result")] as $r
  | ([$ev[] | select(.type == "assistant")] | length) as $prelim
  | ([$ev[] | select(.type == "system" and .subtype == "init") | .model] | uniq_strings) as $models
  | {source: {kind: "claude-stream", event: "final type=result .usage",
              result_events: ($r | length), ignored_assistant_events: $prelim},
     observed_models: $models,
     observed_providers: [],
     provider_evidence: null,
     model_evidence: (if ($models | length) > 0 then "system.init .model" else null end),
     malformed_lines: $malformed}
  + (if ($r | length) == 0 then
       {status: "missing", reason: (if $malformed > 0 then "no_valid_result_event_malformed_lines" else "no_result_event" end), usage: nulls}
     elif ($r | length) > 1 then
       {status: "ambiguous", reason: "multiple_result_events", usage: nulls}
     else
       ($r[0].usage // null) as $u
       | if ($u | type) != "object" then {status: "missing", reason: "result_without_usage", usage: nulls}
         else ([fields[] | {key: ., value: ($u[.] | num)}] | from_entries) as $c
         | if all($c[]; . == null) then {status: "missing", reason: "result_usage_without_counters", usage: nulls}
           else {status: "reported", reason: null, usage: $c,
                 result_subtype: ($r[0].subtype // null), result_is_error: ($r[0].is_error // null)} end
       end
     end);

def pi_usage($ev; $malformed; $finished):
  [$ev[] | select(.type == "message_end" and .message.role == "assistant") | .message] as $m
  | ($m | map(select(.stopReason == "error" or .stopReason == "aborted"))) as $bad
  | ($m - $bad) as $good
  | ($good | map(. as $x | select((.usage | type) == "object"
        and ([.usage.input, .usage.output, .usage.cacheRead, .usage.cacheWrite] | all(type == "number"))))) as $ok
  | ($good | length) - ($ok | length) as $nousage
  | {source: {kind: "pi-json", event: "message_end (assistant) .message.usage, summed per completed message",
              completed_messages: ($good | length), counted_messages: ($ok | length),
              excluded_error_or_aborted_messages: ($bad | length), messages_without_counters: $nousage},
     observed_models: ([$m[] | .responseModel, .model] | uniq_strings),
     observed_providers: ([$m[] | .provider] | uniq_strings),
     provider_evidence: (if ([$m[] | .provider | select(type == "string" and length > 0)] | length) > 0 then "assistant message .provider (route, not account)" else null end),
     model_evidence: (if ([$m[] | .model | select(type == "string" and length > 0)] | length) > 0 then "assistant message .model" else null end),
     malformed_lines: $malformed}
  + (if ($ok | length) == 0 then
       {status: "missing", reason: (if ($m | length) == 0 then "no_assistant_message_end" else "no_completed_message_with_counters" end), usage: nulls}
     else
       ({input_tokens: ($ok | map(.usage.input) | add),
         cache_creation_input_tokens: ($ok | map(.usage.cacheWrite) | add),
         cache_read_input_tokens: ($ok | map(.usage.cacheRead) | add),
         output_tokens: ($ok | map(.usage.output) | add)}) as $c
       | ([ (if ($bad | length) > 0 then "error_or_aborted_message_excluded" else empty end),
            (if $nousage > 0 then "message_without_counters" else empty end),
            (if $malformed > 0 then "malformed_lines" else empty end),
            (if $finished | not then "session_not_finished" else empty end)]) as $why
       | if ($why | length) == 0 then {status: "reported", reason: null, usage: $c}
         else {status: "partial", reason: ($why | join(",")), usage: $c} end
     end);

# $rec: the session record; $lines: transcript lines or null when unreadable.
def session_usage($ws; $rec; $lines):
  ($rec.harness // null) as $h
  | ($rec.state // null) as $state
  | {workspace: $ws, session: $rec.n, harness: $h, record_model: ($rec.model // null),
     state: $state, outcome: ($rec.outcome // null), ok: ($rec.ok // null),
     stop_reason: ($rec.stop_reason // null)}
  + (if $state == "running" or $state == "preparing" then
       {status: "incomplete", reason: "session_not_stopped", usage: nulls, model_invoked: null}
     elif $rec.outcome == "failed:start" then
       # The only record evidence that the model never ran: the host's start was rejected.
       {status: "no_model_invocation", reason: "record outcome failed:start", usage: nulls, model_invoked: false}
     elif $lines == null then
       {status: "missing", reason: "transcript_unavailable", usage: nulls, model_invoked: null}
     else
       ($lines | parse_lines) as $p
       | (if $h == "claude" then claude_usage($p.events; $p.malformed)
          elif $h == "pi" then pi_usage($p.events; $p.malformed; ($state == "finished" or $state == "ready"))
          else {status: "missing", reason: "unknown_harness", usage: nulls, malformed_lines: $p.malformed} end)
       | . + {model_invoked: (if .status == "reported" or .status == "partial" then true else null end)}
     end);

def total_field($k; $rows):
  ([$rows[] | select(.status == "reported")]) as $r
  | ([$r[] | .usage[$k] | select(. != null)]) as $v
  | {sum: (if ($v | length) == 0 then null else ($v | add) end),
     observed_sessions: ($v | length), missing_sessions: (($r | length) - ($v | length))};

def aggregate($rows):
  def n($s): [$rows[] | select(.status == $s)] | length;
  {sessions: ($rows | length), reported: n("reported"), partial: n("partial"), missing: n("missing"),
   ambiguous: n("ambiguous"), incomplete: n("incomplete"), no_model_invocation: n("no_model_invocation"),
   unreadable: n("unreadable"),
   complete: ($rows | length > 0 and all($rows[]; .status == "reported" or .status == "no_model_invocation")),
   note: "totals sum only sessions with status reported; partial, missing, ambiguous and incomplete sessions are excluded, not counted as zero",
   totals: ([fields[] | {key: ., value: total_field(.; $rows)}] | from_entries)};
