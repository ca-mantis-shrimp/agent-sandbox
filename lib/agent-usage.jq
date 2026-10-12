# Completed-session token accounting from a session record and its transcript.
# Pure reduction: no host, credential or run.env access. Counters are never
# inferred: a counter the transcript does not state is null, and a stated zero
# stays 0. Output keys use Claude's names for all harnesses:
# input_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens.

def fields: ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"];
# A counter is a finite non-negative whole number; anything else is not a counter.
def cnt: if type == "number" and . >= 0 and . == floor and . < 1e15 then . else null end;
def str: if type == "string" then . else null end;
def bool: if type == "boolean" then . else null end;
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
       $r[0].usage as $u
       | if ($u | type) != "object" then {status: "missing", reason: "result_without_usage", usage: nulls}
         else ([fields[] | . as $k | {key: $k, value: ($u[$k] | cnt)}] | from_entries) as $c
         | ([fields[] | select(. as $k | ($u | has($k)) and $u[$k] != null and ($u[$k] | cnt) == null)]) as $invalid
         | if all($c[]; . == null) then {status: "missing", reason: (if ($invalid | length) > 0 then "result_counters_invalid" else "result_usage_without_counters" end), usage: nulls}
           else ([ (if ($invalid | length) > 0 then "invalid_counters:" + ($invalid | join("+")) else empty end),
                   (if $malformed > 0 then "malformed_lines_may_hide_result" else empty end)]) as $why
             | {status: (if ($why | length) == 0 then "reported" else "partial" end),
                reason: (if ($why | length) == 0 then null else ($why | join(",")) end), usage: $c,
                result_subtype: ($r[0].subtype | str), result_is_error: ($r[0].is_error | bool)} end
       end
     end);

def pi_keys: {input_tokens: "input", cache_creation_input_tokens: "cacheWrite",
              cache_read_input_tokens: "cacheRead", output_tokens: "output"};

