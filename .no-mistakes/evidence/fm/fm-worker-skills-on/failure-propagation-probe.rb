require 'open3'
require 'fileutils'
root, evidence, temp = ARGV
fixture = File.join(root, '.test-phase-tmp', 'failure-propagation')
FileUtils.mkdir_p(File.join(fixture, 'bin'))
File.write(File.join(fixture, 'bin', 'fm-brief.sh'), <<~SH)
  #!/bin/bash
  for arg in "$@"; do
    if [ "$arg" = --secondmate ]; then
      printf '%s/data/%s/brief.md\\n' "$FM_HOME" "$1" > "$PROBE_EXPECTED_PATH"
      exit "$PROBE_SCAFFOLD_STATUS"
    fi
  done
  exec "$PROBE_ROOT/bin/fm-brief.sh" "$@"
SH
FileUtils.chmod(0755, File.join(fixture, 'bin', 'fm-brief.sh'))
lib_source = '. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"'
brief = File.read(File.join(root, 'tests/fm-brief.test.sh')).split("\ntest_no_subagents_rule_emits_in_every_variant\n", 2).first
brief = brief.sub(lib_source, '. "$PROBE_ROOT/tests/lib.sh"')
script = brief + "\nROOT=\"$PROBE_FIXTURE\"\ntest_worker_skills_section_reaches_ship_and_scout_only\n"
report = []
[7, 0].each do |scaffold_status|
  expected_path = File.join(fixture, 'expected-path')
  env = {'PROBE_ROOT'=>root, 'PROBE_FIXTURE'=>fixture, 'PROBE_EXPECTED_PATH'=>expected_path,
         'PROBE_SCAFFOLD_STATUS'=>scaffold_status.to_s, 'TMPDIR'=>temp}
  out, status = Open3.capture2e(env, 'bash', '-c', script)
  expected = File.read(expected_path).strip
  raise "secondmate failure was swallowed: #{out}" unless status.exitstatus == 1 && out.include?(expected)
  report << "Scenario: secondmate scaffold exits #{scaffold_status}, expected file absent\nExpected file: #{expected}\n#{out}Test exit: #{status.exitstatus}\n"
end
spawn = File.read(File.join(root, 'tests/fm-spawn-dispatch-profile.test.sh')).split("\ntest_no_profile_keeps_claude_profile_defaults\n", 2).first
spawn = spawn.sub(lib_source, '. "$PROBE_ROOT/tests/lib.sh"')
script = spawn + <<~SH
  find_single_task_tmp_file() { fail "injected lookup failure under $1"; }
  test_claude_loads_concatenated_worker_skill_prompt
SH
out, status = Open3.capture2e({'PROBE_ROOT'=>root, 'TMPDIR'=>temp}, 'bash', '-c', script)
raise "lookup failure was swallowed: #{out}" unless status.exitstatus == 1 && out.include?('could not locate the Claude worker-skill prompt')
report << "Scenario: task-temp lookup fails inside command substitution\n#{out}Test exit: #{status.exitstatus}\n"
File.write(File.join(evidence, 'failure-propagation-transcript.txt'), report.join("\n"))
puts report.join("\n")
