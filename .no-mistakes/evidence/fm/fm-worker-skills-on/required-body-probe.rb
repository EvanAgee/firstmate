require 'yaml'
require 'open3'
require 'fileutils'
root, evidence = ARGV
workflow = YAML.load_file(File.join(root, '.github/workflows/no-mistakes-required.yml'))
step = workflow.fetch('jobs').fetch('check').fetch('steps').find { |s| s['run'] }
script = step.fetch('run')
fixture = File.join(root, '.test-phase-tmp', 'required-body')
FileUtils.mkdir_p(fixture)
File.write(File.join(fixture, 'gh'), <<~SH)
  #!/bin/bash
  count=0
  [ ! -f "$PROBE_COUNT" ] || count=$(cat "$PROBE_COUNT")
  count=$((count + 1))
  printf '%s\\n' "$count" > "$PROBE_COUNT"
  printf 'API read %s: ' "$count" >&2
  if [ "$count" -le "$PROBE_FAILURES" ]; then
    echo 'HTTP 503 fixture' >&2
    exit 1
  fi
  if [ "$count" -lt "$PROBE_MARKER_AT" ]; then
    echo 'body update still pending' >&2
    echo 'Intermediate PR body'
  else
    echo 'current body received' >&2
    echo 'Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
  fi
SH
File.write(File.join(fixture, 'sleep'), "#!/bin/bash\nprintf 'Retry delay: %s seconds (test clock)\\n' \"$1\" >&2\n")
FileUtils.chmod(0755, [File.join(fixture, 'gh'), File.join(fixture, 'sleep')])
report = []
[['immediate signature',0,1,0,1], ['transient API failure',2,3,0,3], ['body update race',0,3,0,3], ['exhausted API failures',5,9,1,5], ['missing signature',0,9,1,5]].each do |name, failures, marker_at, expected_status, expected_count|
  count_file = File.join(fixture, 'count')
  FileUtils.rm_f(count_file)
  env = {'PATH'=>"#{fixture}:#{ENV.fetch('PATH')}", 'PROBE_COUNT'=>count_file,
         'PROBE_FAILURES'=>failures.to_s, 'PROBE_MARKER_AT'=>marker_at.to_s,
         'GH_REPO'=>'fixture/firstmate', 'PR_NUMBER'=>'102', 'PR_AUTHOR'=>'fixture-author', 'GH_TOKEN'=>'fixture'}
  out, status = Open3.capture2e(env, '/bin/bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', script)
  count = File.read(count_file).strip.to_i
  raise "#{name}: unexpected status/read count: #{status.exitstatus}/#{count}" unless status.exitstatus == expected_status && count == expected_count
  raise 'missing read-failure diagnostic' if name == 'exhausted API failures' && !out.include?('Could not read PR #102 after 5 attempts.')
  report << "Scenario: #{name}\n#{out}Exit: #{status.exitstatus}; API reads: #{count}\n"
end
prior_yaml, prior_status = Open3.capture2('git', '-C', root, 'show', 'bc6d93c:.github/workflows/no-mistakes-required.yml')
raise 'could not read pre-fix workflow' unless prior_status.success?
prior_script = YAML.safe_load(prior_yaml).fetch('jobs').fetch('check').fetch('steps').find { |s| s['run'] }.fetch('run')
count_file = File.join(fixture, 'count')
FileUtils.rm_f(count_file)
env = {'PATH'=>"#{fixture}:#{ENV.fetch('PATH')}", 'PROBE_COUNT'=>count_file,
       'PROBE_FAILURES'=>'2', 'PROBE_MARKER_AT'=>'3', 'GH_REPO'=>'fixture/firstmate',
       'PR_NUMBER'=>'102', 'PR_AUTHOR'=>'fixture-author', 'GH_TOKEN'=>'fixture'}
out, status = Open3.capture2e(env, '/bin/bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', prior_script)
count = File.read(count_file).strip.to_i
raise 'pre-fix regression did not reproduce' unless status.exitstatus == 1 && count == 1
report << "Pre-fix regression (bc6d93c): two transient failures before success\n#{out}Exit: #{status.exitstatus}; API reads: #{count}. Exited before retrying.\n"
File.write(File.join(evidence, 'required-body-transcript.txt'), report.join("\n"))
puts report.join("\n")