# Error and aborted messages carry real consumption and are kept (as partial).
# Identical message_end events are one message when they carry an identity
# (responseId or timestamp), else the transcript is ambiguous.
def pi_usage($ev; $malformed; $finished):
  [$ev[] | select(.type == "message_end")] as $me
  | ($me | map(select((.message | type) != "object")) | length) as $badev
  | [$me[] | select((.message | type) == "object" and .message.role == "assistant") | .message] as $all
  | ($all | group_by(tojson)) as $groups
  | def ident: ((.responseId | type) == "string" and (.responseId | length) > 0) or (.timestamp | type) == "number";
    ([$groups[] | select(length > 1 and (.[0] | ident | not))] | length) as $amb
  | ([$groups[] | select(length > 1 and (.[0] | ident)) | length - 1] | add // 0) as $dropped
  | [$groups[] | .[0]] as $m
  | ($m | map(select(.stopReason == "error" or .stopReason == "aborted"))) as $bad
  | ($m | map(select(.stopReason != "stop" and .stopReason != "length" and .stopReason != "toolUse" and .stopReason != "error" and .stopReason != "aborted"))) as $pending
  | (pi_keys | with_entries(.value as $f | .value = [$m[] | (if (.usage | type) == "object" then .usage[$f] else null end) | cnt])) as $vals
  | ($vals | map_values([.[] | select(. != null)])) as $seen
  | ($m | map(select((.usage | type) == "object" and ([.usage.input, .usage.output, .usage.cacheRead, .usage.cacheWrite] | any(cnt != null))))) as $withc
  | ($m | length) as $nm
  | {source: {kind: "pi-json", event: "message_end (assistant) .message.usage, summed per message",
              messages: $nm, counted_messages: ($withc | length), messages_without_counters: ($nm - ($withc | length)),
              error_or_aborted_messages: ($bad | length), non_terminal_messages: ($pending | length),
              duplicate_messages_dropped: $dropped, malformed_message_ends: $badev},
     observed_models: ([$all[] | .responseModel, .model] | uniq_strings),
     observed_providers: ([$all[] | .provider] | uniq_strings),
     provider_evidence: (if ([$all[] | .provider | select(type == "string" and length > 0)] | length) > 0 then "assistant message .provider (route, not account)" else null end),
     model_evidence: (if ([$all[] | .model | select(type == "string" and length > 0)] | length) > 0 then "assistant message .model" else null end),
     malformed_lines: $malformed}
  + (if $amb > 0 then
       {status: "ambiguous", reason: "identical_message_end_without_identity", usage: nulls}
     elif ($withc | length) == 0 then
       {status: "missing", reason: (if $nm == 0 then "no_assistant_message_end" else "no_completed_message_with_counters" end), usage: nulls}
     else
       ($seen | map_values(if length == 0 then null else add end)) as $c
       | ([ (if ($bad | length) > 0 then "error_or_aborted_message_included" else empty end),
            (if ($pending | length) > 0 then "message_not_terminal" else empty end),
            (if ($seen | any(length < $nm)) then "message_without_counters" else empty end),
            (if $dropped > 0 then "duplicate_message_end_deduplicated" else empty end),
            (if $badev > 0 then "malformed_message_end" else empty end),
            (if $malformed > 0 then "malformed_lines" else empty end),
            (if $finished | not then "session_not_finished" else empty end)]) as $why
       | if ($why | length) == 0 then {status: "reported", reason: null, usage: $c}
         else {status: "partial", reason: ($why | join(",")), usage: $c} end
     end);

# $rec: the session record; $lines: transcript lines or null when unreadable.
def session_usage($ws; $rec; $lines):
  ($rec.harness | str) as $h
  | ($rec.state | str) as $state
  | {workspace: $ws, session: ($rec.n | tonumber), harness: $h, record_model: ($rec.model | str),
     state: $state, outcome: ($rec.outcome | str), ok: ($rec.ok | bool),
     stop_reason: ($rec.stop_reason | str),
     # failed:start only says the unit did not start cleanly; it is not proof the model never ran.
     start_failed: ($rec.outcome == "failed:start")}
  + (if $state == "running" or $state == "preparing" then
       {status: "incomplete", reason: "session_not_stopped", usage: nulls, model_invoked: null}
     elif $lines == null then
       {status: "missing", reason: "transcript_unavailable", usage: nulls, model_invoked: null}
     else
       ($lines | parse_lines) as $p
       | (if $h == "claude" then claude_usage($p.events; $p.malformed)
          elif $h == "pi" then pi_usage($p.events; $p.malformed; ($state == "finished" or $state == "ready"))
          else {status: "missing", reason: "unknown_harness", usage: nulls, malformed_lines: $p.malformed} end)
       | . + {model_invoked: (if (.status == "reported" or .status == "partial") and (.usage | any(. != null)) then true else null end)}
     end)
  | . + {counters_complete: (.usage | all(. != null))};

# observed/missing_sessions: reported sessions with/without the counter.
# unobserved_sessions: every session in the workspace that adds nothing to sum.
# lower_bound_sum: reported plus partial sessions, a floor and not a total.
def total_field($k; $rows):
  ([$rows[] | select(.status == "reported")]) as $r
  | ([$r[] | .usage[$k] | select(. != null)]) as $v
  | ([$rows[] | select(.status == "reported" or .status == "partial") | .usage[$k] | select(. != null)]) as $lb
  | {sum: (if ($v | length) == 0 then null else ($v | add) end),
     observed_sessions: ($v | length), missing_sessions: (($r | length) - ($v | length)),
     unobserved_sessions: (($rows | length) - ($v | length)),
     lower_bound_sum: (if ($lb | length) == 0 then null else ($lb | add) end)};

def aggregate($rows):
  def n($s): [$rows[] | select(.status == $s)] | length;
  {sessions: ($rows | length), reported: n("reported"), partial: n("partial"), missing: n("missing"),
   ambiguous: n("ambiguous"), incomplete: n("incomplete"), unreadable: n("unreadable"),
   complete: ($rows | length > 0 and all($rows[]; .status == "reported" and .counters_complete == true)),
   note: "sum covers only reported sessions; partial, missing, ambiguous, incomplete and unreadable sessions are excluded, not zero (lower_bound_sum adds partial sessions); complete needs every session reported with all four counters",
   totals: ([fields[] | {key: ., value: total_field(.; $rows)}] | from_entries)};
