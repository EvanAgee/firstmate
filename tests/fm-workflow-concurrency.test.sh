#!/usr/bin/env bash
# Resolve the standard validation workflows' concurrency groups for representative
# GitHub events. This checks the parsed workflow contract and the groups users see,
# including the pull-request and non-pull-request paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOWS=${1:-"$ROOT/.github/workflows"}
BASE_WORKFLOWS=${2:-}

ruby - "$WORKFLOWS" "$BASE_WORKFLOWS" <<'RUBY'
require "yaml"

workflows = ARGV.fetch(0)
base_workflows = ARGV.fetch(1)

def fail_test(message)
  warn "not ok - #{message}"
  exit 1
end

def load_workflow(workflows, filename)
  path = File.join(workflows, filename)
  YAML.safe_load_file(path, aliases: false) || fail_test("#{filename} is empty")
rescue Errno::ENOENT, Psych::SyntaxError => error
  fail_test("could not load #{filename}: #{error.message}")
end

def resolve_group(template, context)
  template.gsub(/\$\{\{\s*(.*?)\s*\}\}/) do
    terms = Regexp.last_match(1).split("||").map(&:strip)
    unknown = terms.reject { |term| context.key?(term) }
    fail_test("unsupported concurrency expression term: #{unknown.join(', ')}") unless unknown.empty?

    value = terms.lazy.map { |term| context.fetch(term) }
      .find { |candidate| candidate && candidate != false && candidate != "" }
    value.to_s
  end
end

def group_for(config, workflow_name:, pull_request_number:, run_id:)
  concurrency = config["concurrency"]
  fail_test("#{workflow_name} has no concurrency policy") unless concurrency.is_a?(Hash)
  fail_test("#{workflow_name} does not cancel an older run") unless concurrency["cancel-in-progress"] == true

  template = concurrency["group"]
  fail_test("#{workflow_name} has no concurrency group") unless template.is_a?(String)

  resolve_group(template, {
    "github.workflow" => workflow_name,
    "github.event.pull_request.number" => pull_request_number,
    "github.run_id" => run_id,
  })
end

ci = load_workflow(workflows, "ci.yml")
unslop = load_workflow(workflows, "unslop.yml")

unless base_workflows.empty?
  standard = ["ci.yml", "unslop.yml"]
  standard.each do |filename|
    before = load_workflow(base_workflows, filename).reject { |key, _| key == "concurrency" }
    after = load_workflow(workflows, filename).reject { |key, _| key == "concurrency" }
    fail_test("#{filename} changed behavior outside concurrency") unless before == after
  end

  current_files = Dir.glob(File.join(workflows, "*.yml")).map { |path| File.basename(path) }.sort
  base_files = Dir.glob(File.join(base_workflows, "*.yml")).map { |path| File.basename(path) }.sort
  fail_test("workflow files were added or removed") unless current_files == base_files

  (current_files - standard).each do |filename|
    before = load_workflow(base_workflows, filename)
    after = load_workflow(workflows, filename)
    fail_test("#{filename} changed") unless before == after
  end

  puts "ok - standard workflow triggers, permissions, and jobs are unchanged"
  puts "ok - specialized, deployment, release, and manual workflows are unchanged"
end

scenarios = {
  "older CI run for PR 73" => group_for(ci, workflow_name: "CI", pull_request_number: 73, run_id: 1001),
  "newer CI run for PR 73" => group_for(ci, workflow_name: "CI", pull_request_number: 73, run_id: 1002),
  "CI run for separate PR 74" => group_for(ci, workflow_name: "CI", pull_request_number: 74, run_id: 1003),
  "Unslop run for PR 73" => group_for(unslop, workflow_name: "Unslop", pull_request_number: 73, run_id: 1004),
  "CI push run 2001" => group_for(ci, workflow_name: "CI", pull_request_number: nil, run_id: 2001),
  "CI push run 2002" => group_for(ci, workflow_name: "CI", pull_request_number: nil, run_id: 2002),
}

if scenarios["older CI run for PR 73"] != scenarios["newer CI run for PR 73"]
  fail_test("two CI runs for the same pull request do not share a group")
end
if scenarios["older CI run for PR 73"] == scenarios["CI run for separate PR 74"]
  fail_test("separate pull requests share a CI group")
end
if scenarios["older CI run for PR 73"] == scenarios["Unslop run for PR 73"]
  fail_test("different workflows share a group")
end
if scenarios["CI push run 2001"] == scenarios["CI push run 2002"]
  fail_test("non-pull-request runs do not fall back to independent run IDs")
end

width = scenarios.keys.map(&:length).max
puts "scenario#{' ' * (width - 8)} | resolved concurrency group"
puts "#{'-' * width}-+---------------------------"
scenarios.each { |scenario, group| puts "#{scenario.ljust(width)} | #{group}" }
puts "ok - standard validation concurrency resolves to the intended cancellation boundaries"
RUBY
