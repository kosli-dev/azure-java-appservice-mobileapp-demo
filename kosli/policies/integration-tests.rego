package policy

# Integration test run passes when it actually executed (at least one case) and reported no
# failures and no errors - errors count harness failures, which are not a pass either. Same
# rule as the jq-based custom:integration-test type this replaced.
#
# Evaluated directly against the integration-test.json report produced by
# report-integration-test-result.yml:
#
#   kosli evaluate input --input-file integration-test.json \
#     --policy kosli/policies/integration-tests.rego
default allow := false

ran if input.total > 0

no_failures if input.failed == 0

no_errors if input.errors == 0

allow if {
	ran
	no_failures
	no_errors
}

violations contains "no test cases were run" if not ran

violations contains sprintf("%d test(s) failed", [input.failed]) if {
	ran
	input.failed > 0
}

violations contains sprintf("%d test(s) errored", [input.errors]) if {
	ran
	input.errors > 0
}
