# jq is the JSON/format parser; unknown or incomplete evidence is not coverage.
def review_report:
  [.closing // "" | match("```json\\s*\n(?<body>[\\s\\S]*?)\n```"; "g")
   | .captures[0].string | fromjson? | select(type == "object")
   | select((.coverage | type) == "array" and (.findings | type) == "array"
            and (.for_human | type) == "array")
   | select(.verdict == "land" or .verdict == "land after fixes" or .verdict == "do not land")
   | select(all(.coverage[]; (.check | type) == "string" and (.how | type) == "string"))
   | select(all(.findings[]; (.severity == "blocking" or .severity == "should-fix" or .severity == "nit")
       and (.file | type) == "string" and (.line | type) == "number"
       and (.what | type) == "string" and (.why | type) == "string"))
   | select(all(.for_human[]; type == "string"))] | last;

def canonical_path:
  sub("^/job/work/"; "") | split("/")
  | reduce .[] as $part ([];
      if $part == "." or $part == "" then .
      elif $part == ".." then . + [".."] else . + [$part] end)
  | join("/");

def complete_request:
  ((.offset // 1) == 1) and (.limit == null);

def pi_reads:
  . as $events
  | $events[] | select(.type == "tool_execution_start" and .toolName == "read") as $call
  | select($call.args | complete_request)
  | $events[] | select(.type == "tool_execution_end" and .toolCallId == $call.toolCallId and .isError == false)
  | select(all(.result.content[]?; .type == "text"))
  | [.result.content[]? | select(.type == "text") | .text] | join("\n")
  | select(length > 0 and (test("truncated|Use offset|Showing lines|output limit"; "i") | not))
  | $call.args.path | select(type == "string") | canonical_path;

def claude_reads:
  . as $events
  | $events[] | select(.type == "assistant") | .message.content[]?
  | select(.type == "tool_use" and .name == "Read") as $call
  | select($call.input | complete_request)
  | $events[] | select(.type == "user") | .message.content[]?
  | select(.type == "tool_result" and .tool_use_id == $call.id and (.is_error // false) == false)
  | .content | select(type == "string")
  # Read defaults to 2000 lines. A shorter numbered result proves EOF;
  # exactly 2000, images, and unknown output shapes remain uncounted.
  | select((test("truncated|exceeds maximum|output limit"; "i") | not))
  | [scan("(?m)^\\s*[0-9]+→")] | length
  | select(. > 0 and . < 2000)
  | $call.input.file_path | select(type == "string") | canonical_path;

def opened_in_full($changed):
  ([pi_reads, claude_reads] | unique) as $read
  | {read: [$changed[] | select(. as $path | $read | index($path))] | unique,
     changed: ($changed | unique | length)};
